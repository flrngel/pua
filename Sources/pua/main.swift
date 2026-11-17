import ApplicationServices
import AppKit
import Foundation
import PuaKit

let version = "0.4.0"

let usage = """
pua \(version): tunnel iPhone (Continuity) calls on a Mac to an agent

Setup and status
  pua doctor                      prerequisites, each with its next action (JSON)
  pua permissions                 ask macOS to list this terminal under Accessibility
  pua devices                     Core Audio devices (JSON)
  pua processes                   Core Audio client processes; find the call renderer during a call
  pua selftest                    prove the tap (downlink) and PUA Call Mic (uplink) legs, no call needed
  pua shortcut install [--name N] build, sign and import the "PUA Dial" shortcut

Calls
  pua call state [--watch]        idle | incoming | active (+ caller, timer)
  pua call dial NUMBER [--via shortcut|tel] [--shortcut NAME]
  pua call wait-connected [--timeout S]  block until the current call connects (callservicesd log)
  pua call answer [--caller NUMBER] [--wait SECONDS]
  pua call decline | hangup
  pua ui-dump [--app BUNDLE_ID]   AX tree of call UI, for calibrating labels during a live call
  pua ui-press --app BUNDLE_ID --label L [--label L2]  press a visible button by label

Audio route (Phone app Audio menu)
  pua route status | setup [--mic NAME] | restore

Conversation (on-device speech recognition + language model; settings: docs/configuration.md)
  pua converse [--dial NUMBER] [--route] [--record DIR] [conversation flags]
                                  talk on an outgoing or already connected call
  pua listen [--answer-after S] [--max-calls N | --once] [--record DIR] [conversation flags]
                                  wait for incoming calls, answer each and talk (Ctrl-C stops)
  pua config show [--config FILE] the resolved settings and where they came from
    conversation flags (override the config file):
      --config FILE  --name NAME  --instructions TEXT | --instructions-file F
      --greeting TEXT | --no-greeting  --locale ID  --stt NAME  --llm NAME
      --tts system|elevenlabs  --voice ID  --tts-model ID  --max-seconds N  --end-silence S
      --no-hangup  --no-call-guard  --pid PID  --process BUNDLE_ID

Duplex audio (stdin PCM16 LE 48 kHz mono → caller; stdout ← caller; stderr JSONL)
  pua audio-stream [--route] [--monitor] [--max-seconds N] [--stop-after-playback]
                   [--process BUNDLE_ID | --pid PID ...] [--no-call-guard]
                   [--capture-only | --playback-only]
"""

func printJSON(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ error: Error) -> Never {
    let e = error as? PuaError
    printJSON(["ok": false, "error": e?.code ?? "error", "message": e?.message ?? "\(error)"])
    exit(1)
}

struct Args {
    var items: [String]
    mutating func flag(_ name: String) -> Bool {
        guard let i = items.firstIndex(of: name) else { return false }
        items.remove(at: i); return true
    }
    mutating func value(_ name: String) -> String? {
        guard let i = items.firstIndex(of: name), i + 1 < items.count else { return nil }
        let v = items[i + 1]; items.removeSubrange(i...(i + 1)); return v
    }
    mutating func values(_ name: String) -> [String] {
        var out: [String] = []
        while let v = value(name) { out.append(v) }
        return out
    }
    mutating func next() -> String? { items.isEmpty ? nil : items.removeFirst() }
}

/// Config file, then command-line flags. Consumes the conversation flags from `args`.
func conversationSettings(_ direction: ConversationSettings.Direction, _ loaded: LoadedConfig,
                          _ args: inout Args) throws -> (ConversationSettings, Conversation.CallAudio) {
    var s = try loaded.conversationSettings(direction: direction)
    if let v = args.value("--name") { s.agentName = v }
    if let f = args.value("--instructions-file") { s.systemPrompt = try String(contentsOfFile: f, encoding: .utf8) }
    if let v = args.value("--instructions") { s.systemPrompt = v }
    if args.flag("--no-greeting") { s.greeting = .none } else if let v = args.value("--greeting") { s.greeting = .custom(v) }
    if let v = args.value("--locale") { s.locale = v }
    if let v = args.value("--stt") { s.stt = v }
    if let v = args.value("--llm") { s.llm = v }
    if let v = args.value("--tts") { s.tts = v }
    if let v = args.value("--voice") { s.voiceID = v }
    if let v = args.value("--tts-model") { s.voiceModel = v }
    if let v = args.value("--max-seconds").flatMap(Double.init) { s.maxSeconds = v }
    if let v = args.value("--end-silence").flatMap(Double.init) { s.endOfTurnSilence = v }
    if args.flag("--no-hangup") { s.hangUpWhenDone = false }
    var audio = Conversation.CallAudio()
    if let p = args.value("--process") { audio.bundleID = p }
    audio.pids = args.values("--pid").compactMap { pid_t($0) }
    audio.callGuard = !args.flag("--no-call-guard")
    return (s, audio)
}

func loadConfig(_ args: inout Args) throws -> LoadedConfig {
    let loaded = try LoadedConfig.load(explicit: args.value("--config"))
    for w in loaded.warnings { Events.shared.emit("config_warning", ["warning": w, "file": loaded.path?.path ?? ""]) }
    return loaded
}

/// Runs async work from the synchronous command switch. Ctrl-C calls `interrupt`.
func runAsync(interrupt: @escaping @Sendable () -> Void, _ body: @escaping @Sendable () async throws -> [String: Any]) throws -> [String: Any] {
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { interrupt() }
    sigint.resume()
    final class Box: @unchecked Sendable { var result: [String: Any]?; var error: Error?; var done = false }
    let box = Box()
    Task {
        do { box.result = try await body() } catch { box.error = error }
        box.done = true
    }
    while !box.done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    sigint.cancel()
    if let error = box.error { throw error }
    return box.result ?? [:]
}

var args = Args(items: Array(CommandLine.arguments.dropFirst()))
guard let command = args.next() else { print(usage); exit(0) }

do {
    switch command {
    case "version", "--version", "-v":
        print(version)

    case "help", "--help", "-h":
        print(usage)

    case "doctor":
        let checks = Doctor.run()
        printJSON(["ok": checks.allSatisfy(\.ok), "version": version, "checks": checks.map(\.json),
                   "required_actions": checks.compactMap(\.action)])

    case "permissions":
        let trusted = AX.requestTrust()
        printJSON(["accessibility": trusted,
                   "note": trusted ? "already trusted" : "enable this terminal in System Settings > Privacy & Security > Accessibility, then rerun"])

    case "devices":
        printJSON(AudioDevice.all().map(\.json))

    case "processes":
        printJSON(AudioProcess.all().map(\.json))

    case "selftest":
        let results = [SelfTest.downlink(), SelfTest.uplink()]
        printJSON(["ok": results.allSatisfy(\.ok), "results": results.map(\.json)])
        exit(results.allSatisfy(\.ok) ? 0 : 2)

    case "shortcut":
        guard args.next() == "install" else { print(usage); exit(64) }
        let name = args.value("--name") ?? Dialer.defaultShortcutName
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/pua")
        let file = try Dialer.buildShortcut(name: name, in: dir)
        if !args.flag("--no-import") { try Dialer.importShortcut(file, name: name) }
        printJSON(["ok": true, "file": file.path, "installed": Dialer.shortcutInstalled(name),
                   "next": "the first dial asks to allow the Call action once"])

    case "call":
        switch args.next() {
        case "state":
            if args.flag("--watch") {
                var last = ""
                while true {
                    let s = CallControl.snapshot().json
                    let line = String(data: try JSONSerialization.data(withJSONObject: s, options: [.sortedKeys]), encoding: .utf8)!
                    if line != last { print(line); fflush(stdout); last = line }
                    usleep(500_000)
                }
            }
            printJSON(CallControl.snapshot().json)
        case "dial":
            guard let number = args.next() else { print(usage); exit(64) }
            let via = args.value("--via") ?? "shortcut"
            if via == "tel" { try Dialer.dialViaTel(number) }
            else { try Dialer.dialViaShortcut(number, shortcut: args.value("--shortcut") ?? Dialer.defaultShortcutName) }
            // The iPhone can reject a relay call ~0.5 s after the outgoing banner appears, so keep
            // watching for the "iPhone Calls Not Available" notice for 3 s after the call UI shows.
            var observed: CallControl.Snapshot?
            var deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let notice = CallControl.relayUnavailableNotice(dismiss: true) {
                    throw PuaError("iphone_calls_unavailable", "\(notice) On the iPhone: Settings > Apps > Phone > "
                        + "Calls on Other Devices > turn on Allow Calls on Other Devices and this Mac (same Apple Account).")
                }
                let s = CallControl.snapshot()
                if s.state == .active, observed == nil {
                    observed = s
                    deadline = min(deadline, Date().addingTimeInterval(3))
                }
                usleep(250_000)
            }
            printJSON(["ok": true, "submitted": true, "via": via,
                       "observed": observed?.json ?? CallControl.snapshot().json])
        case "wait-connected":
            // Prints a line once attached, so a script can dial after it.
            let timeout = args.value("--timeout").flatMap(Double.init) ?? 120
            let result = CallControl.waitForConnection(timeout: timeout) {
                Events.shared.emit("listening", [:])
            }
            printJSON(["ok": result == "connected", "state": result ?? "timeout"])
            if result != "connected" { exit(1) }
        case "answer":
            let caller = args.value("--caller")
            if let wait = args.value("--wait").flatMap(Double.init) {
                guard CallControl.wait(for: .incoming, timeout: wait) != nil else {
                    throw PuaError("incoming_wait_timeout", "no incoming call within \(Int(wait)) s")
                }
            }
            let source = try CallControl.perform(.answer, expectedCaller: caller)
            let observed = CallControl.wait(for: .active, timeout: 5)
            printJSON(["ok": true, "source": source, "observed": observed?.json ?? CallControl.snapshot().json])
        case "decline":
            printJSON(["ok": true, "source": try CallControl.perform(.decline)])
        case "hangup", "end":
            let source = try CallControl.perform(.hangup)
            let observed = CallControl.wait(for: .idle, timeout: 5)
            printJSON(["ok": true, "source": source, "observed": observed?.json ?? CallControl.snapshot().json])
        default:
            print(usage); exit(64)
        }

    case "ui-dump":
        let ids = args.values("--app")
        let targets = ids.isEmpty ? [CallControl.notificationCenterBundleID, CallControl.phoneBundleID] : ids
        for id in targets {
            print("== \(id)")
            guard let app = AX.app(bundleID: id) else { print("(not running)"); continue }
            for w in AX.windows(app) { print(AX.dump(w)) }
        }

    case "ui-press":
        // Presses the first button whose label is one of --label (in order of preference).
        guard let id = args.value("--app") else { print(usage); exit(64) }
        let wanted = args.values("--label")
        guard !wanted.isEmpty else { print(usage); exit(64) }
        guard let app = AX.app(bundleID: id) else { printJSON(["ok": false, "reason": "not_running", "app": id]); exit(1) }
        var found: [String: AXUIElement] = [:]
        for w in AX.windows(app) {
            AX.walk(w, maxDepth: 10) { el, _ in
                let label = AX.label(el)
                if AX.role(el) == kAXButtonRole, wanted.contains(label), found[label] == nil { found[label] = el }
                return true
            }
        }
        guard let label = wanted.first(where: { found[$0] != nil }), AX.press(found[label]!) else {
            printJSON(["ok": false, "reason": "no_button", "app": id]); exit(1)
        }
        printJSON(["ok": true, "app": id, "pressed": label])

    case "route":
        switch args.next() {
        case "status", nil: printJSON(try PhoneRoute.status())
        case "setup": printJSON(try PhoneRoute.setup(micName: args.value("--mic") ?? "PUA Call Mic"))
        case "restore": printJSON(try PhoneRoute.restore())
        default: print(usage); exit(64)
        }

    case "converse":
        let loaded = try loadConfig(&args)
        var (settings, audio) = try conversationSettings(.outgoing, loaded, &args)
        settings.recordDirectory = args.value("--record").map { URL(fileURLWithPath: $0) } ?? loaded.callFolder(direction: .outgoing)
        let dial = args.value("--dial")
        let route = args.flag("--route") || dial != nil
        final class Current: @unchecked Sendable { var conversation: Conversation? }
        let current = Current()
        let summary = try runAsync(interrupt: {
            if let c = current.conversation { c.stop("interrupted") } else {
                if route { _ = try? PhoneRoute.restore() }
                exit(130)
            }
        }) {
            // Prepare before dialing: a missing model or key fails before anyone's phone rings.
            let engines = try Engines.make(settings)
            try await engines.prepare()
            if route { Events.shared.emit("route", try PhoneRoute.setup(micName: "PUA Call Mic")) }
            defer { if route { Events.shared.emit("route_restored", (try? PhoneRoute.restore()) ?? [:]) } }
            if let number = dial {
                let ready = DispatchSemaphore(value: 0)
                let done = DispatchSemaphore(value: 0)
                final class Result: @unchecked Sendable { var value: String? }
                let connected = Result()
                Thread {
                    connected.value = CallControl.waitForConnection(timeout: 120) { ready.signal() }
                    done.signal()
                }.start()
                _ = ready.wait(timeout: .now() + 3)
                try Dialer.dialViaShortcut(number)
                Events.shared.emit("dialed")
                while done.wait(timeout: .now() + 0.25) == .timedOut {
                    if let notice = CallControl.relayUnavailableNotice(dismiss: true) {
                        throw PuaError("iphone_calls_unavailable", notice)
                    }
                }
                guard connected.value == "connected" else {
                    throw PuaError("not_connected", "call \(connected.value ?? "timed out") before answer")
                }
                Events.shared.emit("connected")
            }
            let conversation = Conversation(settings: settings, engines: engines, audio: audio)
            current.conversation = conversation
            let summary = try await conversation.run()
            Hooks.run(loaded.callEndedHook, event: "call_ended", payload: summary)
            Hooks.waitForRunning(timeout: 30)
            return summary
        }
        printJSON(summary)

    case "listen":
        let loaded = try loadConfig(&args)
        let (settings, audio) = try conversationSettings(.incoming, loaded, &args)
        var o = Listener.Options(settings: settings)
        o.audio = audio
        o.recordBase = args.value("--record").map { URL(fileURLWithPath: $0) } ?? loaded.recordBase
        o.answerAfter = args.value("--answer-after").flatMap(Double.init) ?? loaded.answerAfter
        o.maxCalls = args.flag("--once") ? 1 : (args.value("--max-calls").flatMap(Int.init) ?? loaded.maxCalls)
        o.callEndedHook = loaded.callEndedHook
        let listener = Listener(options: o)
        let summary = try runAsync(interrupt: { listener.stop() }) { try await listener.run() }
        printJSON(summary)

    case "config":
        guard args.next() == "show" else { print(usage); exit(64) }
        let loaded = try LoadedConfig.load(explicit: args.value("--config"))
        printJSON([
            "file": loaded.path?.path ?? NSNull(),
            "lookup": ["--config FILE", "$PUA_CONFIG", LoadedConfig.defaultPath],
            "warnings": loaded.warnings,
            "outgoing": try loaded.conversationSettings(direction: .outgoing).json,
            "incoming": try loaded.conversationSettings(direction: .incoming).json,
            "listen": ["answer_after": loaded.answerAfter, "max_calls": loaded.maxCalls],
            "record_directory": loaded.recordBase?.path ?? NSNull(),
            "hooks": ["call_ended": loaded.callEndedHook ?? []],
            "engines_available": ["stt": Engines.recognizers.keys.sorted(), "llm": Engines.models.keys.sorted(),
                                  "tts": Engines.voices.keys.sorted()],
        ])

    case "audio-stream":
        var o = AudioStreamSession.Options()
        if let p = args.value("--process") { o.bundleID = p }
        o.pids = args.values("--pid").compactMap { pid_t($0) }
        o.route = args.flag("--route")
        o.muteLocal = !args.flag("--monitor")
        o.maxSeconds = args.value("--max-seconds").flatMap(Double.init)
        o.stopAfterPlayback = args.flag("--stop-after-playback")
        o.callGuard = !args.flag("--no-call-guard")
        if args.flag("--capture-only") { o.playbackEnabled = false }
        if args.flag("--playback-only") { o.captureEnabled = false }
        if let mic = args.value("--mic-uid") { o.micUID = mic }
        exit(try AudioStreamSession(options: o).run())

    default:
        print(usage); exit(64)
    }
} catch {
    fail(error)
}
