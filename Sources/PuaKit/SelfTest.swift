import CoreAudio
import Foundation

/// Proves both audio legs without a phone call.
///  1. Downlink: a muted process tap captures a helper process (`afplay`) playing a 440 Hz tone,
///     the same mechanism used on `avconferenced` during a call.
///  2. Uplink: a 880 Hz tone rendered into `PUA Call Mic` comes back out of its input side,
///     which is what the Phone app reads as its microphone.
@available(macOS 14.2, *)
public enum SelfTest {
    public struct Result {
        public let name: String
        public let ok: Bool
        public let detail: [String: Any]
        public var json: [String: Any] { ["name": name, "ok": ok, "detail": detail] }
    }

    static func writeWAV(_ samples: [Float], to url: URL, rate: Int = 48_000) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try d.write(to: url)
    }

    /// Leg 1. The tone starts after 0.8 s of silence so the tap is already muting it: nothing is audible.
    public static func downlink() -> Result {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pua-selftest-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try writeWAV([Float](repeating: 0, count: 38_400) + sine(frequency: 440, amplitude: 0.25, seconds: 2.5), to: url)
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [url.path]
            try player.run()
            defer { if player.isRunning { player.terminate() }; player.waitUntilExit() }

            var objectReady = false
            for _ in 0..<20 where !objectReady { usleep(25_000); objectReady = AudioProcess.objectID(for: player.processIdentifier) != 0 }
            let ring = SampleRing(capacity: 48_000 * 4)
            let tap = try ProcessTapCapture(pids: [player.processIdentifier], mute: true, sink: ring)
            try tap.start()
            usleep(2_600_000)
            tap.stop()
            let freq = tap.level.frequency(sampleRate: ProcessTapCapture.outputRate)
            let ok = tap.level.peak > 0.1 && abs(freq - 440) < 25
            var detail = tap.level.json
            detail["frequency_hz"] = freq.rounded()
            detail["tap_rate"] = tap.tapFormat.mSampleRate
            if !ok, tap.level.peak == 0 {
                detail["hint"] = "silence: allow System Audio Recording for this terminal in Privacy & Security"
            }
            return Result(name: "downlink_process_tap", ok: ok, detail: detail)
        } catch {
            return Result(name: "downlink_process_tap", ok: false, detail: ["error": "\(error)"])
        }
    }

    /// Leg 2. Requires the driver; reading its input needs Microphone access for this terminal.
    public static func uplink() -> Result {
        guard let mic = AudioDevice.find(uid: AudioStreamSession.callMicUID),
              let feedDevice = AudioDevice.find(uid: callFeedUID) else {
            return Result(name: "uplink_call_mic_loopback", ok: false,
                          detail: ["error": "PUA Call Mic / PUA Call Feed not loaded", "action": "sudo scripts/install-driver.sh"])
        }
        do {
            let source = SampleRing(capacity: 48_000 * 3)
            let tone = sine(frequency: 880, amplitude: 0.3, seconds: 2)
            tone.withUnsafeBufferPointer { source.write($0.baseAddress!, $0.count) }
            var level = Level()
            let lock = NSLock()
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, mic.id, nil) { _, inData, _, _, _ in
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
                guard let b = list.first, let p = b.mData?.assumingMemoryBound(to: Float.self) else { return }
                lock.lock(); level.add(p, Int(b.mDataByteSize) / 4); lock.unlock()
            }, "input IOProc")
            try check(AudioDeviceStart(mic.id, proc), "input start")
            let feed = DeviceFeed(device: feedDevice, source: source)
            try feed.start()
            usleep(2_300_000)
            feed.stop()
            AudioDeviceStop(mic.id, proc)
            AudioDeviceDestroyIOProcID(mic.id, proc!)
            lock.lock(); let measured = level; lock.unlock()
            let freq = measured.frequency(sampleRate: 48_000)
            let ok = abs(measured.peak - 0.3) < 0.05 && abs(freq - 880) < 40
            var detail = measured.json
            detail["frequency_hz"] = freq.rounded()
            detail["render_callbacks"] = feed.renderCallbacks
            if measured.peak == 0 { detail["hint"] = "silence: allow Microphone for this terminal, or reload coreaudiod" }
            return Result(name: "uplink_call_mic_loopback", ok: ok, detail: detail)
        } catch {
            return Result(name: "uplink_call_mic_loopback", ok: false, detail: ["error": "\(error)"])
        }
    }
}
