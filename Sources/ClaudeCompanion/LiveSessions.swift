import AppKit

/// A Claude Code session running in a terminal right now, identified by its TTY.
/// It may be reachable two ways:
///   - push: it was started with the companion channel (see integration/cc-voice), so we
///     can inject a message exactly like a typed prompt and it shows up in the terminal.
///   - typing: it lives in an iTerm2 tab, so we can type into that tab via AppleScript.
struct LiveSession: Identifiable, Equatable {
    var tty: String                // "ttys003"
    var cwd: String?
    var title: String?             // iTerm tab/session name
    var itermID: String?           // iTerm session unique id
    var channelPID: Int32?         // claude pid that registered the channel
    var lastSeen: Date = Date()
    var lastActive: Date = .distantPast

    var id: String { tty }
    var canPush: Bool { channelPID != nil && Date().timeIntervalSince(lastSeen) < 45 }
    var canType: Bool { itermID != nil }
    var folderName: String { cwd.map { ($0 as NSString).lastPathComponent } ?? (title ?? tty) }
    var method: String { canPush ? "push" : (canType ? "types into iTerm" : "offline") }
}

/// What the app sends to.
enum Target: Equatable {
    case live(LiveSession)
    case background
}

/// Registry + message queues for live sessions.
final class LiveSessionHub {
    private(set) var sessions: [String: LiveSession] = [:]   // by tty
    private var queues: [String: [[String: Any]]] = [:]
    private var waiters: [String: (LocalServer.Response) -> Void] = [:]
    var onChange: (() -> Void)?

    var all: [LiveSession] {
        sessions.values
            .filter { $0.canPush || $0.canType }
            .sorted { ($0.lastActive, $0.lastSeen) > ($1.lastActive, $1.lastSeen) }
    }

    // MARK: Channel side

    func register(tty: String, cwd: String?, pid: Int32) {
        var s = sessions[tty] ?? LiveSession(tty: tty)
        if s.channelPID != nil && s.channelPID != pid {
            // A new claude process took over this terminal; an old parked poll belongs to a dead process.
            waiters.removeValue(forKey: tty)?(.init(status: 204))
        }
        s.cwd = cwd ?? s.cwd
        s.channelPID = pid
        s.lastSeen = Date()
        sessions[tty] = s
        onChange?()
    }

    func unregister(tty: String, pid: Int32) {
        guard sessions[tty]?.channelPID == pid else { return }
        sessions[tty]?.channelPID = nil
        waiters.removeValue(forKey: tty)?(.init(status: 204))
        queues[tty] = nil
        onChange?()
    }

    /// Long-poll: answer now if something is queued, else park for up to 25 s.
    func poll(tty: String, reply: @escaping (LocalServer.Response) -> Void) {
        sessions[tty]?.lastSeen = Date()
        if let q = queues[tty], !q.isEmpty {
            queues[tty] = []
            reply(.init(json: ["messages": q]))
            return
        }
        waiters[tty]?(.init(status: 204))
        waiters[tty] = reply
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            guard let self, let w = self.waiters[tty] else { return }
            self.waiters[tty] = nil
            w(.init(status: 204))
        }
    }

    private(set) var acked = Set<String>()

    func ack(_ id: String) { acked.insert(id) }

    /// Remove a not-yet-delivered message (e.g. we fell back to typing it).
    func cancel(tty: String, id: String) {
        queues[tty]?.removeAll { ($0["id"] as? String) == id }
    }

    func push(to tty: String, text: String, attachmentIDs: [String], id: String) {
        let msg: [String: Any] = ["id": id, "text": text, "attachments": attachmentIDs]
        sessions[tty]?.lastActive = Date()
        if let w = waiters.removeValue(forKey: tty) {
            w(.init(json: ["messages": [msg]]))
        } else {
            queues[tty, default: []].append(msg)
        }
    }

    /// Bump a session's activity. Called on every hook, so only republish when the order
    /// changed (that's when follow-active may now point somewhere else).
    func markActive(_ tty: String) {
        guard sessions[tty] != nil else { return }
        let wasFirst = all.first?.tty == tty
        sessions[tty]?.lastActive = Date()
        if !wasFirst { onChange?() }
    }

    func session(tty: String) -> LiveSession? { sessions[tty] }

    // MARK: iTerm side

    /// Refresh the list of iTerm2 sessions running `claude`. Runs AppleScript off the main thread.
    func refreshITerm(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let rows = ITerm.sessions()
            let ttysWithClaude = Set(rows.map(\.tty).filter { ITerm.ttyRunsClaude($0) })
            DispatchQueue.main.async {
                for k in self.sessions.keys { self.sessions[k]?.itermID = nil }
                for r in rows where ttysWithClaude.contains(r.tty) {
                    var s = self.sessions[r.tty] ?? LiveSession(tty: r.tty)
                    s.itermID = r.id
                    s.title = r.name
                    if s.cwd == nil { s.cwd = ITerm.cwd(ofClaudeOn: r.tty) }
                    self.sessions[r.tty] = s
                }
                self.onChange?()
                completion?()
            }
        }
    }
}

enum ITerm {
    struct Row { let id: String; let tty: String; let name: String }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.googlecode.iterm2" }
    }

    static func sessions() -> [Row] {
        guard isRunning else { return [] }
        let script = """
        set out to ""
        set TB to character id 9 -- inside iTerm's tell block `tab` means iTerm's tab class, not a tab character
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                set out to out & (unique id of s) & TB & (tty of s) & TB & (name of s) & linefeed
              end repeat
            end repeat
          end repeat
        end tell
        return out
        """
        guard let out = runAppleScript(script) else { return [] }
        return out.split(separator: "\n").compactMap { line in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 3 else { return nil }
            return Row(id: p[0], tty: p[1].replacingOccurrences(of: "/dev/", with: ""), name: p[2])
        }
    }

    /// Types `text` into the iTerm session and presses Return (same as typing it).
    ///
    /// Long text is written in chunks with short pauses: a single multi-KB `write text`
    /// overflows the terminal input path and Claude Code receives only the tail.
    /// Return is sent separately (a newline inside the write arrives as pasted text).
    @discardableResult
    static func type(_ text: String, intoSession id: String, chunkSize: Int = 400, pause: Double = 0.06) -> String? {
        let oneLine = ITerm.singleLine(text)
        var chunks: [String] = []
        var rest = Substring(oneLine)
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: chunkSize, limitedBy: rest.endIndex) ?? rest.endIndex
            // Prefer to cut after a space so words aren't split across writes.
            if end < rest.endIndex, let sp = rest[rest.startIndex..<end].lastIndex(of: " "), rest.distance(from: rest.startIndex, to: sp) > chunkSize / 2 {
                end = rest.index(after: sp)
            }
            chunks.append(String(rest[rest.startIndex..<end]))
            rest = rest[end...]
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let writes = chunks.map { "tell s to write text \"\(esc($0))\" newline NO\n                  delay \(pause)" }
            .joined(separator: "\n                  ")
        let script = """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (unique id of s) is "\(id)" then
                  \(writes)
                  delay \(String(format: "%.2f", 0.3 + Double(oneLine.count) / 20000))
                  tell s to write text (character id 13) newline NO
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "missing"
        """
        return runAppleScript(script)
    }

    /// Collapse all line breaks / runs of whitespace (\n, \r, U+2028, tabs) to single spaces.
    static func singleLine(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func ttyRunsClaude(_ tty: String) -> Bool {
        guard let out = shell("/bin/ps", ["-t", tty, "-o", "comm="]) else { return false }
        return out.split(separator: "\n").contains { $0.hasSuffix("claude") || $0.contains("/claude") }
    }

    static func cwd(ofClaudeOn tty: String) -> String? {
        guard let out = shell("/bin/ps", ["-t", tty, "-o", "pid=,comm="]) else { return nil }
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[1].hasSuffix("claude") else { continue }
            if let l = shell("/usr/sbin/lsof", ["-a", "-p", String(parts[0]), "-d", "cwd", "-Fn"]),
               let n = l.split(separator: "\n").first(where: { $0.hasPrefix("n") }) {
                return String(n.dropFirst())
            }
        }
        return nil
    }

    /// Runs via /usr/bin/osascript so it is safe off the main thread. macOS asks once for
    /// Automation permission (Claude Companion → iTerm).
    static func runAppleScript(_ source: String) -> String? {
        let out = shell("/usr/bin/osascript", ["-e", source])
        return out?.trimmingCharacters(in: .newlines)
    }

    static func shell(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
