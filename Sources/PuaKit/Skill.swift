import Foundation

/// The phone-use skill (skills/phone-use/SKILL.md): teaches agent harnesses such as Claude Code
/// and Codex to place, answer and report calls with pua. `pua skill install` copies it into the
/// harnesses' skill folders and adds this pua's path.
public enum PhoneUseSkill {
    public static let name = "phone-use"
    public static var markdown: String { SkillText.markdown + "\n" }
    static let marker = "installed by `pua skill install`"

    /// Skill folders to install into when none are given: Claude Code's, when it is set up, and
    /// the shared `~/.agents/skills` that Codex, Gemini CLI and other harnesses read.
    public static func defaultFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var out: [URL] = []
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) {
            out.append(home.appendingPathComponent(".claude/skills"))
        }
        out.append(home.appendingPathComponent(".agents/skills"))
        return out
    }

    /// The installed SKILL.md: the skill, plus where this pua lives.
    public static func installedText(puaPath: String, version: String) -> String {
        markdown + """

        ## On this Mac

        pua is at `\(puaPath)` (version \(version)), \(marker). Run it by that path.

        """
    }

    /// Writes `<folder>/phone-use/SKILL.md` into each folder. Returns one result per folder.
    public static func install(into folders: [URL], puaPath: String, version: String) -> [[String: Any]] {
        let text = installedText(puaPath: puaPath, version: version)
        return folders.map { folder in
            let file = folder.appendingPathComponent(name).appendingPathComponent("SKILL.md")
            do {
                let existing = try? String(contentsOf: file, encoding: .utf8)
                if let existing, !existing.contains(marker) {
                    return ["path": file.path, "ok": false, "error": "a different phone-use skill is already there; remove it first"]
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
                return ["path": file.path, "ok": true, "action": existing == nil ? "installed" : (existing == text ? "unchanged" : "updated")]
            } catch {
                return ["path": file.path, "ok": false, "error": "\(error.localizedDescription)"]
            }
        }
    }

    /// Removes skills that `install` wrote; leaves anything else alone.
    public static func uninstall(from folders: [URL]) -> [[String: Any]] {
        folders.map { folder in
            let dir = folder.appendingPathComponent(name)
            let file = dir.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                return ["path": dir.path, "ok": true, "action": "absent"]
            }
            guard text.contains(marker) else {
                return ["path": dir.path, "ok": false, "error": "not installed by pua; left alone"]
            }
            do {
                try FileManager.default.removeItem(at: dir)
                return ["path": dir.path, "ok": true, "action": "removed"]
            } catch {
                return ["path": dir.path, "ok": false, "error": "\(error.localizedDescription)"]
            }
        }
    }
}
