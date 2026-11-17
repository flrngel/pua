import Foundation

/// `engines.llm = "exec"`: the replies come from your own program, one process per call, over
/// JSON lines on its stdin and stdout. pua keeps the phone, speech recognition, voice and
/// turn-taking; the program is the brain and can use any tools it likes.
///
/// pua → agent (stdin):
///   {"type":"call_start","direction":"incoming","caller":"…","instructions":"…","greeting":"…","locale":"en-US","recording":true}
///   {"type":"turn","id":1,"text":"what the caller said"}
///   {"type":"call_end","reason":"call_ended","seconds":42.1,"transcript":[…]}
/// agent → pua (stdout):
///   {"type":"text","text":"Let me check. "}     a piece of the reply to the current turn
///   {"type":"end_turn","hangup":false}          the reply is complete (hangup: end the call after it)
///   {"type":"say","text":"…"}                   speak without being asked, when the caller is quiet
///   {"type":"hangup"}                           end the call
///   {"type":"error","message":"…"}              the current reply failed (pua says a short apology)
///   {"type":"log","message":"…"}                written to pua's event stream
/// Anything the agent prints on stderr becomes an `agent_log` event. Spec: docs/integration.md.
public final class ExecReplyModel: ReplyModel, @unchecked Sendable {
    public let name: String
    public let events: AsyncStream<ModelEvent>?
    private let eventSink: AsyncStream<ModelEvent>.Continuation
    private let argv: [String]
    private let settings: ConversationSettings
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var current: AsyncThrowingStream<String, Error>.Continuation?
    private var turnID = 0
    private var buffer = Data()
    private var errBuffer = Data()
    private var finished = false

    public init(settings: ConversationSettings) throws {
        guard let argv = settings.execCommand, !argv.isEmpty else {
            throw PuaError("exec_command_missing", "engines.llm \"exec\" needs exec.command in the config or --exec CMD")
        }
        self.argv = argv
        self.settings = settings
        name = "exec:\((argv.count >= 3 && argv[0] == "/bin/sh" ? argv[2] : argv[0]).split(separator: " ").first.map(String.init) ?? "agent")"
        (events, eventSink) = AsyncStream<ModelEvent>.makeStream()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func prepare() async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receivedLog(h.availableData) }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let pending = locked { () -> AsyncThrowingStream<String, Error>.Continuation? in
                defer { self.current = nil }
                return self.current
            }
            pending?.finish(throwing: PuaError("agent_exited", "agent exited with status \(p.terminationStatus)"))
            if !locked({ self.finished }) {
                Events.shared.emit("agent_exited", ["status": Int(p.terminationStatus)])
            }
            eventSink.finish()
        }
        do { try process.run() } catch {
            throw PuaError("agent_start_failed", "\(argv.joined(separator: " ")): \(error)")
        }
        send([
            "type": "call_start", "direction": settings.direction.rawValue, "caller": settings.caller ?? NSNull(),
            "agent_name": settings.agentName, "instructions": settings.instructions,
            "greeting": settings.openingLine ?? NSNull(), "locale": settings.locale,
            "recording": settings.recordDirectory != nil,
        ])
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard process.isRunning else {
            throw PuaError("agent_exited", "agent exited right after start (status \(process.terminationStatus))")
        }
    }

    public func reply(to callerText: String) -> AsyncThrowingStream<String, Error> {
        let timeout = settings.execTurnTimeout
        return AsyncThrowingStream { continuation in
            let id = locked { () -> Int in
                current?.finish()
                current = continuation
                turnID += 1
                return turnID
            }
            send(["type": "turn", "id": id, "text": callerText])
            let watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                let stale = locked { () -> AsyncThrowingStream<String, Error>.Continuation? in
                    guard self.turnID == id, let c = self.current else { return nil }
                    self.current = nil
                    return c
                }
                stale?.finish(throwing: PuaError("agent_timeout", "no end_turn within \(Int(timeout)) s"))
            }
            continuation.onTermination = { _ in watchdog.cancel() }
        }
    }

    public func finish(summary: [String: Any]) async {
        guard !locked({ () -> Bool in defer { finished = true }; return finished }) else { return }
        var end = summary
        end["type"] = "call_end"
        end["files"] = nil
        send(end)
        try? stdin.fileHandleForWriting.close()
        for _ in 0..<30 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
        if process.isRunning { process.terminate() }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    // MARK: - Wire

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        do { try stdin.fileHandleForWriting.write(contentsOf: data) } catch {
            Events.shared.emit("agent_log", ["message": "write to agent failed: \(error)"])
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [Data] = locked {
            buffer.append(data)
            var out: [Data] = []
            while let nl = buffer.firstIndex(of: 0x0A) {
                out.append(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            return out
        }
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func receivedLog(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = locked {
            errBuffer.append(data)
            var out: [String] = []
            while let nl = errBuffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: errBuffer[errBuffer.startIndex..<nl], as: UTF8.self))
                errBuffer.removeSubrange(errBuffer.startIndex...nl)
            }
            return out
        }
        for line in lines where !line.isEmpty { Events.shared.emit("agent_log", ["stderr": line]) }
    }

    private func handle(_ line: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = msg["type"] as? String else {
            Events.shared.emit("agent_log", ["message": "not a JSON message", "line": String(decoding: line.prefix(200), as: UTF8.self)])
            return
        }
        let text = msg["text"] as? String ?? ""
        switch type {
        case "text":
            if let c = locked({ current }) { c.yield(text) }
            else { Events.shared.emit("agent_log", ["message": "text outside a turn ignored; use say"]) }
        case "end_turn":
            let c = locked { () -> AsyncThrowingStream<String, Error>.Continuation? in defer { current = nil }; return current }
            if (msg["hangup"] as? Bool) == true { c?.yield(" \(Conversation.hangupMarker)") }
            c?.finish()
        case "say":
            if !text.isEmpty { eventSink.yield(.say(text)) }
        case "hangup":
            eventSink.yield(.hangup)
        case "error":
            let c = locked { () -> AsyncThrowingStream<String, Error>.Continuation? in defer { current = nil }; return current }
            c?.finish(throwing: PuaError("agent_error", msg["message"] as? String ?? "agent error"))
        case "log":
            Events.shared.emit("agent_log", ["message": msg["message"] as? String ?? text])
        default:
            Events.shared.emit("agent_log", ["message": "unknown message type '\(type)'"])
        }
    }
}
