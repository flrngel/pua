import AVFoundation
import CoreMedia
import Foundation
import FoundationModels
import Speech

/// Where the agent's voice comes from. Every backend writes 48 kHz mono Float32 into the
/// playback ring as audio arrives, so speech starts before synthesis finishes.
public enum AgentVoice {
    /// AVSpeechSynthesizer, on-device. `identifier` nil picks the default en-US voice.
    case system(identifier: String?)
    /// ElevenLabs streaming TTS (`/v1/text-to-speech/{voice}/stream`, PCM 48 kHz).
    case elevenLabs(apiKey: String, voiceID: String, model: String)
}

/// A spoken conversation over a connected call:
/// caller audio (process tap) → on-device SpeechTranscriber → on-device Foundation Models
/// → TTS → PUA Call Feed (→ PUA Call Mic → the call). Half duplex: what the caller says while
/// the agent is speaking is ignored, which also keeps far-end echo from triggering turns.
public final class Conversation: @unchecked Sendable {
    public struct Options {
        public var instructions: String
        public var greeting: String?
        public var voice: AgentVoice = .system(identifier: nil)
        public var pids: [pid_t] = []
        public var bundleID = "com.apple.avconferenced"
        public var recordDirectory: URL?
        public var maxSeconds: Double = 300
        public var callGuard = true
        public var hangUpWhenDone = true
        /// Caller silence (no voice energy and no new words) that ends their turn.
        public var endOfTurnSilence: Double = 0.8
        public var locale = Locale(identifier: "en-US")

        public init(instructions: String = Conversation.defaultInstructions, greeting: String? = Conversation.defaultGreeting) {
            self.instructions = instructions
            self.greeting = greeting
        }
    }

    public static let hangupMarker = "[hangup]"
    public static let defaultGreeting = "Hi, it's Jessica, the AI assistant calling from your Mac through pua. Just so you know, this call is being recorded for a demo. How's your day going?"
    public static let defaultInstructions = """
    You are Jessica, a warm and upbeat AI assistant on a live phone call. You run on a Mac: \
    pua relays the iPhone call to the Mac, Apple's on-device speech recognition hears the caller, \
    Apple's on-device language model (you) writes the reply, and a synthetic voice speaks it. \
    You already greeted the caller and told them the call is recorded; do not mention recording again. \
    Speak naturally, like a person on the phone: one or two short sentences per reply, no lists, \
    no markdown, no emoji. Ask a short follow-up question now and then. Never invent facts about \
    the caller. If the caller wants to end the call or says goodbye, reply with a short goodbye \
    and put \(hangupMarker) at the very end.
    """

    private let options: Options
    private let events = Events.shared
    private let caller = SampleRing(capacity: 48_000 * 10)     // tap → pump thread
    private let playback = SampleRing(capacity: 48_000 * 120)  // TTS → PUA Call Feed
    private let rendered = SampleRing(capacity: 48_000 * 10)   // feed → recorder

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var started = Date()
    private var stopReason: String?
    private var fedSeconds: Double = 0
    private var lastVoice = Date.distantPast
    private var consumedUntil: Double = 0
    private var finals: [String] = []
    private var volatileText = ""
    private var agentSpeaking = false
    private var callerTrack: [Int16] = []
    private var agentTrack: [Int16] = []
    private var transcript: [[String: Any]] = []
    private var latencies: [Double] = []

    private var synthesizer: AVSpeechSynthesizer?

    public init(options: Options) { self.options = options }

    /// Ends the conversation from another thread (e.g. on SIGINT).
    public func stop(_ reason: String = "stopped") {
        lock.lock(); if stopReason == nil { stopReason = reason }; lock.unlock()
    }

    private var isStopped: Bool { locked { stopReason != nil } }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    private func elapsed() -> Double { Date().timeIntervalSince(started) }

    // MARK: - Run

    public func run() async throws -> [String: Any] {
        guard case .available = SystemLanguageModel.default.availability else {
            throw PuaError("llm_unavailable", "Apple Intelligence model unavailable: \(SystemLanguageModel.default.availability)")
        }
        guard let feedDevice = AudioDevice.find(uid: callFeedUID) else {
            throw PuaError("call_feed_missing", "PUA Call Feed not found; reinstall the driver (sudo scripts/install-driver.sh)")
        }
        let pids = options.pids.isEmpty ? callAudioPIDs(bundleID: options.bundleID) : options.pids
        guard !pids.isEmpty else { throw PuaError("no_audio_process", "no process for \(options.bundleID); is a call connected?") }

        // Speech recognition, fed from the tap at the analyzer's preferred format.
        let transcriber = SpeechTranscriber(locale: options.locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            events.emit("installing_speech_assets")
            try await request.downloadAndInstall()
        }
        guard let sttFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: tapFormat, to: sttFormat) else {
            throw PuaError("stt_format", "no audio format for SpeechAnalyzer")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: sttFormat)
        let (inputStream, input) = AsyncStream<AnalyzerInput>.makeStream()

        let session = LanguageModelSession(instructions: options.instructions)
        session.prewarm()

        let tap = try ProcessTapCapture(pids: pids, mute: true, sink: caller)
        let feed = DeviceFeed(device: feedDevice, source: playback)
        feed.monitor = rendered
        started = Date()
        try tap.start()
        try feed.start()
        defer { feed.stop(); tap.stop() }
        events.emit("conversation_ready", ["pids": pids.map(Int.init), "stt_rate": sttFormat.sampleRate,
                                           "voice": voiceName, "record": options.recordDirectory?.path ?? NSNull()])

        let pump = Thread { [self] in pumpLoop(converter: converter, tapFormat: tapFormat, sttFormat: sttFormat, input: input) }
        pump.qualityOfService = .userInteractive
        pump.start()
        let analysis = Task { _ = try? await analyzer.analyzeSequence(inputStream) }
        let results = Task { [self] in
            do {
                for try await r in transcriber.results { handle(result: r) }
            } catch { events.emit("stt_error", ["error": "\(error)"]) }
        }

        var session2 = session
        if let greeting = options.greeting {
            _ = await speakTurn(sentences: [greeting], heardAt: nil, userText: nil)
        }
        var lastGuard = Date.distantPast
        var sawActive = false
        var idleSince: Date?
        while !isStopped {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if elapsed() > options.maxSeconds { stop("max_seconds"); break }
            if options.callGuard, Date().timeIntervalSince(lastGuard) >= 1 {
                lastGuard = Date()
                let state = CallControl.snapshot().state
                if state == .active { sawActive = true; idleSince = nil }
                else if sawActive, state == .idle {
                    idleSince = idleSince ?? Date()
                    if Date().timeIntervalSince(idleSince!) >= 2 { stop("call_ended"); break }
                }
            }
            let (text, heardAt, endOfTurn) = locked { () -> (String, Date, Bool) in
                let text = (finals + [volatileText]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                let end = !text.isEmpty && Date().timeIntervalSince(lastVoice) >= options.endOfTurnSilence
                if end { consumedUntil = fedSeconds; finals = []; volatileText = "" }
                return (text, lastVoice, end)
            }
            guard endOfTurn else { continue }

            record(speaker: "caller", text: text, extra: [:])
            let hangup = await respond(to: text, session: &session2, heardAt: heardAt)
            if hangup {
                if options.hangUpWhenDone, let source = try? CallControl.perform(.hangup) {
                    events.emit("hung_up", ["source": source])
                }
                stop("agent_hung_up")
            }
        }

        input.finish()
        results.cancel()
        await analyzer.cancelAndFinishNow()
        analysis.cancel()
        while pump.isExecuting { usleep(10_000) }
        let files = try writeRecording()

        let (sorted, reason, entries) = locked { (latencies.sorted(), stopReason ?? "stopped", transcript) }
        var summary: [String: Any] = [
            "ok": true, "reason": reason, "seconds": round(elapsed() * 10) / 10,
            "turns": entries.count, "transcript": entries,
        ]
        if !sorted.isEmpty {
            summary["reply_latency_s"] = ["median": sorted[sorted.count / 2], "max": sorted.last!]
        }
        if !files.isEmpty { summary["files"] = files }
        return summary
    }

    private var voiceName: String {
        switch options.voice {
        case .system(let id): return "system:\(id ?? "default")"
        case .elevenLabs(_, let voice, let model): return "elevenlabs:\(model):\(voice)"
        }
    }

    // MARK: - Listening

    /// 20 ms at a time: record the caller, track voice energy, convert for the analyzer.
    private func pumpLoop(converter: AVAudioConverter, tapFormat: AVAudioFormat, sttFormat: AVAudioFormat,
                          input: AsyncStream<AnalyzerInput>.Continuation) {
        let chunk = 960
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: chunk)
        let mon = UnsafeMutablePointer<Float>.allocate(capacity: 4800)
        defer { buf.deallocate(); mon.deallocate() }
        while !isStopped {
            var n = rendered.read(mon, 4800)
            while n > 0 {
                let samples = UnsafeBufferPointer(start: mon, count: n).map(int16)
                lock.lock(); agentTrack.append(contentsOf: samples); lock.unlock()
                n = rendered.read(mon, 4800)
            }
            guard caller.available >= chunk else { usleep(5_000); continue }
            caller.read(buf, chunk)
            var sum: Float = 0
            for i in 0..<chunk { sum += buf[i] * buf[i] }
            let rms = (sum / Float(chunk)).squareRoot()
            let samples = UnsafeBufferPointer(start: buf, count: chunk).map(int16)
            lock.lock()
            callerTrack.append(contentsOf: samples)
            fedSeconds += Double(chunk) / 48_000
            if rms > 0.004, !agentSpeaking { lastVoice = Date() }
            lock.unlock()

            guard let inBuf = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: AVAudioFrameCount(chunk)),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: sttFormat,
                                                frameCapacity: AVAudioFrameCount(Double(chunk) * sttFormat.sampleRate / 48_000) + 32)
            else { continue }
            inBuf.floatChannelData![0].update(from: buf, count: chunk)
            inBuf.frameLength = AVAudioFrameCount(chunk)
            var given = false
            var error: NSError?
            converter.convert(to: outBuf, error: &error) { _, status in
                if given { status.pointee = .noDataNow; return nil }
                given = true
                status.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0 { input.yield(AnalyzerInput(buffer: outBuf)) }
        }
    }

    private func handle(result r: SpeechTranscriber.Result) {
        let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        let start = r.range.start.seconds
        lock.lock(); defer { lock.unlock() }
        // Drop speech already answered, and anything heard while the agent talks.
        guard !agentSpeaking, start.isFinite, start >= consumedUntil - 0.05 else { return }
        if !text.isEmpty { lastVoice = Date() }
        if r.isFinal {
            if !text.isEmpty { finals.append(text) }
            volatileText = ""
        } else {
            volatileText = text
        }
    }

    // MARK: - Replying

    /// Streams the model's reply and speaks each sentence as soon as it is complete, while the
    /// rest is still generating. Returns true when the model asked to hang up.
    private func respond(to text: String, session: inout LanguageModelSession, heardAt: Date) async -> Bool {
        let (sentenceStream, sentences) = AsyncStream<String>.makeStream()
        let model = session
        let generator = Task { () -> Error? in
            defer { sentences.finish() }
            var splitter = SentenceSplitter()
            var last = ""
            do {
                for try await snapshot in model.streamResponse(to: text) {
                    last = snapshot.content
                    for sentence in splitter.feed(last) { sentences.yield(sentence) }
                }
                for sentence in splitter.finish(last) { sentences.yield(sentence) }
                return nil
            } catch {
                return error
            }
        }
        locked { agentSpeaking = true }
        var spoken: [String] = []
        var hangup = false
        var firstAudio: Date?
        for await sentence in sentenceStream {
            let (clean, wantsHangup) = Self.clean(sentence)
            hangup = hangup || wantsHangup
            guard !clean.isEmpty else { continue }
            await synthesize(clean) { firstAudio = firstAudio ?? Date() }
            spoken.append(clean)
        }
        if let error = await generator.value {
            events.emit("llm_error", ["error": "\(error)"])
            if case LanguageModelSession.GenerationError.exceededContextWindowSize = error {
                session = LanguageModelSession(instructions: options.instructions)
            }
            if spoken.isEmpty {
                let fallback = "Sorry, I missed that. Could you say it again?"
                await synthesize(fallback) { firstAudio = firstAudio ?? Date() }
                spoken.append(fallback)
            }
        }
        await drainPlayback()
        finishAgentTurn(spoken: spoken, heardAt: heardAt, firstAudio: firstAudio)
        return hangup
    }

    /// Speaks fixed sentences as one agent turn (greeting, fallbacks).
    private func speakTurn(sentences: [String], heardAt: Date?, userText: String?) async -> Bool {
        locked { agentSpeaking = true }
        var firstAudio: Date?
        for s in sentences { await synthesize(s) { firstAudio = firstAudio ?? Date() } }
        await drainPlayback()
        finishAgentTurn(spoken: sentences, heardAt: heardAt, firstAudio: firstAudio)
        return false
    }

    private func finishAgentTurn(spoken: [String], heardAt: Date?, firstAudio: Date?) {
        var extra: [String: Any] = [:]
        if let heardAt, let firstAudio, heardAt != .distantPast {
            let latency = (firstAudio.timeIntervalSince(heardAt) * 100).rounded() / 100
            extra["latency_s"] = latency
            locked { latencies.append(latency) }
        }
        record(speaker: "agent", text: spoken.joined(separator: " "), extra: extra)
        locked {
            agentSpeaking = false
            // Far-end echo of the agent's last words can arrive a few hundred ms after playback.
            consumedUntil = fedSeconds + 0.4
            finals = []
            volatileText = ""
            lastVoice = .distantPast
        }
    }

    /// Waits until the feed has rendered everything, plus the path to the far end.
    private func drainPlayback() async {
        while playback.available > 0, !isStopped { try? await Task.sleep(nanoseconds: 20_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    static func clean(_ sentence: String) -> (String, Bool) {
        var s = sentence
        let hangup = s.localizedCaseInsensitiveContains(hangupMarker)
        s = s.replacingOccurrences(of: hangupMarker, with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "#", with: "")
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), hangup)
    }

    private func record(speaker: String, text: String, extra: [String: Any]) {
        var entry: [String: Any] = ["t": (elapsed() * 10).rounded() / 10, "speaker": speaker, "text": text]
        entry.merge(extra) { a, _ in a }
        locked { transcript.append(entry) }
        events.emit(speaker == "caller" ? "heard" : "said", entry)
    }

    // MARK: - Speech synthesis

    private func synthesize(_ text: String, firstAudio: @escaping () -> Void) async {
        do {
            switch options.voice {
            case .elevenLabs(let key, let voice, let model):
                try await synthesizeElevenLabs(text, apiKey: key, voiceID: voice, model: model, firstAudio: firstAudio)
            case .system(let id):
                await synthesizeSystem(text, identifier: id, firstAudio: firstAudio)
            }
        } catch {
            events.emit("tts_error", ["error": "\(error)"])
            await synthesizeSystem(text, identifier: nil, firstAudio: firstAudio)
        }
    }

    private func synthesizeElevenLabs(_ text: String, apiKey: String, voiceID: String, model: String,
                                      firstAudio: @escaping () -> Void) async throws {
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
        var first = true
        func flush(all: Bool) {
            let frames = pending.count / 2
            guard frames > 0, all || frames >= 960 else { return }
            if floats.count < frames { floats = [Float](repeating: 0, count: frames) }
            for i in 0..<frames {
                let v = Int16(bitPattern: UInt16(pending[2 * i]) | UInt16(pending[2 * i + 1]) << 8)
                floats[i] = Float(v) / 32768
            }
            floats.withUnsafeBufferPointer { playback.write($0.baseAddress!, frames) }
            pending.removeFirst(frames * 2)
            if first { first = false; firstAudio() }
        }
        for try await byte in bytes {
            pending.append(byte)
            if pending.count >= 1920 { flush(all: false) }
        }
        flush(all: true)
    }

    private func synthesizeSystem(_ text: String, identifier: String?, firstAudio: @escaping () -> Void) async {
        let synth = synthesizer ?? AVSpeechSynthesizer()
        synthesizer = synth
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: "en-US")
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let ring = playback
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var converter: AVAudioConverter?
            var finished = false
            var first = true
            synth.write(utterance) { buffer in
                guard !finished, let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { finished = true; done.resume(); return }
                if converter == nil || converter!.inputFormat != pcm.format { converter = AVAudioConverter(from: pcm.format, to: target) }
                let cap = AVAudioFrameCount(Double(pcm.frameLength) * 48_000 / pcm.format.sampleRate) + 64
                guard let conv = converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
                var given = false
                var error: NSError?
                conv.convert(to: out, error: &error) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true
                    status.pointee = .haveData
                    return pcm
                }
                if out.frameLength > 0 {
                    ring.write(out.floatChannelData![0], Int(out.frameLength))
                    if first { first = false; firstAudio() }
                }
            }
        }
    }

    // MARK: - Recording

    /// Writes conversation.wav (stereo: left = caller, right = agent) and transcript.md/.jsonl.
    private func writeRecording() throws -> [String: String] {
        guard let dir = options.recordDirectory else { return [:] }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        lock.lock()
        let left = callerTrack, right = agentTrack, entries = transcript
        lock.unlock()
        let frames = max(left.count, right.count)
        var data = Data(capacity: 44 + frames * 4)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[2 * i] = i < left.count ? left[i] : 0
            interleaved[2 * i + 1] = i < right.count ? right[i] : 0
        }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        let wav = dir.appendingPathComponent("conversation.wav")
        try data.write(to: wav)

        let jsonl = dir.appendingPathComponent("transcript.jsonl")
        let lines = try entries.map { String(data: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)! }
        try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

        let md = dir.appendingPathComponent("transcript.md")
        let body = entries.map { e -> String in
            let t = e["t"] as? Double ?? 0
            let who = (e["speaker"] as? String) == "agent" ? "Jessica (AI)" : "Caller"
            let lat = (e["latency_s"] as? Double).map { String(format: "  _(reply in %.1f s)_", $0) } ?? ""
            return String(format: "**[%d:%02d] %@:** %@%@", Int(t) / 60, Int(t) % 60, who, e["text"] as? String ?? "", lat)
        }.joined(separator: "\n\n")
        try (body + "\n").write(to: md, atomically: true, encoding: .utf8)
        return ["wav": wav.path, "transcript_md": md.path, "transcript_jsonl": jsonl.path]
    }
}

@inline(__always) func int16(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }

/// Splits a growing text into complete sentences.
struct SentenceSplitter {
    private var emitted = 0

    mutating func feed(_ full: String) -> [String] {
        let chars = Array(full)
        var out: [String] = []
        var cut = emitted
        var i = emitted
        while i < chars.count - 1 {
            if ".!?".contains(chars[i]), chars[i + 1] == " " {
                let s = String(chars[cut...i]).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                cut = i + 1
            }
            i += 1
        }
        emitted = cut
        return out
    }

    mutating func finish(_ full: String) -> [String] {
        let chars = Array(full)
        guard emitted < chars.count else { return [] }
        let s = String(chars[emitted...]).trimmingCharacters(in: .whitespacesAndNewlines)
        emitted = chars.count
        return s.isEmpty ? [] : [s]
    }
}
