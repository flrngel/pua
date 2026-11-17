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
}
