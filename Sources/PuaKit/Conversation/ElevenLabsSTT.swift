import Foundation

/// ElevenLabs Scribe v3 Live over the realtime WebSocket, with turn prediction: the server
/// commits a transcript as soon as it predicts that the caller has finished, or after
/// `vad_silence_threshold_secs` of silence when it is not sure. Each commit ends the caller's
/// turn, so pua answers without waiting out a fixed silence.
///
/// Sends the caller's audio to ElevenLabs. The API key comes from `ELEVENLABS_API_KEY`.
public final class ElevenLabsSpeechRecognizer: SpeechRecognizer, @unchecked Sendable {
    public static let model = "scribe_v3_live"
    /// The silence after which the server commits when it predicts nothing (`--end-silence`,
    /// at least this long, so a caller who pauses mid-thought is not cut off).
    public static let minimumSilence = 1.3

    public let name = "elevenlabs:\(ElevenLabsSpeechRecognizer.model)"
    public let predictsTurns = true
    public let results: AsyncStream<RecognizedSpeech>
    private let continuation: AsyncStream<RecognizedSpeech>.Continuation
    private let apiKey: String
    private let url: URL
    private let urlSession = URLSession(configuration: .default)
    private let downsampler = Resampler(from: 48_000, to: 16_000)  // pump thread only

    private let lock = NSLock()
    private var ws: URLSessionWebSocketTask?
    private var pending = Data()
    private var lastSend = Date.distantPast
    private var fed: Double = 0          // seconds of caller audio appended
    private var lastVoiced: Double = 0   // end of the latest appended chunk with voice in it
    private var lastPartial = ""
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    public init(settings: ConversationSettings) throws {
        guard let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !key.isEmpty else {
            throw PuaError("elevenlabs_key_missing", "set ELEVENLABS_API_KEY or use engines.stt \"apple\"")
        }
        apiKey = key
        let language = Locale(identifier: settings.locale).language.languageCode?.identifier ?? "en"
        let silence = min(3, max(settings.endOfTurnSilence, Self.minimumSilence))
        var c = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        c.queryItems = [
            URLQueryItem(name: "model_id", value: Self.model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "turn_prediction"),
            URLQueryItem(name: "language_code", value: language),
            URLQueryItem(name: "vad_silence_threshold_secs", value: String(format: "%.2f", silence)),
        ]
        url = c.url!
        (results, continuation) = AsyncStream<RecognizedSpeech>.makeStream()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func prepare() async throws {
        try await connect()
        // The server closes a session that gets no audio for 15 s, as while the phone rings.
        let keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.locked({ !self.finished && Date().timeIntervalSince(self.lastSend) > 5 }) {
                    self.send(Data(count: 3200))  // 100 ms of silence
                }
            }
        }
        locked { tasks.append(keepAlive) }
    }

    /// Opens a session and waits for `session_started`.
    private func connect() async throws {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        task.resume()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { task.cancel(with: .goingAway, reason: nil) }
        }
        defer { watchdog.cancel() }
        let first: [String: Any]
        do { first = try await Self.receiveJSON(task) } catch {
            task.cancel(with: .goingAway, reason: nil)
            let status = (task.response as? HTTPURLResponse).map { " (HTTP \($0.statusCode))" } ?? ""
            throw PuaError("stt_connect_failed", "ElevenLabs realtime speech-to-text\(status): \(error.localizedDescription)")
        }
        guard first["message_type"] as? String == "session_started" else {
            task.cancel(with: .goingAway, reason: nil)
            throw PuaError("stt_failed", "ElevenLabs \(first["message_type"] ?? "error"): \(first["error"] ?? first["message"] ?? "")")
        }
        let receiver = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task)
        }
        locked {
            ws = task
            lastSend = Date()
            tasks.append(receiver)
        }
    }

    private static func receiveJSON(_ task: URLSessionWebSocketTask) async throws -> [String: Any] {
        while true {
            let text: String
            switch try await task.receive() {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            if let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { return obj }
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        do {
            while true { handle(try await Self.receiveJSON(task)) }
        } catch {
            let lost = locked { () -> Bool in
                guard !finished, ws === task else { return false }
                ws = nil
                return true
            }
            guard lost else { return }
            Events.shared.emit("stt_error", ["stt": name, "error": "connection closed: \(error.localizedDescription)"])
            await reconnect()
        }
    }

    /// Audio sent while disconnected is lost; the caller's turn goes on with what was recognized.
    private func reconnect() async {
        for attempt in 1...5 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if locked({ finished }) { return }
            do {
                try await connect()
                Events.shared.emit("stt_reconnected", ["stt": name, "attempt": attempt])
                return
            } catch {
                Events.shared.emit("stt_error", ["stt": name, "error": "\(error)", "attempt": attempt])
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["message_type"] as? String else { return }
        let text = ((msg["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "partial_transcript":
            // `end` is where the caller's voice last was, so pua can drop speech it already answered.
            let end: Double? = locked {
                guard text != lastPartial else { return nil }
                lastPartial = text
                return lastVoiced
            }
            if let end { continuation.yield(RecognizedSpeech(text: text, isFinal: false, end: end)) }
        case "committed_transcript":
            let end = locked { () -> Double in lastPartial = ""; return lastVoiced }
            continuation.yield(RecognizedSpeech(text: text, isFinal: true, end: end, endOfTurn: true))
        case "session_started", "committed_transcript_with_timestamps":
            break
        default:
            Events.shared.emit("stt_error", ["stt": name, "type": type, "error": msg["error"] ?? msg["message"] ?? ""])
        }
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for v in samples { sum += v * v }
        let voiced = (sum / Float(samples.count)).squareRoot() > 0.004  // the threshold Conversation uses
        let pcm = downsampler.process(samples)
        var bytes = Data(capacity: pcm.count * 2)
        for v in pcm {
            let s = int16(v)
            bytes.append(UInt8(truncatingIfNeeded: s))
            bytes.append(UInt8(truncatingIfNeeded: s >> 8))
        }
        let chunk: Data? = locked {
            fed += Double(samples.count) / 48_000
            if voiced { lastVoiced = fed }
            pending.append(bytes)
            guard pending.count >= 3200 else { return nil }  // 100 ms at 16 kHz
            let out = pending
            pending.removeAll(keepingCapacity: true)
            return out
        }
        if let chunk { send(chunk) }
    }

    private func send(_ audio: Data) {
        guard let task = locked({ () -> URLSessionWebSocketTask? in lastSend = Date(); return ws }) else { return }
        let message: [String: Any] = [
            "message_type": "input_audio_chunk", "audio_base_64": audio.base64EncodedString(),
            "commit": false, "sample_rate": 16_000,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    public func finish() async {
        let (task, running) = locked { () -> (URLSessionWebSocketTask?, [Task<Void, Never>]) in
            guard !finished else { return (nil, []) }
            finished = true
            defer { ws = nil; tasks = [] }
            return (ws, tasks)
        }
        running.forEach { $0.cancel() }
        task?.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        continuation.finish()
    }
}
