import ApplicationServices
import Foundation

/// Observes and controls Continuity calls through the UI that macOS shows for them:
/// the incoming-call banner (Notification Center) and the Phone app's call window.
public enum CallControl {
    public static let phoneBundleID = "com.apple.mobilephone"
    public static let faceTimeBundleID = "com.apple.FaceTime"
    public static let notificationCenterBundleID = "com.apple.notificationcenterui"

    // English and Korean labels. Extend via environment:
    // PUA_ANSWER_LABELS / PUA_DECLINE_LABELS / PUA_END_LABELS as comma-separated lists.
    static let answerLabels = labels("PUA_ANSWER_LABELS", ["Accept", "Answer", "수락", "응답", "받기"])
    static let declineLabels = labels("PUA_DECLINE_LABELS", ["Decline", "거절"])
    static let endLabels = labels("PUA_END_LABELS", ["End", "End Call", "Hang Up", "종료", "통화 종료", "끊기"])
    // A bare timer ("0:42") or one ending the relay banner label ("<contact>, Using Your iPhone - 0:02").
    static let timerPattern = try! NSRegularExpression(pattern: "(?:^|\\s)(?:[0-9]{1,2}:)?[0-9]{1,2}:[0-5][0-9]$")

    private static func labels(_ env: String, _ defaults: [String]) -> Set<String> {
        let extra = ProcessInfo.processInfo.environment[env]?.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        } ?? []
        return Set(defaults + extra)
    }

    public enum State: String { case idle, incoming, active, unknown }

    public struct Snapshot {
        public var state: State
        public var caller: String?
        public var timer: String?
        public var source: String?
        public var reason: String?

        public var json: [String: Any] {
            var o: [String: Any] = ["state": state.rawValue]
            if let caller { o["caller"] = caller }
            if let timer { o["timer"] = timer }
            if let source { o["source"] = source }
            if let reason { o["reason"] = reason }
            return o
        }
    }

    struct Scan {
        var answer: AXUIElement?
        var decline: AXUIElement?
        var end: AXUIElement?
        var timer: String?
        var texts: [String] = []
    }

    static func scan(_ root: AXUIElement) -> Scan {
        var s = Scan()
        AX.walk(root) { el, _ in
            let role = AX.role(el)
            let label = AX.label(el).trimmingCharacters(in: .whitespaces)
            if role == kAXButtonRole {
                if s.answer == nil, answerLabels.contains(label) { s.answer = el }
                if s.decline == nil, declineLabels.contains(label) { s.decline = el }
                if s.end == nil, endLabels.contains(label) { s.end = el }
            } else if role == kAXStaticTextRole || role == "AXGenericElement", !label.isEmpty {
                // The relay banner puts "<contact>, From Your iPhone" in a generic element's description.
                let range = NSRange(label.startIndex..., in: label)
                if s.timer == nil, timerPattern.firstMatch(in: label, range: range) != nil { s.timer = label }
                else if s.texts.count < 12 { s.texts.append(label) }
            }
            return true
        }
        return s
    }

    /// "<contact>, From Your iPhone" (ringing) or "<contact>, Using Your iPhone - 0:02" (active).
    static let relaySuffix = try! NSRegularExpression(pattern: ",\\s*(?:From|Using) Your iPhone.*$")

    /// Best-effort caller label: the contact or number from the relay banner, else the first text
    /// that is not a button label or a timer.
    static func caller(from texts: [String]) -> String? {
        let ignored = answerLabels.union(declineLabels).union(endLabels)
        // Labels wrap names in bidi isolation marks (U+202A…U+202E, U+2066…U+2069).
        let cleaned = texts.map { text in
            String(String.UnicodeScalarView(text.unicodeScalars.filter {
                !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
            })).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && !ignored.contains($0) }
        for text in cleaned {
            let range = NSRange(text.startIndex..., in: text)
            if let m = relaySuffix.firstMatch(in: text, range: range), let r = Range(m.range, in: text) {
                return String(text[..<r.lowerBound])
            }
        }
        return cleaned.first { $0.count <= 64 }
    }

    static func roots() -> [(String, AXUIElement)] {
        var out: [(String, AXUIElement)] = []
        if let nc = AX.app(bundleID: notificationCenterBundleID) {
            out += AX.windows(nc).map { (notificationCenterBundleID, $0) }
        }
        for id in [phoneBundleID, faceTimeBundleID] {
            if let app = AX.app(bundleID: id) { out += AX.windows(app).map { (id, $0) } }
        }
        return out
    }

    public static func snapshot() -> Snapshot {
        guard AX.isTrusted else { return Snapshot(state: .unknown, reason: "accessibility_required") }
        var incoming: Snapshot?
        for (source, root) in roots() {
            let s = scan(root)
            if s.end != nil || s.timer != nil {
                return Snapshot(state: .active, caller: caller(from: s.texts), timer: s.timer, source: source)
            }
            if s.answer != nil, s.decline != nil, incoming == nil {
                incoming = Snapshot(state: .incoming, caller: caller(from: s.texts), source: source)
            }
        }
        return incoming ?? Snapshot(state: .idle)
    }

    public enum Action: String { case answer, decline, hangup }

    /// Presses the matching control. Returns the source app on success.
    public static func perform(_ action: Action, expectedCaller: String? = nil) throws -> String {
        guard AX.isTrusted else { throw PuaError("accessibility_required", "grant Accessibility to this terminal/agent") }
        var matches: [(String, AXUIElement, String?)] = []
        for (source, root) in roots() {
            let s = scan(root)
            let target: AXUIElement?
            switch action {
            case .answer: target = s.answer
            case .decline: target = s.decline
            case .hangup: target = s.end ?? s.decline
            }
            if let target { matches.append((source, target, caller(from: s.texts))) }
        }
        if let expectedCaller {
            let digits = { (x: String) in x.filter(\.isNumber) }
            matches = matches.filter { m in
                guard let c = m.2 else { return false }
                return c == expectedCaller || (!digits(expectedCaller).isEmpty && digits(c).hasSuffix(digits(expectedCaller).suffix(8)))
            }
        }
        guard !matches.isEmpty else { throw PuaError("no_call_control", "no \(action.rawValue) control is visible") }
        // The banner and the Phone window can both show the same call; two different callers
        // (call waiting) are ambiguous.
        guard Set(matches.map { $0.2 ?? "" }).count == 1 else {
            throw PuaError("ambiguous_controls", "\(matches.count) \(action.rawValue) controls are visible")
        }
        guard AX.press(matches[0].1) else { throw PuaError("press_failed", "AXPress failed") }
        return matches[0].0
    }

    /// macOS posts a FaceTime notification instead of placing the call when Continuity calling is
    /// off on the iPhone ("iPhone Calls Not Available"). Returns its text, if shown.
    static let relayUnavailableMarkers = ["iPhone Calls Not Available", "not configured to allow calls"]

    public static func relayUnavailableNotice(dismiss: Bool = false) -> String? {
        guard AX.isTrusted, let app = AX.app(bundleID: notificationCenterBundleID) else { return nil }
        for window in AX.windows(app) {
            var notice: String?
            var cancel: AXUIElement?
            AX.walk(window, maxDepth: 10) { el, _ in
                let label = AX.label(el)
                if notice == nil, relayUnavailableMarkers.contains(where: { label.contains($0) }) { notice = label }
                if notice != nil, cancel == nil, AX.role(el) == kAXButtonRole, label == "Cancel" { cancel = el }
                return true
            }
            if let notice {
                if dismiss, let cancel { AX.press(cancel) }
                return notice
            }
        }
        return nil
    }

    /// Waits for callservicesd to log that the relayed call connected or ended. On the Mac every
    /// cellular call is a relay call, and the host iPhone sends `CallConnected` when the far end
    /// answers. Unlike the call UI (whose timer is not exposed to AX), this is language-independent.
    /// Returns "connected", "ended", or nil on timeout. `ready` runs once the log stream is attached.
    public static func waitForConnection(timeout: TimeInterval, ready: (() -> Void)? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        p.arguments = ["stream", "--style", "compact", "--predicate",
                       #"process == "callservicesd" AND (eventMessage CONTAINS "CallConnected message" OR eventMessage CONTAINS "with disconnected call")"#]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        defer { if p.isRunning { p.terminate() } }
        let lock = NSLock()
        var result: String?
        var pending = ""
        let done = DispatchSemaphore(value: 0)
        let attached = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            lock.lock(); defer { lock.unlock() }
            pending += text
            var lines = pending.components(separatedBy: "\n")
            pending = lines.removeLast()
            for line in lines {
                // The stream echoes the predicate in a header; only timestamped lines are events.
                guard let first = line.first, first.isNumber else { attached.signal(); continue }
                guard result == nil else { continue }
                if line.contains("CallConnected message") { result = "connected"; done.signal() }
                else if line.contains("with disconnected call") { result = "ended"; done.signal() }
            }
        }
        _ = attached.wait(timeout: .now() + 3)
        ready?()
        _ = done.wait(timeout: .now() + timeout)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return result
    }

    /// Polls until `state` is reached or the timeout passes.
    public static func wait(for state: State, timeout: TimeInterval) -> Snapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let s = snapshot()
            if s.state == state { return s }
            usleep(250_000)
        } while Date() < deadline
        return nil
    }
}
