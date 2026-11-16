import AppKit
import ApplicationServices
import Foundation

/// Thin Accessibility helpers. Requires the hosting process (your terminal or agent) to be listed
/// under System Settings > Privacy & Security > Accessibility.
public enum AX {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds the current host app to the Accessibility list.
    @discardableResult
    public static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func app(bundleID: String) -> AXUIElement? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let el = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 1.0)
        return el
    }

    public static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    public static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    public static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    public static func role(_ el: AXUIElement) -> String { string(el, kAXRoleAttribute) ?? "" }
    public static func title(_ el: AXUIElement) -> String { string(el, kAXTitleAttribute) ?? "" }
    public static func identifier(_ el: AXUIElement) -> String { string(el, kAXIdentifierAttribute) ?? "" }

    /// Human-visible label: title, else description, else value.
    public static func label(_ el: AXUIElement) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s = string(el, name), !s.isEmpty { return s }
        }
        return ""
    }

    @discardableResult
    public static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    /// Breadth-first walk with a node budget so a large UI cannot stall a call action.
    public static func walk(_ root: AXUIElement, maxDepth: Int = 12, budget: Int = 4_000,
                            _ visit: (AXUIElement, Int) -> Bool) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var seen = 0
        while !queue.isEmpty, seen < budget {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if !visit(el, depth) { return }
            if depth < maxDepth { queue.append(contentsOf: children(el).map { ($0, depth + 1) }) }
        }
    }

    public static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Text dump used by `pua ui-dump` to calibrate label matching during a live call.
    public static func dump(_ root: AXUIElement, maxDepth: Int = 10) -> String {
        var lines: [String] = []
        func rec(_ el: AXUIElement, _ depth: Int) {
            let parts = [
                role(el),
                title(el).isEmpty ? nil : "title=\(title(el))",
                (string(el, kAXDescriptionAttribute) ?? "").isEmpty ? nil : "desc=\(string(el, kAXDescriptionAttribute)!)",
                identifier(el).isEmpty ? nil : "id=\(identifier(el))",
                (string(el, kAXValueAttribute) ?? "").isEmpty ? nil : "value=\(string(el, kAXValueAttribute)!.prefix(60))",
            ].compactMap { $0 }
            lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
            guard depth < maxDepth else { return }
            for c in children(el) { rec(c, depth + 1) }
        }
        rec(root, 0)
        return lines.joined(separator: "\n")
    }
}
