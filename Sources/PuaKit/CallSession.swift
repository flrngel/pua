import Foundation

/// What runs on a connected call: pua's own `Conversation`, or a `MediaStreamBridge` to an
/// external voice agent. `converse`, `stream` and `listen` only differ in how the call starts.
public protocol CallSession: AnyObject {
    /// Runs until the call or the session ends. Returns the call summary.
    func run() async throws -> [String: Any]
    /// Ends the session from another thread (Ctrl-C). Does not hang up.
    func stop(_ reason: String)
    /// The call never connected (missed, answered elsewhere): release what was prepared.
    func discard() async
}

/// Facts about the call a session is made for.
public struct CallInfo: Sendable {
    public var direction: ConversationSettings.Direction
    /// The caller as macOS shows it (incoming), or the dialed number (outgoing).
    public var caller: String?
    public var recordDirectory: URL?

    public init(direction: ConversationSettings.Direction, caller: String? = nil, recordDirectory: URL? = nil) {
        self.direction = direction
        self.caller = caller
        self.recordDirectory = recordDirectory
    }
}

/// Makes the session for one call. `listen` calls it while the call rings, so slow setup
/// (models, an agent process) is done before Accept.
public typealias CallSessionFactory = @Sendable (CallInfo) async throws -> CallSession

public enum CallSessions {
    /// pua's own conversation with the configured engines.
    public static func conversation(_ settings: ConversationSettings, audio: Conversation.CallAudio = .init()) -> CallSessionFactory {
        { info in
            var s = settings
            s.direction = info.direction
            s.caller = info.caller ?? s.caller
            if let dir = info.recordDirectory { s.recordDirectory = dir }
            let engines = try Engines.make(s)
            do { try await engines.prepare() } catch {
                await engines.discard()
                throw error
            }
            return Conversation(settings: s, engines: engines, audio: audio)
        }
    }

    /// Checks that every engine can start, without starting an `exec` agent. Returns the engines.
    public static func check(_ settings: ConversationSettings) async throws -> [String: Any] {
        let engines = try Engines.make(settings)
        try await engines.recognizer.prepare()
        if !(engines.model is ExecReplyModel) { try await engines.model.prepare() }
        try await engines.voice.prepare()
        try await engines.fallbackVoice?.prepare()
        await engines.recognizer.finish()
        return ["engines": engines.description]
    }

    /// A Twilio Media Streams compatible WebSocket bridge to `options.url`.
    public static func stream(_ options: MediaStreamBridge.Options) -> CallSessionFactory {
        { info in
            var o = options
            o.direction = info.direction
            o.caller = info.caller ?? o.caller
            if let dir = info.recordDirectory { o.recordDirectory = dir }
            return MediaStreamBridge(options: o)
        }
    }
}

/// Notices the caller hanging up: the call UI was active, then stayed idle for 2 s.
struct CallEndWatch {
    private var lastCheck = Date.distantPast
    private var sawActive = false
    private var idleSince: Date?

    mutating func callEnded() -> Bool {
        guard Date().timeIntervalSince(lastCheck) >= 1 else { return false }
        lastCheck = Date()
        let state = CallControl.snapshot().state
        if state == .active { sawActive = true; idleSince = nil; return false }
        guard sawActive, state == .idle else { return false }
        let since = idleSince ?? Date()
        idleSince = since
        return Date().timeIntervalSince(since) >= 2
    }
}
