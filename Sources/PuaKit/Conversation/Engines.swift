import Foundation

// Extension points of a conversation. Each part is a protocol; the config file picks an
// implementation by name (`engines.stt`, `engines.llm`, `engines.tts`).
//
// To add an engine: implement the protocol in a new file in this folder, then add one line to
// the matching table in `Engines`. Nothing else in pua needs to change. See CONTRIBUTING.md.

/// Text recognized from the caller. `end` is where the phrase ends, in seconds of caller audio
/// since the conversation started (the clock of the samples passed to `append`). `endOfTurn`
/// marks a final result after which the caller is done talking, from recognizers that predict
/// turns (`predictsTurns`).
public struct RecognizedSpeech: Sendable {
    public var text: String
    public var isFinal: Bool
    public var end: Double
    public var endOfTurn: Bool

    public init(text: String, isFinal: Bool, end: Double, endOfTurn: Bool = false) {
        self.text = text
        self.isFinal = isFinal
        self.end = end
        self.endOfTurn = endOfTurn
    }
}

/// Speech-to-text for the caller's side of the call.
public protocol SpeechRecognizer: AnyObject {
    var name: String { get }
    /// Called once before audio flows: download models, choose formats, connect.
    func prepare() async throws
    /// Caller audio: 48 kHz mono Float32 in 20 ms chunks, from the audio pump thread.
    /// Must return quickly.
    func append(_ samples: UnsafeBufferPointer<Float>)
    /// Partial and final results. Partial results for a phrase replace each other until a final one.
    var results: AsyncStream<RecognizedSpeech> { get }
    /// True when final results carry `endOfTurn`. pua then answers on that mark instead of
    /// waiting for `end_of_turn_silence`.
    var predictsTurns: Bool { get }
    /// No more audio. Ends `results`.
    func finish() async
}

/// Something a reply model does on its own, outside a reply.
public enum ModelEvent: Sendable {
    /// Speak this line when the caller is not talking (a greeting, "I found it", a reminder).
    case say(String)
    /// End the call after anything queued has been said.
    case hangup
}

/// Writes the agent's replies. Keeps the conversation context for one call.
public protocol ReplyModel: AnyObject {
    var name: String { get }
    func prepare() async throws
    /// Streams the reply to one caller turn as text pieces, in order. pua splits them into
    /// sentences and speaks each one as soon as it is complete. End the reply with
    /// `Conversation.hangupMarker` to end the call.
    func reply(to callerText: String) -> AsyncThrowingStream<String, Error>
    /// Unprompted actions; nil when the model only answers turns.
    var events: AsyncStream<ModelEvent>? { get }
    /// The call is over (`summary` includes the transcript). Release resources here.
    func finish(summary: [String: Any]) async
}

/// Text-to-speech for the agent's side of the call.
public protocol Voice: AnyObject {
    var name: String { get }
    func prepare() async throws
    /// Speaks `text`, writing audio to `out` while it is synthesized, so playback starts early.
    func speak(_ text: String, to out: SpeechOutput) async throws
}

public extension SpeechRecognizer {
    func prepare() async throws {}
    var predictsTurns: Bool { false }
}
public extension ReplyModel {
    func prepare() async throws {}
    var events: AsyncStream<ModelEvent>? { nil }
    func finish(summary: [String: Any]) async {}
}
public extension Voice { func prepare() async throws {} }

/// Where a `Voice` writes: 48 kHz mono Float32 samples, played into the call in order.
public final class SpeechOutput: @unchecked Sendable {
    public static let sampleRate: Double = 48_000
    private let ring: SampleRing
    private let lock = NSLock()
    private var first: Date?

    public init(ring: SampleRing) { self.ring = ring }

    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        if first == nil { first = Date() }
        lock.unlock()
        ring.write(samples, count)
    }

    /// When the first audio was written (reply latency is measured to this point).
    public var firstWrite: Date? {
        lock.lock(); defer { lock.unlock() }
        return first
    }
}

/// The engines for one conversation. Create a fresh set per call, so no context leaks between calls.
public struct EngineSet {
    public let recognizer: SpeechRecognizer
    public let model: ReplyModel
    public let voice: Voice
    /// Speaks instead of `voice` when it fails (for example, the network is down).
    public let fallbackVoice: Voice?

    public func prepare() async throws {
        try await recognizer.prepare()
        try await model.prepare()
        try await voice.prepare()
        try await fallbackVoice?.prepare()
    }

    public var description: [String: String] {
        ["stt": recognizer.name, "llm": model.name, "tts": voice.name]
    }

    /// Releases everything when the call never happened (missed, answered elsewhere).
    public func discard() async {
        await recognizer.finish()
        await model.finish(summary: ["ok": false, "reason": "not_answered", "transcript": []])
    }
}

public enum Engines {
    public typealias Factory<T> = (ConversationSettings) throws -> T

    /// `engines.stt`
    public static let recognizers: [String: Factory<SpeechRecognizer>] = [
        "apple": { AppleSpeechRecognizer(locale: Locale(identifier: $0.locale)) },
        "elevenlabs": { try ElevenLabsSpeechRecognizer(settings: $0) },
    ]

    /// `engines.llm`
    public static let models: [String: Factory<ReplyModel>] = [
        "apple": { AppleReplyModel(instructions: $0.instructions) },
        "exec": { try ExecReplyModel(settings: $0) },
    ]

    /// `engines.tts`
    public static let voices: [String: Factory<Voice>] = [
        "system": { SystemVoice(identifier: $0.voiceID, language: $0.locale) },
        "elevenlabs": { try ElevenLabsVoice(settings: $0) },
    ]

    public static func make(_ settings: ConversationSettings) throws -> EngineSet {
        func pick<T>(_ table: [String: Factory<T>], _ name: String, _ key: String) throws -> T {
            guard let factory = table[name] else {
                throw PuaError("unknown_engine", "\(key) '\(name)' is not registered; known: \(table.keys.sorted().joined(separator: ", "))")
            }
            return try factory(settings)
        }
        let voice = try pick(voices, settings.tts, "engines.tts")
        return EngineSet(
            recognizer: try pick(recognizers, settings.stt, "engines.stt"),
            model: try pick(models, settings.llm, "engines.llm"),
            voice: voice,
            fallbackVoice: settings.tts == "system" ? nil : SystemVoice(identifier: nil, language: settings.locale)
        )
    }
}
