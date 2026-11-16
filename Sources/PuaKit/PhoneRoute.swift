import AppKit
import ApplicationServices
import Foundation

/// Selects the Phone app's microphone and speaker through its "Audio" menu
/// (menu bar item id `com.apple.facetime.menu.video`), keeping a journal so the
/// previous choice can be restored. See docs/analysis/local-probes.md (P3).
public enum PhoneRoute {
    public static let audioMenuID = "com.apple.facetime.menu.video"
    static var journalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/pua/route.json")
    }

    public enum Section: String { case microphone, output }

    public struct Item {
        public let title: String
        public let identifier: String
        public let selected: Bool
        let element: AXUIElement
    }

    public struct Menu {
        public var microphone: [Item] = []
        public var output: [Item] = []
        public func items(_ s: Section) -> [Item] { s == .microphone ? microphone : output }
        public func selected(_ s: Section) -> Item? { items(s).first(where: \.selected) }
    }

    static func phoneApp() throws -> AXUIElement {
        guard AX.isTrusted else { throw PuaError("accessibility_required", "grant Accessibility to this terminal/agent") }
        guard let app = AX.app(bundleID: CallControl.phoneBundleID) else {
            throw PuaError("phone_not_running", "open the Phone app first (open -a Phone)")
        }
        return app
    }

    /// Reads the Audio menu. Sections are found by structure (a titled item without identifier
    /// starts a section; the first is Microphone, the second Output), so it is language-independent.
    static func audioMenu() throws -> (bar: AXUIElement, menu: AXUIElement) {
        let app = try phoneApp()
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { throw PuaError("menu_unavailable", "Phone menu bar unavailable") }
        guard let audio = AX.children(bar).first(where: { AX.identifier($0) == audioMenuID }),
              let menu = AX.children(audio).first else {
            throw PuaError("menu_unavailable", "Phone Audio menu unavailable")
        }
        return (audio, menu)
    }

    public static func read() throws -> Menu {
        let menu = try audioMenu().menu
        var result = Menu()
        var sectionIndex = -1
        for item in AX.children(menu) {
            let title = AX.title(item)
            let id = AX.identifier(item)
            if title.isEmpty { continue }  // separator
            if id.isEmpty {
                // Section header ("Microphone", "Output", or localized). Items before the first
                // header (Mute, Always on Top, …) carry identifiers and are skipped below.
                sectionIndex += 1
                continue
            }
            guard sectionIndex == 0 || sectionIndex == 1 else { continue }
            let mark = AX.string(item, kAXMenuItemMarkCharAttribute) ?? ""
            let entry = Item(title: title, identifier: id, selected: !mark.isEmpty, element: item)
            if sectionIndex == 0 { result.microphone.append(entry) } else { result.output.append(entry) }
        }
        guard !result.microphone.isEmpty else {
            throw PuaError("menu_unsupported", "unexpected Phone Audio menu structure")
        }
        return result
    }

    /// Selects an item by exact title, or `system` for "Use System Setting".
    public static func select(_ section: Section, _ name: String) throws {
        let menu = try read()
        let items = menu.items(section)
        let wanted = name == "system"
            ? items.filter { $0.identifier == "use_system_setting" }
            : items.filter { $0.title == name }
        guard wanted.count == 1, let item = wanted.first else {
            throw PuaError("device_not_listed", "\(section.rawValue) '\(name)' is missing or ambiguous in the Phone Audio menu")
        }
        if item.selected { return }
        // AXPress on a menu item reports success without effect unless the Phone app owns the
        // active menu bar and the menu is open. Bring Phone forward briefly, open the Audio menu,
        // press the item (which closes the menu), then give focus back to the previous app.
        let previous = NSWorkspace.shared.frontmostApplication
        if let phone = NSRunningApplication.runningApplications(withBundleIdentifier: CallControl.phoneBundleID).first,
           previous?.processIdentifier != phone.processIdentifier {
            phone.activate()
            usleep(400_000)
        }
        defer {
            if let previous, previous.bundleIdentifier != CallControl.phoneBundleID { previous.activate() }
        }
        let (barItem, menuElement) = try audioMenu()
        AX.press(barItem)
        usleep(300_000)
        let fresh = AX.children(menuElement).first { AX.identifier($0) == item.identifier && AX.title($0) == item.title } ?? item.element
        guard AX.press(fresh) else {
            AXUIElementPerformAction(menuElement, kAXCancelAction as CFString)
            throw PuaError("press_failed", "AXPress failed on '\(item.title)'")
        }
        for _ in 0..<20 {
            usleep(100_000)
            if (try? read().selected(section)?.identifier) == item.identifier { return }
        }
        AXUIElementPerformAction(menuElement, kAXCancelAction as CFString)
        // Phone ignores devices that are listed but unusable (e.g. the built-in mic with the lid closed).
        throw PuaError("selection_unsettled", "selection of '\(item.title)' did not settle (device unavailable?)")
    }

    // MARK: - Journal

    /// Saves the current selections (once) and routes the Phone microphone to `micName`.
    public static func setup(micName: String) throws -> [String: Any] {
        let menu = try read()
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            let journal: [String: String] = [
                "microphone": menu.selected(.microphone).map { $0.identifier == "use_system_setting" ? "system" : $0.title } ?? "system",
                "output": menu.selected(.output).map { $0.identifier == "use_system_setting" ? "system" : $0.title } ?? "system",
            ]
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: journalURL, options: .atomic)
        }
        try select(.microphone, micName)
        return try status()
    }

    /// Restores the journaled selections and removes the journal.
    public static func restore() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: journalURL),
              let journal = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return ["restored": false, "reason": "no_journal"]
        }
        if let mic = journal["microphone"] { try select(.microphone, mic) }
        if let out = journal["output"] { try select(.output, out) }
        try? FileManager.default.removeItem(at: journalURL)
        var s = try status()
        s["restored"] = true
        return s
    }

    public static func status() throws -> [String: Any] {
        let menu = try read()
        return [
            "microphone": menu.selected(.microphone)?.title ?? NSNull(),
            "output": menu.selected(.output)?.title ?? NSNull(),
            "microphones": menu.microphone.map(\.title),
            "outputs": menu.output.map(\.title),
            "journal_pending": FileManager.default.fileExists(atPath: journalURL.path),
        ]
    }
}
