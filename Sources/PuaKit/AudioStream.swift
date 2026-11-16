import CoreAudio
import Foundation

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Duplex call audio for an agent:
///   stdin  → PCM16 LE 48 kHz mono → `PUA Call Mic` → Phone app microphone → caller
///   stdout ← PCM16 LE 48 kHz mono ← process tap on `avconferenced` ← caller
///   stderr   JSONL events
/// Plain PCM16 on stdin and stdout, so existing STT/TTS pipes fit.
@available(macOS 14.2, *)
public final class AudioStreamSession {
    public static let callMicUID = PuaKit.callMicUID

    public struct Options {
        public var bundleID = "com.apple.avconferenced"
        public var pids: [pid_t] = []
        public var micUID = AudioStreamSession.callMicUID
        public var muteLocal = true
        public var maxSeconds: Double?
        public var route = false
        public var stopAfterPlayback = false
        public var callGuard = true
        public var statsInterval: Double = 5
        public var captureEnabled = true
        public var playbackEnabled = true
        public init() {}
    }

    let options: Options
    let events = Events.shared
    let stop = Flag()
    let capture = SampleRing(capacity: 48_000 * 5)
    let playback = SampleRing(capacity: 48_000 * 10)
    var playbackEOF = Flag()
    var stopReason = "stopped"
    var receivedFrames: UInt64 = 0
    var sentFrames: UInt64 = 0

    public init(options: Options) { self.options = options }

    func finish(_ reason: String) {
        guard !stop.isSet else { return }
        stopReason = reason
        stop.set()
    }

    public func run() throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var feed: DeviceFeed?
        var tap: ProcessTapCapture?
        var routed = false
        defer {
            tap?.stop()
            feed?.stop()
            if routed {
                do { events.emit("route_restored", try PhoneRoute.restore()) }
                catch { events.emit("route_restore_failed", ["error": "\(error)"]) }
            }
        }

        // Uplink: pua renders into the output-only feed; the Phone app reads the input-only mic.
        var mic: AudioDevice?
        var feedDevice: AudioDevice?
        if options.playbackEnabled {
            guard let found = AudioDevice.find(uid: options.micUID) else {
                throw PuaError("call_mic_missing", "virtual device \(options.micUID) not found; run scripts/install-driver.sh")
            }
            guard let f = AudioDevice.find(uid: callFeedUID) else {
                throw PuaError("call_feed_missing", "PUA Call Feed not found; reinstall the driver (sudo scripts/install-driver.sh)")
            }
            mic = found
            feedDevice = f
        }

        // Downlink processes.
        let pids = options.pids.isEmpty ? callAudioPIDs(bundleID: options.bundleID) : options.pids
        if options.captureEnabled, pids.isEmpty {
            throw PuaError("no_audio_process", "no process for \(options.bundleID); is a call connected?")
        }

        if options.route, let mic {
            events.emit("route", try PhoneRoute.setup(micName: mic.name))
            routed = true
        }

        if options.captureEnabled {
            let t = try ProcessTapCapture(pids: pids, mute: options.muteLocal, sink: capture)
            try t.start()
            tap = t
        }
        if let feedDevice {
            let f = DeviceFeed(device: feedDevice, source: playback)
            try f.start()
            feed = f
        }

        installSignalHandlers()
        if options.captureEnabled { startCaptureWriter() }
        if options.playbackEnabled { startPlaybackReader() }

        var ready: [String: Any] = ["format": "s16le", "rate": 48_000, "channels": 1,
                                    "pids": pids, "mute_local": options.muteLocal]
        if let mic { ready["mic"] = mic.name }
        if let tap { ready["tap_rate"] = tap.tapFormat.mSampleRate; ready["tap_channels"] = tap.tapFormat.mChannelsPerFrame }
        events.emit("ready", ready)

        let started = Date()
        var lastStats = Date()
        var lastGuard = Date()
        var sawActive = false
        var idleSince: Date?
        var drainedReported = false
        let guardOn = options.callGuard && AX.isTrusted
        if options.callGuard && !AX.isTrusted { events.emit("warning", ["reason": "call_guard_disabled_accessibility_required"]) }

        while !stop.isSet {
            usleep(50_000)
            let now = Date()
            if let max = options.maxSeconds, now.timeIntervalSince(started) >= max { finish("max_seconds"); break }

            if playbackEOF.isSet, !drainedReported, playback.available == 0 {
                drainedReported = true
                events.emit("playback_drained", ["sent_frames": sentFrames])
                if options.stopAfterPlayback { finish("playback_drained"); break }
            }

            if guardOn, now.timeIntervalSince(lastGuard) >= 1 {
                lastGuard = now
                let state = CallControl.snapshot().state
                if state == .active { sawActive = true; idleSince = nil }
                else if sawActive, state == .idle {
                    if idleSince == nil { idleSince = now }
                    if now.timeIntervalSince(idleSince!) >= 2 { events.emit("call_ended"); finish("call_ended"); break }
                }
            }

            if now.timeIntervalSince(lastStats) >= options.statsInterval {
                lastStats = now
                var s: [String: Any] = ["received_frames": receivedFrames, "sent_frames": sentFrames,
                                        "capture_dropped": capture.droppedFrames]
                if let tap { s["capture_level"] = tap.level.json; s["tap_callbacks"] = tap.callbacks }
                if let feed { s["render_callbacks"] = feed.renderCallbacks; s["underrun_frames"] = feed.underrunFrames }
                events.emit("stats", s)
            }
        }
        events.emit("stopped", ["reason": stopReason, "received_frames": receivedFrames, "sent_frames": sentFrames])
        return 0
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { [weak self] in self?.finish(sig == SIGINT ? "sigint" : "sigterm") }
            src.resume()
            signalSources.append(src)
        }
    }
    private var signalSources: [DispatchSourceSignal] = []

    /// Drains captured caller audio to stdout in 10 ms chunks.
    private func startCaptureWriter() {
        let t = Thread { [self] in
            let chunk = 480
            let f = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
            let s = UnsafeMutablePointer<Int16>.allocate(capacity: chunk)
            defer { f.deallocate(); s.deallocate() }
            while !stop.isSet {
                if capture.available < chunk { usleep(5_000); continue }
                let n = capture.read(f, chunk)
                PCM16.fromFloat(f, n, s)
                if !writeAll(1, s, n * 2) { events.emit("capture_consumer_closed"); finish("stdout_closed"); return }
                receivedFrames += UInt64(n)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    /// Reads agent speech from stdin with backpressure (keeps at most ~10 s queued).
    private func startPlaybackReader() {
        let t = Thread { [self] in
            let bytes = 9_600
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes + 1)
            let f = UnsafeMutablePointer<Float>.allocate(capacity: bytes / 2 + 1)
            defer { buf.deallocate(); f.deallocate() }
            var carry = 0
            while !stop.isSet {
                while playback.available > playback.capacity - bytes / 2, !stop.isSet { usleep(10_000) }
                let r = read(0, buf + carry, bytes - carry)
                if r < 0 { if errno == EINTR { continue }; break }
                if r == 0 { break }
                let total = carry + r
                let frames = total / 2
                buf.withMemoryRebound(to: Int16.self, capacity: frames) { PCM16.toFloat($0, frames, f) }
                playback.write(f, frames)
                sentFrames += UInt64(frames)
                carry = total % 2
                if carry == 1 { buf[0] = buf[total - 1] }
            }
            playbackEOF.set()
            events.emit("playback_eof", ["sent_frames": sentFrames])
        }
        t.qualityOfService = .userInitiated
        t.start()
    }
}
