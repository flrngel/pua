import Foundation

/// Files written for a recorded call:
/// - conversation.wav: stereo 48 kHz PCM16, left = caller, right = agent
/// - transcript.jsonl: one turn per line (`t` seconds from the start, `speaker`, `text`, `latency_s`)
/// - transcript.md: the same, readable
/// - call.json: the call summary (everything but the transcript)
enum CallRecording {
    static func write(to dir: URL, caller left: [Int16], agent right: [Int16], transcript entries: [[String: Any]],
                      agentName: String, summary: [String: Any]) throws -> [String: String] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let frames = max(left.count, right.count)
        var data = Data(capacity: 44 + frames * 4)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(2); u32(48_000); u32(48_000 * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 4))
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            interleaved[2 * i] = i < left.count ? left[i] : 0
            interleaved[2 * i + 1] = i < right.count ? right[i] : 0
        }
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        let wav = dir.appendingPathComponent("conversation.wav")
        try data.write(to: wav)

        let jsonl = dir.appendingPathComponent("transcript.jsonl")
        let lines = try entries.map { String(data: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)! }
        try (lines.joined(separator: "\n") + "\n").write(to: jsonl, atomically: true, encoding: .utf8)

        let md = dir.appendingPathComponent("transcript.md")
        let body = entries.map { e -> String in
            let t = e["t"] as? Double ?? 0
            let who = (e["speaker"] as? String) == "agent" ? "\(agentName) (AI)" : "Caller"
            let lat = (e["latency_s"] as? Double).map { String(format: "  _(reply in %.1f s)_", $0) } ?? ""
            return String(format: "**[%d:%02d] %@:** %@%@", Int(t) / 60, Int(t) % 60, who, e["text"] as? String ?? "", lat)
        }.joined(separator: "\n\n")
        try (body + "\n").write(to: md, atomically: true, encoding: .utf8)

        let files = ["wav": wav.path, "transcript_md": md.path, "transcript_jsonl": jsonl.path,
                     "call_json": dir.appendingPathComponent("call.json").path]
        var meta = summary
        meta["transcript"] = nil
        meta["files"] = files
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("call.json"))
        return files
    }

    /// `<base>/<yyyyMMdd-HHmmss>-<direction>`, one folder per call.
    static func folder(in base: URL, direction: ConversationSettings.Direction, at date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return base.appendingPathComponent("\(f.string(from: date))-\(direction == .incoming ? "in" : "out")")
    }
}
