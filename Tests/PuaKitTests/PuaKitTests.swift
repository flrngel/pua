import Foundation
import Testing
@testable import PuaKit

// Offline checks for the parts that do not need a call. Run with `swift test`.

@Test func knownKeysMatchConfigFields() throws {
    var c = PuaConfig()
    c.version = 1
    c.agent = .init(name: "a", systemPrompt: "b", systemPromptFile: "c", greeting: "d", locale: "e")
    c.engines = .init(stt: "a", llm: "b", tts: "c")
    c.voice = .init(id: "a", model: "b")
    c.conversation = .init(endOfTurnSilence: 1, maxSeconds: 2, hangUpWhenDone: true)
    c.listen = .init(answerAfter: 1, maxCalls: 2)
    c.record = .init(directory: "a")
    c.hooks = .init(callEnded: ["a"])
    c.exec = .init(command: ["a"], turnTimeout: 1)
    c.stream = .init(url: "ws://a", hangUpOnClose: true)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let root = try #require(try JSONSerialization.jsonObject(with: encoder.encode(c)) as? [String: Any])
    #expect(Set(root.keys) == Set(PuaConfig.knownKeys.keys))
    for (section, value) in root {
        guard let fields = value as? [String: Any] else { continue }
        #expect(Set(fields.keys) == PuaConfig.knownKeys[section], "PuaConfig.knownKeys[\(section)] is out of date")
    }
}

@Test func unknownKeysAreReported() throws {
    let (_, warnings) = try PuaConfig.decode(Data(#"{"agent": {"nmae": "x"}, "voices": {}}"#.utf8))
    #expect(warnings.contains("unknown key 'agent.nmae'"))
    #expect(warnings.contains("unknown key 'voices'"))
}

@Test func configOverridesDefaults() throws {
    var loaded = LoadedConfig()
    (loaded.config, _) = try PuaConfig.decode(Data(#"""
    {"agent": {"name": "Mina", "greeting": "", "system_prompt": "You are {name}."},
     "engines": {"tts": "system"}, "conversation": {"max_seconds": 60}}
    """#.utf8))
    let s = try loaded.conversationSettings(direction: .incoming)
    #expect(s.openingLine == nil)
    #expect(s.instructions.hasPrefix("You are Mina."))
    #expect(s.instructions.contains(Conversation.hangupMarker))
    #expect(s.tts == "system")
    #expect(s.maxSeconds == 60)
}

@Test func defaultGreetingDisclosesRecordingOnlyWhenRecording() {
    var s = ConversationSettings(direction: .incoming)
    #expect(s.openingLine?.contains("recorded") == false)
    s.recordDirectory = URL(fileURLWithPath: "/tmp/call")
    #expect(s.openingLine?.contains("recorded") == true)
}

@Test func unknownEngineIsAnError() {
    var s = ConversationSettings(direction: .outgoing)
    s.tts = "nope"
    #expect(throws: PuaError.self) { try Engines.make(s) }
}

@Test func sentencesAreEmittedAsTheyComplete() {
    var splitter = SentenceSplitter()
    #expect(splitter.feed("Hi there") == [])
    #expect(splitter.feed("Hi there! How are") == ["Hi there!"])
    #expect(splitter.feed("Hi there! How are you? Fine") == ["How are you?"])
    #expect(splitter.finish("Hi there! How are you? Fine") == ["Fine"])
}

@Test func hangupMarkerIsStripped() {
    let (text, hangup) = Conversation.clean("Bye now! [hangup]")
    #expect(text == "Bye now!")
    #expect(hangup)
    #expect(Conversation.clean("Take care [hangup].").0 == "Take care.")
}

@Test func callerComesFromTheRelayBannerLabel() {
    // Shape seen on a live incoming call: bidi marks around the name, the avatar initials after it.
    #expect(CallControl.caller(from: ["\u{202A}Mina \u{2764}\u{202C}, From Your iPhone", "MK"]) == "Mina \u{2764}")
    #expect(CallControl.caller(from: ["+1 555 0100, Using Your iPhone - 0:02"]) == "+1 555 0100")
    #expect(CallControl.caller(from: ["Answer", "Mina"]) == "Mina")
}

@Test func execAgentRepliesAndHangsUp() async throws {
    var s = ConversationSettings(direction: .incoming)
    s.caller = "Mina"
    s.execCommand = ["python3", URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("examples/agents/clock_agent.py").path]
    let model = try ExecReplyModel(settings: s)
    try await model.prepare()
    func collect(_ text: String) async throws -> String {
        var out = ""
        for try await piece in model.reply(to: text) { out += piece }
        return out
    }
    #expect(try await collect("what time is it").hasPrefix("It's "))
    let bye = try await collect("ok bye")
    #expect(bye.contains("Goodbye!"))
    #expect(bye.hasSuffix(Conversation.hangupMarker))
    await model.finish(summary: ["reason": "test", "transcript": []])
}

@Test func muLawRoundTripsWithinItsStepSize() {
    for sample in stride(from: -32000, through: 32000, by: 997) {
        let back = Int(G711.decode(G711.encode(Int16(sample))))
        #expect(abs(back - sample) <= max(8, abs(sample) / 16), "sample \(sample) → \(back)")
    }
    #expect(G711.encode(0) == 0xFF)
}

@Test func execAgentCanSpeakAndHangUpOnItsOwn() async throws {
    var s = ConversationSettings(direction: .outgoing)
    s.execCommand = ["/bin/sh", "-c", #"read start; echo '{"type":"say","text":"One moment."}'; echo '{"type":"hangup"}'; cat >/dev/null"#]
    let model = try ExecReplyModel(settings: s)
    try await model.prepare()
    var seen: [String] = []
    for await event in model.events! {
        switch event {
        case .say(let text): seen.append("say:\(text)")
        case .hangup: seen.append("hangup")
        }
        if seen.count == 2 { break }
    }
    #expect(seen == ["say:One moment.", "hangup"])
    await model.finish(summary: ["reason": "test", "transcript": []])
}
