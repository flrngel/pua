import Foundation

/// A spoken conversation over a connected call:
/// caller audio (process tap) → `SpeechRecognizer` → `ReplyModel` → `Voice` → PUA Call Feed
/// (→ PUA Call Mic → the call). The engines are pluggable (see Engines.swift); this class owns
/// turn-taking, timing and recording, which are the same for every engine.
///
/// Half duplex: what the caller says while the agent is speaking is ignored, which also keeps
/// far-end echo from starting turns.
public final class Conversation: @unchecked Sendable {
    /// Where the call's audio is.
    public struct CallAudio: Sendable {
        public var bundleID = "com.apple.avconferenced"
        public var pids: [pid_t] = []
        /// Stop when the call UI goes idle after having been active (the caller hung up).
        public var callGuard = true
        public init() {}
    }

    public static let hangupMarker = "[hangup]"
    /// Appended to every system prompt, so custom prompts need not know pua's conventions.
    public static let callRules = """
    Your replies are spoken aloud on a phone call. Speak naturally, like a person on the phone: \
    one or two short sentences per reply, no lists, no markdown, no emoji. Do not greet or introduce \
    yourself again, and never repeat an earlier reply: if the caller is confused, say it differently. \
    Only when the caller says goodbye or asks to end the call, reply with a short goodbye and put \
    \(hangupMarker) at the very end. Never write \(hangupMarker) in any other reply.
    """

    private let settings: ConversationSettings
    private let engines: EngineSet
    private let audio: CallAudio
    private let events = Events.shared
    private let caller = SampleRing(capacity: 48_000 * 10)     // tap → pump thread
    private let playback = SampleRing(capacity: 48_000 * 120)  // voice → PUA Call Feed
    private let rendered = SampleRing(capacity: 48_000 * 10)   // feed → recorder

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var started = Date()
    private var stopReason: String?
    private var fedSeconds: Double = 0
    private var lastVoice = Date.distantPast   // voice energy or new words: keeps the turn open
    private var lastSound = Date.distantPast   // voice energy only: end of speech, for latency
    private var soundOnset: Double?            // start of the latest burst of caller voice
    private var turnStart: Double?             // when the caller's current turn began
    private var consumedUntil: Double = 0
    private var finals: [String] = []
    private var volatileText = ""
    private var agentSpeaking = false
    private var callerTrack: [Int16] = []
    private var agentTrack: [Int16] = []
    private var transcript: [[String: Any]] = []
    private var latencies: [Double] = []

    /// `engines` must already be prepared (`EngineSet.prepare()`), so setup cost is paid before
    /// the call starts.
    public init(settings: ConversationSettings, engines: EngineSet, audio: CallAudio = CallAudio()) {
        self.settings = settings
        self.engines = engines
        self.audio = audio
    }

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
        guard let feedDevice = AudioDevice.find(uid: callFeedUID) else {
            throw PuaError("call_feed_missing", "PUA Call Feed not found; reinstall the driver (sudo scripts/install-driver.sh)")
        }
        let pids = audio.pids.isEmpty ? callAudioPIDs(bundleID: audio.bundleID) : audio.pids
        guard !pids.isEmpty else { throw PuaError("no_audio_process", "no process for \(audio.bundleID); is a call connected?") }

        let tap = try ProcessTapCapture(pids: pids, mute: true, sink: caller)
        let feed = DeviceFeed(device: feedDevice, source: playback)
        feed.monitor = rendered
        started = Date()
        try tap.start()
        try feed.start()
        defer { feed.stop(); tap.stop() }
        events.emit("conversation_ready", ["pids": pids.map(Int.init), "direction": settings.direction.rawValue,
                                           "engines": engines.description,
                                           "record": settings.recordDirectory?.path ?? NSNull()])

        let pump = Thread { [self] in pumpLoop() }
        pump.qualityOfService = .userInteractive
        pump.start()
        let results = Task { [self] in
            for await r in engines.recognizer.results { handle(r) }
        }

        if let greeting = settings.openingLine {
            await speakTurn(greeting)
        }
        var lastGuard = Date.distantPast
        var sawActive = false
        var idleSince: Date?
        while !isStopped {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if elapsed() > settings.maxSeconds { stop("max_seconds"); break }
            if audio.callGuard, Date().timeIntervalSince(lastGuard) >= 1 {
                lastGuard = Date()
                let state = CallControl.snapshot().state
                if state == .active { sawActive = true; idleSince = nil }
                else if sawActive, state == .idle {
                    idleSince = idleSince ?? Date()
                    if Date().timeIntervalSince(idleSince!) >= 2 { stop("call_ended"); break }
                }
            }
            let (text, heardAt, endOfTurn, startedAt) = locked { () -> (String, Date, Bool, Double?) in
                let text = (finals + [volatileText]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                // A trailing unfinalized phrase without end punctuation ("I just want to, um")
                // usually means the caller is still thinking: give them a little longer.
                let open = !volatileText.isEmpty && !".?!".contains(volatileText.last ?? ".")
                let silence = open ? max(settings.endOfTurnSilence, 1.3) : settings.endOfTurnSilence
                let end = !text.isEmpty && Date().timeIntervalSince(lastVoice) >= silence
                let start = turnStart
                if end { consumedUntil = fedSeconds; finals = []; volatileText = ""; turnStart = nil; soundOnset = nil }
                return (text, lastSound == .distantPast ? lastVoice : lastSound, end, start)
            }
            guard endOfTurn else { continue }

            record(speaker: "caller", text: text, extra: [:], at: startedAt)
            let hangup = await respond(to: text, heardAt: heardAt)
            if hangup {
                if settings.hangUpWhenDone, let source = try? CallControl.perform(.hangup) {
                    events.emit("hung_up", ["source": source])
                }
                stop("agent_hung_up")
            }
        }

        while pump.isExecuting { usleep(10_000) }
        await engines.recognizer.finish()
        results.cancel()

        let (left, right, sorted, reason, entries) = locked {
            (callerTrack, agentTrack, latencies.sorted(), stopReason ?? "stopped", transcript)
        }
        var summary: [String: Any] = [
            "ok": true, "reason": reason, "seconds": round(elapsed() * 10) / 10,
            "direction": settings.direction.rawValue, "engines": engines.description,
            "turns": entries.count, "transcript": entries,
        ]
        if !sorted.isEmpty {
            summary["reply_latency_s"] = ["median": sorted[sorted.count / 2], "max": sorted.last!]
        }
        if let dir = settings.recordDirectory {
            summary["files"] = try CallRecording.write(to: dir, caller: left, agent: right, transcript: entries,
                                                       agentName: settings.agentName, summary: summary)
        }
        return summary
    }

    // MARK: - Listening

    /// 20 ms at a time: record both sides, track the caller's voice energy, feed the recognizer.
    private func pumpLoop() {
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
            if rms > 0.004, !agentSpeaking {
                let now = Date()
                if now.timeIntervalSince(lastSound) > 0.5 { soundOnset = now.timeIntervalSince(started) }
                lastVoice = now
                lastSound = now
            }
            lock.unlock()
            engines.recognizer.append(UnsafeBufferPointer(start: buf, count: chunk))
        }
    }

    private func handle(_ r: RecognizedSpeech) {
        lock.lock(); defer { lock.unlock() }
        // Drop speech already answered and results delivered while the agent talks. Keep a phrase
        // that runs past the boundary in full: callers often answer the instant the agent stops.
        guard !agentSpeaking, r.end.isFinite, r.end > consumedUntil + 0.1 else { return }
        if !r.text.isEmpty {
            lastVoice = Date()
            // Recognizer ranges include leading silence; the voice onset is when they began.
            if turnStart == nil { turnStart = soundOnset ?? elapsed() }
        }
        if r.isFinal {
            if !r.text.isEmpty { finals.append(r.text) }
            volatileText = ""
        } else {
            volatileText = r.text
        }
    }

    // MARK: - Replying

    /// Streams the model's reply and speaks each sentence as soon as it is complete, while the
    /// rest is still generating. Returns true when the model asked to hang up.
    private func respond(to text: String, heardAt: Date) async -> Bool {
        let (sentenceStream, sentences) = AsyncStream<String>.makeStream()
        let pieces = engines.model.reply(to: text)
        let generator = Task { () -> Error? in
            defer { sentences.finish() }
            var splitter = SentenceSplitter()
            var full = ""
            do {
                for try await piece in pieces {
                    full += piece
                    for sentence in splitter.feed(full) { sentences.yield(sentence) }
                }
                for sentence in splitter.finish(full) { sentences.yield(sentence) }
                return nil
            } catch {
                return error
            }
        }
        locked { agentSpeaking = true }
        let out = SpeechOutput(ring: playback)
        var spoken: [String] = []
        var hangup = false
        for await sentence in sentenceStream where !isStopped {
            let (clean, wantsHangup) = Self.clean(sentence)
            hangup = hangup || wantsHangup
            guard !clean.isEmpty else { continue }
            await say(clean, to: out)
            spoken.append(clean)
        }
        if let error = await generator.value {
            events.emit("llm_error", ["error": "\(error)", "llm": engines.model.name])
            if spoken.isEmpty {
                let fallback = "Sorry, I missed that. Could you say it again?"
                await say(fallback, to: out)
                spoken.append(fallback)
            }
        }
        await drainPlayback()
        finishAgentTurn(spoken: spoken, heardAt: heardAt, firstAudio: out.firstWrite)
        return hangup
    }

    /// Speaks a fixed line as one agent turn (the greeting).
    private func speakTurn(_ line: String) async {
        locked { agentSpeaking = true }
        let out = SpeechOutput(ring: playback)
        await say(line, to: out)
        await drainPlayback()
        finishAgentTurn(spoken: [line], heardAt: nil, firstAudio: out.firstWrite)
    }

    private func say(_ text: String, to out: SpeechOutput) async {
        do {
            try await engines.voice.speak(text, to: out)
        } catch {
            events.emit("tts_error", ["error": "\(error)", "tts": engines.voice.name])
            try? await engines.fallbackVoice?.speak(text, to: out)
        }
    }

    private func finishAgentTurn(spoken: [String], heardAt: Date?, firstAudio: Date?) {
        var extra: [String: Any] = [:]
        if let heardAt, let firstAudio, heardAt != .distantPast {
            let latency = (firstAudio.timeIntervalSince(heardAt) * 100).rounded() / 100
            extra["latency_s"] = latency
            locked { latencies.append(latency) }
        }
        record(speaker: "agent", text: spoken.joined(separator: " "), extra: extra,
               at: firstAudio.map { $0.timeIntervalSince(started) })
        locked {
            agentSpeaking = false
            // No echo margin: the iPhone cancels the agent's voice (live: caller track silent
            // while the agent spoke), and a margin dropped answers given right after a question.
            consumedUntil = fedSeconds
            finals = []
            volatileText = ""
            lastVoice = .distantPast
            lastSound = .distantPast
            soundOnset = nil  // a phrase begun while the agent spoke has no onset of its own
            turnStart = nil
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

    /// `at`: when the turn started, in seconds since the conversation began (default: now).
    private func record(speaker: String, text: String, extra: [String: Any], at: Double? = nil) {
        var entry: [String: Any] = ["t": ((at ?? elapsed()) * 10).rounded() / 10, "speaker": speaker, "text": text]
        entry.merge(extra) { a, _ in a }
        locked { transcript.append(entry) }
        events.emit(speaker == "caller" ? "heard" : "said", entry)
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
