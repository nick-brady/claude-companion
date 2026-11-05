import Foundation

/// Recent Claude Code sessions, read from ~/.claude/projects/<project>/<session>.jsonl.
/// Read-only: we only peek at the first part of each transcript for a label.
struct SessionInfo: Identifiable {
    let id: String
    let cwd: String
    let snippet: String
    let modified: Date

    /// A transcript written to in the last ~2 minutes is probably open in a terminal.
    var isLikelyLive: Bool { Date().timeIntervalSince(modified) < 120 }

    var folderName: String { (cwd as NSString).lastPathComponent }

    var ageText: String {
        let s = Int(Date().timeIntervalSince(modified))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}

enum SessionCatalog {
    static func recent(limit: Int = 12) -> [SessionInfo] {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for dir in projects {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in items where f.pathExtension == "jsonl" {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((f, d))
            }
        }
        files.sort { $0.1 > $1.1 }
        var out: [SessionInfo] = []
        for (url, date) in files.prefix(limit * 3) {
            if let info = peek(url, modified: date) { out.append(info) }
            if out.count >= limit { break }
        }
        return out
    }

    private static func peek(_ url: URL, modified: Date) -> SessionInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        var cwd: String?
        var snippet: String?
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if cwd == nil, let c = obj["cwd"] as? String { cwd = c }
            if snippet == nil, obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any] {
                var text: String?
                if let s = msg["content"] as? String { text = s }
                else if let arr = msg["content"] as? [[String: Any]] {
                    text = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String
                }
                if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("<") {
                    snippet = String(t.replacingOccurrences(of: "\n", with: " ").prefix(60))
                }
            }
            if cwd != nil && snippet != nil { break }
        }
        guard let cwd, let snippet else { return nil }
        return SessionInfo(id: url.deletingPathExtension().lastPathComponent, cwd: cwd, snippet: snippet, modified: modified)
    }
}
