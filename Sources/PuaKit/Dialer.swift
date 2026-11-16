import AppKit
import Foundation

/// Outbound calls. The default path runs an Apple Shortcut that wraps the Phone "Call" action
/// (`com.apple.mobilephone.call`). `tel:` is a fallback that needs a click to confirm.
public enum Dialer {
    public static let defaultShortcutName = "PUA Dial"
    static let numberPattern = try! NSRegularExpression(pattern: "^\\+?[0-9][0-9 ()-]{2,24}$")

    public static func validate(_ number: String) throws -> String {
        let range = NSRange(number.startIndex..., in: number)
        guard numberPattern.firstMatch(in: number, range: range) != nil else {
            throw PuaError("invalid_number", "expected digits with optional +, spaces, () or -")
        }
        return number
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 30) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { usleep(50_000) }
        if p.isRunning {
            p.terminate()
            throw PuaError("timeout", "\(tool) did not finish within \(Int(timeout)) s")
        }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, out)
    }

    public static func shortcutInstalled(_ name: String = defaultShortcutName) -> Bool {
        guard let (code, out) = try? run("/usr/bin/shortcuts", ["list"], timeout: 15), code == 0 else { return false }
        return out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }

    /// Dials through the shortcut. The first run shows a Shortcuts permission prompt for the
    /// Call action; the owner approves it once.
    public static func dialViaShortcut(_ number: String, shortcut: String = defaultShortcutName) throws {
        let number = try validate(number)
        guard shortcutInstalled(shortcut) else {
            throw PuaError("shortcut_missing", "Shortcut '\(shortcut)' not found; run `pua shortcut install`")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pua-dial-\(UUID().uuidString).txt")
        try number.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let (code, out) = try run("/usr/bin/shortcuts", ["run", shortcut, "--input-path", file.path], timeout: 60)
        guard code == 0 else {
            throw PuaError("shortcut_failed", "shortcuts exited \(code): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Opens `tel:`; macOS asks the user to confirm the call.
    public static func dialViaTel(_ number: String) throws {
        let number = try validate(number).filter { $0 == "+" || $0.isNumber }
        guard let url = URL(string: "tel:\(number)"), NSWorkspace.shared.open(url) else {
            throw PuaError("open_failed", "could not open tel: URL")
        }
    }

    // MARK: - Shortcut generation

    /// The unsigned workflow: Get Text (Shortcut Input as text) → Call.
    static func workflow() -> [String: Any] {
        let textUUID = UUID().uuidString
        return [
            "WFWorkflowClientVersion": "5114.0.6.204",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowHasShortcutInputVariables": true,
            "WFWorkflowHasOutputFallback": false,
            "WFWorkflowIcon": ["WFWorkflowIconGlyphNumber": 59511, "WFWorkflowIconStartColor": 4_282_601_983],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.gettext",
                    "WFWorkflowActionParameters": [
                        "UUID": textUUID,
                        "WFTextActionText": [
                            "WFSerializationType": "WFTextTokenString",
                            "Value": [
                                "string": "\u{FFFC}",
                                "attachmentsByRange": [
                                    "{0, 1}": [
                                        "Type": "ExtensionInput",
                                        "Aggrandizements": [[
                                            "Type": "WFCoercionVariableAggrandizement",
                                            "CoercionItemClass": "WFStringContentItem",
                                        ]],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
                [
                    "WFWorkflowActionIdentifier": "com.apple.mobilephone.call",
                    "WFWorkflowActionParameters": [
                        "UUID": UUID().uuidString,
                        "WFCallContact": [
                            "WFSerializationType": "WFTextTokenAttachment",
                            "Value": ["Type": "ActionOutput", "OutputName": "Text", "OutputUUID": textUUID],
                        ],
                    ],
                ],
            ],
        ]
    }

    /// Writes `<dir>/<name>.shortcut`, signs it with `shortcuts sign`, and returns the signed file.
    /// Importing it (double-click or `open`) asks the owner to confirm in Shortcuts.
    public static func buildShortcut(name: String = defaultShortcutName, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unsigned = dir.appendingPathComponent("\(name).unsigned.shortcut")
        let signed = dir.appendingPathComponent("\(name).shortcut")
        let data = try PropertyListSerialization.data(fromPropertyList: workflow(), format: .binary, options: 0)
        try data.write(to: unsigned, options: .atomic)
        try? FileManager.default.removeItem(at: signed)
        let (code, out) = try run("/usr/bin/shortcuts", ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path], timeout: 60)
        try? FileManager.default.removeItem(at: unsigned)
        guard code == 0, FileManager.default.fileExists(atPath: signed.path) else {
            throw PuaError("sign_failed", "shortcuts sign exited \(code): \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return signed
    }
}
