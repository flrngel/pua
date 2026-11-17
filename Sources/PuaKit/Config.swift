import Foundation

/// The config file (JSON, snake_case keys). Every key is optional; a missing key keeps the
/// built-in default. Reference: docs/configuration.md. Example: examples/receptionist.json.
public struct PuaConfig: Codable, Sendable {
    public struct Agent: Codable, Sendable {
        public var name: String?
        /// The system prompt. `{name}` is replaced with `agent.name`.
        public var systemPrompt: String?
        /// Reads the system prompt from a text file (relative to the config file).
        public var systemPromptFile: String?
        /// First thing the agent says. "" for none.
        public var greeting: String?
        public var locale: String?
    }
    public struct EngineNames: Codable, Sendable { public var stt: String?; public var llm: String?; public var tts: String? }
    public struct VoiceConfig: Codable, Sendable { public var id: String?; public var model: String? }
    public struct Turns: Codable, Sendable {
        public var endOfTurnSilence: Double?
        public var maxSeconds: Double?
        public var hangUpWhenDone: Bool?
    }
    public struct Listen: Codable, Sendable { public var answerAfter: Double?; public var maxCalls: Int? }
    public struct Record: Codable, Sendable { public var directory: String? }
    public struct Hooks: Codable, Sendable { public var callEnded: [String]? }

    public var version: Int?
    public var agent: Agent?
    public var engines: EngineNames?
    public var voice: VoiceConfig?
    public var conversation: Turns?
    public var listen: Listen?
    public var record: Record?
    public var hooks: Hooks?

    public init() {}

    /// Keys pua understands, for typo warnings. Keep in sync with the structs above
    /// (a test checks it).
    static let knownKeys: [String: Set<String>] = [
        "version": [],
        "agent": ["name", "system_prompt", "system_prompt_file", "greeting", "locale"],
        "engines": ["stt", "llm", "tts"],
        "voice": ["id", "model"],
        "conversation": ["end_of_turn_silence", "max_seconds", "hang_up_when_done"],
        "listen": ["answer_after", "max_calls"],
        "record": ["directory"],
        "hooks": ["call_ended"],
    ]

    public static func decode(_ data: Data) throws -> (PuaConfig, warnings: [String]) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config: PuaConfig
        do { config = try decoder.decode(PuaConfig.self, from: data) } catch {
            throw PuaError("config_invalid", "\(error)")
        }
        var warnings: [String] = []
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in root.sorted(by: { $0.key < $1.key }) {
                guard let known = knownKeys[key] else { warnings.append("unknown key '\(key)'"); continue }
                for sub in ((value as? [String: Any]) ?? [:]).keys.sorted() where !known.contains(sub) {
                    warnings.append("unknown key '\(key).\(sub)'")
                }
            }
        }
        if let v = config.version, v != 1 { warnings.append("config version \(v) is newer than this pua understands (1)") }
        return (config, warnings)
    }
}

/// A config file and where it came from. Lookup: `--config FILE`, then `$PUA_CONFIG`, then
/// `~/.config/pua/config.json`, then built-in defaults.
public struct LoadedConfig {
    public static let defaultPath = "~/.config/pua/config.json"
    public var config = PuaConfig()
    public var path: URL?
    public var warnings: [String] = []

    public init() {}

    public static func load(explicit: String?) throws -> LoadedConfig {
        let env = ProcessInfo.processInfo.environment["PUA_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        let required = explicit ?? env
        let candidate = required ?? defaultPath
        let url = URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let required { throw PuaError("config_missing", "no config file at \(required)") }
            return LoadedConfig()
        }
        var loaded = LoadedConfig()
        (loaded.config, loaded.warnings) = try PuaConfig.decode(try Data(contentsOf: url))
        loaded.path = url
        return loaded
    }

    /// Resolves a path from the config: `~` expands, relative paths start at the config file.
    func resolve(_ value: String) -> URL {
        let expanded = (value as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        let base = path?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    public func conversationSettings(direction: ConversationSettings.Direction) throws -> ConversationSettings {
        var s = ConversationSettings(direction: direction)
        let c = config
        if let v = c.agent?.name { s.agentName = v }
        if let file = c.agent?.systemPromptFile {
            let url = resolve(file)
            do { s.systemPrompt = try String(contentsOf: url, encoding: .utf8) } catch {
                throw PuaError("config_invalid", "agent.system_prompt_file: cannot read \(url.path)")
            }
        }
        if let v = c.agent?.systemPrompt { s.systemPrompt = v }
        if let v = c.agent?.greeting { s.greeting = v.isEmpty ? .none : .custom(v) }
        if let v = c.agent?.locale { s.locale = v }
        if let v = c.engines?.stt { s.stt = v }
        if let v = c.engines?.llm { s.llm = v }
        if let v = c.engines?.tts { s.tts = v }
        if let v = c.voice?.id { s.voiceID = v }
        if let v = c.voice?.model { s.voiceModel = v }
        if let v = c.conversation?.endOfTurnSilence { s.endOfTurnSilence = v }
        if let v = c.conversation?.maxSeconds { s.maxSeconds = v }
        if let v = c.conversation?.hangUpWhenDone { s.hangUpWhenDone = v }
        s.recordDirectory = callFolder(direction: direction)
        return s
    }

    /// Base folder for recordings; each call gets its own subfolder.
    public var recordBase: URL? { config.record?.directory.map(resolve) }

    /// A new folder under `record.directory` for one call, or nil when recording is off.
    public func callFolder(direction: ConversationSettings.Direction) -> URL? {
        recordBase.map { CallRecording.folder(in: $0, direction: direction) }
    }
    /// The command for `hooks.call_ended`; a relative program path ("./notify.sh") starts at the config file.
    public var callEndedHook: [String]? {
        guard var argv = config.hooks?.callEnded, let program = argv.first else { return nil }
        if program.contains("/") || program.hasPrefix("~") { argv[0] = resolve(program).path }
        return argv
    }
    public var answerAfter: Double { config.listen?.answerAfter ?? 0 }
    public var maxCalls: Int { config.listen?.maxCalls ?? 0 }
}

/// Resolved settings for one conversation, after the config file and command-line flags.
public struct ConversationSettings: Sendable {
    public enum Direction: String, Sendable { case outgoing, incoming }
    public enum Greeting: Sendable { case standard, none, custom(String) }

    public var direction: Direction
    public var agentName = "Jessica"
    /// nil uses the built-in prompt for `direction`.
    public var systemPrompt: String?
    public var greeting: Greeting = .standard
    public var locale = "en-US"
    public var stt = "apple"
    public var llm = "apple"
    /// Default: "elevenlabs" when `ELEVENLABS_API_KEY` is set, otherwise "system".
    public var tts: String
    public var voiceID: String?
    public var voiceModel: String?
    public var endOfTurnSilence = 0.8
    public var maxSeconds = 300.0
    public var hangUpWhenDone = true
    /// The folder for this conversation's recording; nil records nothing.
    public var recordDirectory: URL?

    public init(direction: Direction) {
        self.direction = direction
        let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? ""
        tts = key.isEmpty ? "system" : "elevenlabs"
    }

    var recording: Bool { recordDirectory != nil }

    private func fill(_ text: String) -> String { text.replacingOccurrences(of: "{name}", with: agentName) }

    /// The system prompt as sent to the model: the persona plus pua's call rules.
    public var instructions: String {
        fill(systemPrompt ?? defaultPrompt) + "\n\n" + Conversation.callRules
    }

    public var openingLine: String? {
        switch greeting {
        case .none: return nil
        case .custom(let text): return fill(text)
        case .standard: return fill(defaultGreeting)
        }
    }

    var defaultGreeting: String {
        let recorded = recording ? (direction == .outgoing ? " Just so you know, this call is being recorded." : " This call is being recorded.") : ""
        switch direction {
        case .outgoing: return "Hi, it's {name}, an AI assistant calling from a Mac through pua.\(recorded) How's your day going?"
        case .incoming: return "Hi, you've reached {name}, an AI assistant answering this phone.\(recorded) Who's calling, and how can I help?"
        }
    }

    var defaultPrompt: String {
        let greeted = "You already greeted the caller\(recording ? " and told them the call is recorded; do not mention recording again" : "")."
        switch direction {
        case .outgoing:
            return """
            You are {name}, a warm and upbeat AI assistant on a live phone call. You run on a Mac: \
            pua relays the iPhone call to the Mac, speech recognition hears the caller, you write the \
            reply, and a synthetic voice speaks it. \(greeted) Ask a short follow-up question now and \
            then. Never invent facts about the caller.
            """
        case .incoming:
            return """
            You are {name}, a friendly AI assistant who answers this phone; you are not the phone's owner. \
            \(greeted) Have a real conversation: answer the caller's questions and talk about whatever \
            they like, as well as you can. You cannot look anything up and have no live information \
            such as weather, news or the time; say so in a few words and offer what you do know. \
            If the caller wants the owner, offer to take a message and repeat it back in one sentence. \
            Never invent facts about the owner and never promise a callback or anything else for them.
            """
        }
    }

    public var json: [String: Any] {
        var o: [String: Any] = [
            "direction": direction.rawValue, "agent_name": agentName, "system_prompt": fill(systemPrompt ?? defaultPrompt),
            "greeting": openingLine ?? NSNull(), "locale": locale,
            "engines": ["stt": stt, "llm": llm, "tts": tts],
            "end_of_turn_silence": endOfTurnSilence, "max_seconds": maxSeconds, "hang_up_when_done": hangUpWhenDone,
            "record_directory": recordDirectory?.path ?? NSNull(),
        ]
        if let voiceID { o["voice_id"] = voiceID }
        if let voiceModel { o["voice_model"] = voiceModel }
        return o
    }
}
