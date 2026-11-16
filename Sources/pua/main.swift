import AppKit
import Foundation
import PuaKit

let version = "0.1.1"

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
  pua call answer [--caller NUMBER] [--wait SECONDS]
  pua call decline | hangup
  pua ui-dump [--app BUNDLE_ID]   AX tree of call UI, for calibrating labels during a live call

Audio route (Phone app Audio menu)
  pua route status | setup [--mic NAME] | restore

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
            let observed = CallControl.wait(for: .active, timeout: 8)
            printJSON(["ok": true, "submitted": true, "via": via,
                       "observed": observed?.json ?? CallControl.snapshot().json])
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

    case "route":
        switch args.next() {
        case "status", nil: printJSON(try PhoneRoute.status())
        case "setup": printJSON(try PhoneRoute.setup(micName: args.value("--mic") ?? "PUA Call Mic"))
        case "restore": printJSON(try PhoneRoute.restore())
        default: print(usage); exit(64)
        }

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
