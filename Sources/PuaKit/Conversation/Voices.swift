import AVFoundation
import Foundation

/// The macOS voice (AVSpeechSynthesizer), on-device. `identifier` nil picks the locale's default.
public final class SystemVoice: Voice, @unchecked Sendable {
    public let name: String
    private let identifier: String?
    private let language: String
    private let synthesizer = AVSpeechSynthesizer()

    public init(identifier: String?, language: String) {
        self.identifier = identifier
        self.language = language
        name = "system:\(identifier ?? language)"
    }

    public func speak(_ text: String, to out: SpeechOutput) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: language)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechOutput.sampleRate, channels: 1, interleaved: false)!
        let synth = synthesizer
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var converter: AVAudioConverter?
            var finished = false
            synth.write(utterance) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { finished = true; done.resume(); return }
                if converter == nil || converter!.inputFormat != pcm.format { converter = AVAudioConverter(from: pcm.format, to: target) }
                let cap = AVAudioFrameCount(Double(pcm.frameLength) * SpeechOutput.sampleRate / pcm.format.sampleRate) + 64
                guard let conv = converter, let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                var given = false
                var error: NSError?
                conv.convert(to: buf, error: &error) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true
                    status.pointee = .haveData
                    return pcm
                }
                if buf.frameLength > 0 { out.write(buf.floatChannelData![0], count: Int(buf.frameLength)) }
            }
        }
    }
}

/// ElevenLabs streaming TTS (`/v1/text-to-speech/{voice}/stream`, raw PCM at 48 kHz).
/// The API key comes from the `ELEVENLABS_API_KEY` environment variable, never from the config.
public final class ElevenLabsVoice: Voice, @unchecked Sendable {
    public static let defaultVoiceID = "cgSgspJ2msm6clMCkdW9"  // "Jessica"
    public static let defaultModel = "eleven_flash_v2_5"
    public let name: String
    private let apiKey: String
    private let voiceID: String
    private let model: String

    public init(settings: ConversationSettings) throws {
        guard let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !key.isEmpty else {
            throw PuaError("elevenlabs_key_missing", "set ELEVENLABS_API_KEY or use engines.tts \"system\"")
        }
        apiKey = key
        voiceID = settings.voiceID ?? Self.defaultVoiceID
        model = settings.voiceModel ?? Self.defaultModel
        name = "elevenlabs:\(model):\(voiceID)"
    }

    public func speak(_ text: String, to out: SpeechOutput) async throws {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream?output_format=pcm_48000")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines { body += line; if body.count > 300 { break } }
            throw PuaError("tts_failed", "ElevenLabs \((response as? HTTPURLResponse)?.statusCode ?? 0): \(body)")
        }
        var pending: [UInt8] = []
        pending.reserveCapacity(4096)
        var floats = [Float](repeating: 0, count: 2048)
        func flush(all: Bool) {
            let frames = pending.count / 2
            guard frames > 0, all || frames >= 960 else { return }
            if floats.count < frames { floats = [Float](repeating: 0, count: frames) }
            for i in 0..<frames {
                let v = Int16(bitPattern: UInt16(pending[2 * i]) | UInt16(pending[2 * i + 1]) << 8)
                floats[i] = Float(v) / 32768
            }
            floats.withUnsafeBufferPointer { out.write($0.baseAddress!, count: frames) }
            pending.removeFirst(frames * 2)
        }
        for try await byte in bytes {
            pending.append(byte)
            if pending.count >= 1920 { flush(all: false) }
        }
        flush(all: true)
    }
}
