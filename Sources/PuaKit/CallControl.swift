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
    static let timerPattern = try! NSRegularExpression(pattern: "^(?:[0-9]{1,2}:)?[0-9]{1,2}:[0-5][0-9]$")

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
            } else if role == kAXStaticTextRole, !label.isEmpty {
                let range = NSRange(label.startIndex..., in: label)
                if s.timer == nil, timerPattern.firstMatch(in: label, range: range) != nil { s.timer = label }
                else if s.texts.count < 12 { s.texts.append(label) }
            }
            return true
        }
        return s
    }

    /// Best-effort caller label: the first static text that is not a button label or a timer.
    static func caller(from texts: [String]) -> String? {
        let ignored = answerLabels.union(declineLabels).union(endLabels)
        return texts.first { !ignored.contains($0) && $0.count <= 64 }
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
        guard matches.count == 1 else { throw PuaError("ambiguous_controls", "\(matches.count) \(action.rawValue) controls are visible") }
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
