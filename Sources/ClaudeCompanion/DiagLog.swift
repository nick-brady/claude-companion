import Foundation

/// Append-only diagnostics log: ~/Library/Application Support/ClaudeCompanion/logs/companion.log
/// (rotated to companion.1.log at 5 MB). Records hotkey/recording state changes, recognizer
/// partials and finals, what was sent where, and delivery results. Stays on this Mac.
enum DiagLog {
    private static let queue = DispatchQueue(label: "diag.log")
    static let url: URL = {
        let d = LocalServer.supportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("companion.log")
    }()
    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ event: String, _ detail: String = "") {
        let line = "\(fmt.string(from: Date()))  \(event)\(detail.isEmpty ? "" : "  " + detail.replacingOccurrences(of: "\n", with: "⏎"))\n"
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > 5_000_000 {
                let old = url.deletingLastPathComponent().appendingPathComponent("companion.1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
