import Foundation

/// `pua listen`: waits for incoming calls relayed from the iPhone, answers them on the Mac and
/// runs a `CallSession` on each (pua's conversation, or a stream bridge to your agent), one call
/// at a time.
///
/// Per call: ring → wait `answerAfter` (the owner can still pick up) → make the session and point
/// the Phone microphone at PUA Call Mic while it rings → Accept → run the session → restore the
/// microphone → `hooks.call_ended`. Between calls the Phone app keeps its normal microphone.
public final class Listener: @unchecked Sendable {
    public struct Options {
        /// Makes the session for each call, while it rings.
        public var session: CallSessionFactory
        /// Runs once before listening, so a broken setup fails now rather than on the first call.
        /// Returns what to report in the `listening` event.
        public var preflight: @Sendable () async throws -> [String: Any] = { [:] }
        public var recordBase: URL?
        public var answerAfter: Double = 0
        /// 0: no limit.
        public var maxCalls = 0
        public var callEndedHook: [String]?
        public var micName = "PUA Call Mic"

        public init(session: @escaping CallSessionFactory) { self.session = session }
    }

    private let options: Options
    private let events = Events.shared
    private let lock = NSLock()
    private var stopped = false
    private var current: CallSession?

    public init(options: Options) { self.options = options }

    /// Stops waiting, or ends the current conversation (the call is hung up by the caller or
    /// stays up; pua does not hang up on interrupt).
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        current?.stop("interrupted")
    }

    private var isStopped: Bool { locked { stopped } }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    public func run() async throws -> [String: Any] {
        guard AX.isTrusted else { throw PuaError("accessibility_required", "grant Accessibility to this terminal/agent") }
        guard AudioDevice.find(uid: callFeedUID) != nil else {
            throw PuaError("call_feed_missing", "PUA Call Feed not found; reinstall the driver (sudo scripts/install-driver.sh)")
        }
        var ready = try await options.preflight()
        ready["answer_after"] = options.answerAfter
        ready["max_calls"] = options.maxCalls
        ready["record"] = options.recordBase?.path ?? NSNull()
        events.emit("listening", ready)
        var calls: [[String: Any]] = []
        while !isStopped, options.maxCalls == 0 || calls.count < options.maxCalls {
            guard let ring = await nextRing() else { break }
            if let call = await take(ring) { calls.append(call) }
            await settle()
        }
        Hooks.waitForRunning(timeout: 30)
        return ["ok": true, "calls": calls.count, "summaries": calls]
    }

    // MARK: - One call

    private func nextRing() async -> CallControl.Snapshot? {
        while !isStopped {
            let s = CallControl.snapshot()
            if s.state == .incoming { return s }
            await pause(0.25)
        }
        return nil
    }

    /// Answers and talks. Returns the call summary (with the transcript), or nil when the call
    /// was not answered by pua.
    private func take(_ ring: CallControl.Snapshot) async -> [String: Any]? {
        let caller: Any = ring.caller ?? NSNull()
        events.emit("ringing", ["caller": caller, "source": ring.source ?? NSNull()])
        if options.answerAfter > 0 {
            let deadline = Date().addingTimeInterval(options.answerAfter)
            while Date() < deadline {
                await pause(0.25)
                if isStopped { return nil }
                if let gone = stillRinging() { events.emit(gone, ["caller": caller]); return nil }
            }
        }

        // Prepare while it rings, so the agent speaks right after Accept.
        let info = CallInfo(direction: .incoming, caller: ring.caller,
                            recordDirectory: options.recordBase.map { CallRecording.folder(in: $0, direction: .incoming) })
        let session: CallSession
        do { session = try await options.session(info) } catch {
            events.emit("listen_error", ["stage": "session", "error": "\(error)"])
            return nil
        }
        var sessionRan = false
        defer { if !sessionRan { Task { await session.discard() } } }
        do {
            events.emit("route", try PhoneRoute.setup(micName: options.micName))
        } catch {
            events.emit("listen_error", ["stage": "route", "error": "\(error)"])
            return nil
        }
        defer { PhoneRoute.restoreAndReport() }

        if let gone = stillRinging() { events.emit(gone, ["caller": caller]); return nil }
        let watch = ConnectionWatch()
        do {
            events.emit("answering", ["source": try CallControl.perform(.answer, expectedCaller: ring.caller)])
        } catch {
            events.emit("listen_error", ["stage": "answer", "error": "\(error)"])
            return nil
        }
        guard let via = await watch.connected(timeout: 10) else {
            events.emit("answer_failed", ["caller": caller])
            return nil
        }
        events.emit("answered", ["caller": caller, "via": via])

        let interrupted = locked { current = session; return stopped }
        if interrupted { session.stop("interrupted") }
        sessionRan = true
        var summary: [String: Any]
        do { summary = try await session.run() } catch {
            events.emit("listen_error", ["stage": "session", "error": "\(error)"])
            summary = ["ok": false, "error": "\(error)"]
        }
        locked { current = nil }
        summary["caller"] = caller
        summary["answered_via"] = via
        Hooks.run(options.callEndedHook, event: "call_ended", payload: summary)
        var event = summary
        event["transcript"] = nil
        events.emit("call_finished", event)
        return summary
    }

    /// nil while the call still rings; otherwise the event that describes what happened.
    private func stillRinging() -> String? {
        switch CallControl.snapshot().state {
        case .incoming: return nil
        case .active: return "answered_elsewhere"
        default: return "missed"
        }
    }

    /// Waits until no call is ringing or active, so the same call is not taken twice and a call
    /// the owner picked up is left alone.
    private func settle() async {
        while !isStopped {
            let state = CallControl.snapshot().state
            if state == .idle || state == .unknown { return }
            await pause(0.5)
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Watches for the answered call to connect: the call UI turning active (Accessibility) or
/// callservicesd's `CallConnected` log line, whichever comes first. Start it before pressing Accept.
final class ConnectionWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var logResult: String?

    init() {
        let attached = DispatchSemaphore(value: 0)
        Thread { [self] in
            let r = CallControl.waitForConnection(timeout: 20) { attached.signal() }
            locked { logResult = r ?? "timeout" }
        }.start()
        _ = attached.wait(timeout: .now() + 3)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    /// "ax" or "callservicesd" once connected; nil if the call ended or nothing happened in time.
    func connected(timeout: Double) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let log = locked { logResult }
            if log == "connected" { return "callservicesd" }
            if log == "ended" { return nil }
            if CallControl.snapshot().state == .active { return "ax" }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }
}
