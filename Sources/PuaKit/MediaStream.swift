import AVFoundation
import Foundation

/// Bridges a connected call to a WebSocket server that speaks Twilio Media Streams messages, so
/// voice agents built for Twilio phone calls take pua calls unchanged.
///
/// pua plays Twilio's part: it connects as the client and sends `connected`, `start`, `media`
/// (the caller, 8 kHz μ-law, 20 ms per message) and `stop`. It plays the server's `media`,
/// sends each `mark` back once the audio queued before it has played, and empties its queue on
/// `clear` (barge-in). When the server closes the socket, pua hangs up (`hangUpOnClose`).
/// Spec and differences from Twilio: docs/integration.md.
public final class MediaStreamBridge: CallSession, @unchecked Sendable {
    public struct Options: Sendable {
        public var url: URL
        public var direction: ConversationSettings.Direction = .outgoing
        public var caller: String?
        public var audio = Conversation.CallAudio()
        public var recordDirectory: URL?
        /// Hang up the call when the server closes the socket.
        public var hangUpOnClose = true
        public var maxSeconds: Double = 3600

        public init(url: URL) { self.url = url }
    }

    /// Accepts ws:// and wss:// URLs.
    public static func validate(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["ws", "wss"].contains(url.scheme?.lowercased() ?? "") else {
            throw PuaError("stream_url_invalid", "stream URL must start with ws:// or wss:// (got \(text))")
        }
        return url
    }

    private let options: Options
    private let events = Events.shared
    private let callerRing = SampleRing(capacity: 48_000 * 10)
    private let playback = SampleRing(capacity: 48_000 * 120)
    private let rendered = SampleRing(capacity: 48_000 * 10)
    private let streamSid = "MZ" + MediaStreamBridge.hex(32)
    private let callSid = "CA" + MediaStreamBridge.hex(32)
    private let accountSid = "AC" + MediaStreamBridge.hex(32)

    private let lock = NSLock()
    private var stopReason: String?
    private var serverClosed = false
    private var ws: URLSessionWebSocketTask?
    private var sequence = 0
    private var started = Date()
    private var totalWritten = 0             // 48 kHz frames queued for the caller
    private var marks: [(name: String, at: Int)] = []
    private var mediaSent = 0, mediaReceived = 0, marksReturned = 0, clears = 0
    private var callerTrack: [Int16] = []
    private var agentTrack: [Int16] = []

    public init(options: Options) { self.options = options }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private var isStopped: Bool { locked { stopReason != nil } }

    public func stop(_ reason: String = "stopped") { locked { if stopReason == nil { stopReason = reason } } }
    public func discard() async {}

    public func run() async throws -> [String: Any] {
        guard let feedDevice = AudioDevice.find(uid: callFeedUID) else {
            throw PuaError("call_feed_missing", "PUA Call Feed not found; reinstall the driver (sudo scripts/install-driver.sh)")
        }
        let audio = options.audio
        let pids = audio.pids.isEmpty ? callAudioPIDs(bundleID: audio.bundleID) : audio.pids
        guard !pids.isEmpty else { throw PuaError("no_audio_process", "no process for \(audio.bundleID); is a call connected?") }

        let task = URLSession(configuration: .default).webSocketTask(with: options.url)
        task.maximumMessageSize = 4 << 20
        task.resume()
        ws = task
        var custom: [String: String] = ["direction": options.direction.rawValue]
        if let caller = options.caller { custom["caller"] = caller }
        do {
            try await task.send(.string(Self.json(["event": "connected", "protocol": "Call", "version": "1.0.0"])))
            try await task.send(.string(Self.json(message("start", [
                "start": [
                    "accountSid": accountSid, "streamSid": streamSid, "callSid": callSid,
                    "tracks": ["inbound"], "customParameters": custom,
                    "mediaFormat": ["encoding": "audio/x-mulaw", "sampleRate": 8000, "channels": 1],
                ],
            ]))))
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw PuaError("stream_connect_failed", "\(options.url.host ?? "server"): \(error.localizedDescription)")
        }

        let tap = try ProcessTapCapture(pids: pids, mute: true, sink: callerRing)
        let feed = DeviceFeed(device: feedDevice, source: playback)
        feed.monitor = rendered
        started = Date()
        try tap.start()
        try feed.start()
        defer { feed.stop(); tap.stop() }
        events.emit("stream_ready", ["host": options.url.host ?? "", "path": options.url.path, "stream_sid": streamSid,
                                     "call_sid": callSid, "direction": options.direction.rawValue, "pids": pids.map(Int.init)])

        let receiver = Task { [self] in
            let up = Resampler(from: 8_000, to: 48_000)
            do {
                while true {
                    switch try await task.receive() {
                    case .string(let text): handle(text, upsampler: up)
                    case .data(let data): handle(String(decoding: data, as: UTF8.self), upsampler: up)
                    @unknown default: break
                    }
                }
            } catch {
                let ours = locked { () -> Bool in
                    if stopReason == nil { serverClosed = true; return false }
                    return true
                }
                if !ours { events.emit("stream_closed", ["error": error.localizedDescription]); stop("stream_closed") }
            }
        }
        let pump = Thread { [self] in pumpLoop() }
        pump.qualityOfService = .userInteractive
        pump.start()

        var watch = CallEndWatch()
        while !isStopped {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Date().timeIntervalSince(started) > options.maxSeconds { stop("max_seconds") }
            else if audio.callGuard, watch.callEnded() { stop("call_ended") }
        }
        while pump.isExecuting { usleep(10_000) }

        let closedByServer = locked { serverClosed }
        if !closedByServer {
            try? await task.send(.string(Self.json(message("stop", ["stop": ["accountSid": accountSid, "callSid": callSid]]))))
            task.cancel(with: .normalClosure, reason: nil)
        }
        receiver.cancel()
        if closedByServer, options.hangUpOnClose, let source = try? CallControl.perform(.hangup) {
            events.emit("hung_up", ["source": source])
        }

        let (left, right, reason, counts) = locked {
            (callerTrack, agentTrack, stopReason ?? "stopped",
             ["media_sent": mediaSent, "media_received": mediaReceived, "marks_returned": marksReturned, "clears": clears])
        }
        var summary: [String: Any] = [
            "ok": true, "reason": reason, "seconds": round(Date().timeIntervalSince(started) * 10) / 10,
            "direction": options.direction.rawValue, "stream_sid": streamSid, "call_sid": callSid, "stream": counts,
        ]
        if let caller = options.caller { summary["caller"] = caller }
        if let dir = options.recordDirectory {
            summary["files"] = try CallRecording.write(to: dir, caller: left, agent: right, transcript: [],
                                                       agentName: "Agent", summary: summary)
        }
        return summary
    }

    // MARK: - Caller → server

    /// 20 ms at a time: record both sides, send the caller as μ-law, return marks that have played.
    private func pumpLoop() {
        let down = Resampler(from: 48_000, to: 8_000)
        let chunk = 960
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let mon = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
        defer { buf.deallocate(); mon.deallocate() }
        var pending: [UInt8] = []
        var chunkNumber = 0
        while !isStopped {
            var n = rendered.read(mon, 4800)
            while n > 0 {
                let samples = UnsafeBufferPointer(start: mon, count: n).map(int16)
                locked { agentTrack.append(contentsOf: samples) }
                n = rendered.read(mon, 4800)
            }
            returnPlayedMarks()
            guard callerRing.available >= chunk else { usleep(5_000); continue }
            callerRing.read(buf, chunk)
            let samples = UnsafeBufferPointer(start: buf, count: chunk)
            locked { callerTrack.append(contentsOf: samples.map(int16)) }
            pending.append(contentsOf: down.process(samples).map { G711.encode(int16($0)) })
            while pending.count >= 160 {
                chunkNumber += 1
                let payload = Data(pending.prefix(160)).base64EncodedString()
                pending.removeFirst(160)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                send(message("media", ["media": ["track": "inbound", "chunk": "\(chunkNumber)", "timestamp": "\(ms)", "payload": payload]]))
                locked { mediaSent += 1 }
            }
        }
    }

    private func returnPlayedMarks() {
        let played = locked { () -> [String] in
            let consumed = totalWritten - playback.available
            var out: [String] = []
            while let first = marks.first, first.at <= consumed { out.append(first.name); marks.removeFirst() }
            marksReturned += out.count
            return out
        }
        for name in played { send(message("mark", ["mark": ["name": name]])) }
    }

    // MARK: - Server → caller

    private func handle(_ text: String, upsampler: Resampler) {
        guard let msg = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let event = msg["event"] as? String else { return }
        switch event {
        case "media":
            guard let media = msg["media"] as? [String: Any], let b64 = media["payload"] as? String,
                  let bytes = Data(base64Encoded: b64) else { return }
            let pcm = bytes.map { Float(G711.decode($0)) / 32768 }
            let out = pcm.withUnsafeBufferPointer { upsampler.process($0) }
            locked {
                out.withUnsafeBufferPointer { playback.write($0.baseAddress!, $0.count) }
                totalWritten += out.count
                mediaReceived += 1
            }
        case "mark":
            guard let name = (msg["mark"] as? [String: Any])?["name"] as? String else { return }
            locked { marks.append((name, totalWritten)) }
        case "clear":
            locked {
                playback.clear()
                clears += 1
            }
            events.emit("stream_clear")
        default:
            events.emit("stream_message_ignored", ["event": event])
        }
    }

    // MARK: - Wire

    private func message(_ event: String, _ body: [String: Any]) -> [String: Any] {
        var m = body
        m["event"] = event
        m["streamSid"] = streamSid
        m["sequenceNumber"] = locked { () -> String in sequence += 1; return "\(sequence)" }
        return m
    }

    private func send(_ message: [String: Any]) {
        ws?.send(.string(Self.json(message))) { _ in }
    }

    static func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func hex(_ n: Int) -> String {
        (0..<n).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
    }
}

/// Streaming sample-rate conversion (mono Float32) with Core Audio's converter.
final class Resampler {
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    init(from: Double, to: Double) {
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: inFormat, to: outFormat)!
    }

    func process(_ samples: UnsafeBufferPointer<Float>) -> [Float] {
        guard let base = samples.baseAddress, !samples.isEmpty,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * outFormat.sampleRate / inFormat.sampleRate) + 64)
        else { return [] }
        inBuf.floatChannelData![0].update(from: base, count: samples.count)
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        var given = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return inBuf
        }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}

/// G.711 μ-law, as used by telephone networks and Twilio Media Streams.
enum G711 {
    static func encode(_ sample: Int16) -> UInt8 {
        var s = Int(sample)
        let sign = s < 0 ? 0x80 : 0
        if s < 0 { s = -s }
        s = min(s, 32635) + 0x84
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, s & mask == 0 { exponent -= 1; mask >>= 1 }
        let mantissa = (s >> (exponent + 3)) & 0x0F
        return UInt8(~(sign | (exponent << 4) | mantissa) & 0xFF)
    }

    static func decode(_ byte: UInt8) -> Int16 {
        let u = ~Int(byte) & 0xFF
        let exponent = (u >> 4) & 0x07
        let magnitude = (((u & 0x0F) << 3) + 0x84) << exponent - 0x84
        return Int16(u & 0x80 != 0 ? -magnitude : magnitude)
    }
}
