import Foundation

/// Commands from `hooks` in the config. Each gets the event payload as JSON on stdin and
/// `PUA_EVENT`, `PUA_RECORD_DIR` (when recorded) in its environment. pua does not wait for them,
/// except for up to 30 s when it exits.
public enum Hooks {
    private static let group = DispatchGroup()

    public static func run(_ argv: [String]?, event: String, payload: [String: Any]) {
        guard let argv, !argv.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        var env = ProcessInfo.processInfo.environment
        env["PUA_EVENT"] = event
        if let files = payload["files"] as? [String: String], let wav = files["wav"] {
            env["PUA_RECORD_DIR"] = (wav as NSString).deletingLastPathComponent
        }
        p.environment = env
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = FileHandle.standardError
        group.enter()
        p.terminationHandler = { proc in
            Events.shared.emit("hook_finished", ["event": event, "status": Int(proc.terminationStatus)])
            group.leave()
        }
        do { try p.run() } catch {
            group.leave()
            Events.shared.emit("hook_error", ["event": event, "error": "\(error)"])
            return
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()
    }

    public static func waitForRunning(timeout: Double) {
        _ = group.wait(timeout: .now() + timeout)
    }
}
