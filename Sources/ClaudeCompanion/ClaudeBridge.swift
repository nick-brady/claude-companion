import Foundation

/// Talks to Claude Code through its headless stream-json mode:
///
///   claude -p --input-format stream-json --output-format stream-json \
///          --include-partial-messages --verbose [--resume <id> [--fork-session]]
///
/// One long-lived process per conversation. Each user turn is one JSON line on
/// stdin (text + optional base64 images); replies stream back as JSON lines on
/// stdout. Keeping the process alive keeps the prompt cache warm, so turns after
/// the first are fast and cheap.
final class ClaudeBridge {
    enum Event {
        case started(sessionID: String)
        case text(String)
        case tool(String)
        case done(isError: Bool, message: String?)
        case exited(String)
    }

    struct Launch: Equatable {
        var cwd: URL
        var resume: String? = nil
        var fork: Bool = false
        var model: String? = nil
        /// nil = Claude Code's default mode. Anything that would need an
        /// approval prompt is auto-denied (--permission-prompts none).
        var permissionMode: String? = nil
        var extraArgs: [String] = []
    }

    struct Image {
        let mediaType: String
        let data: Data
    }

    /// Always delivered on the main queue.
    var onEvent: ((Event) -> Void)?

    private(set) var launch: Launch
    private(set) var sessionID: String?
    private var forkPending = false
    private var proc: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrTail = ""
    private let queue = DispatchQueue(label: "claude.bridge")
    private var textBlocksThisTurn = 0
    private var expectingExit = false

    static let voicePrompt = """
    The user is talking to you by voice through a small companion app. Your reply is read aloud \
    by text-to-speech and also shown briefly in a small window. Speak naturally and concisely: \
    lead with the answer in a few short sentences, no preamble. Avoid markdown tables, long lists \
    and code in the spoken part. If code, file paths, commands or other detail are useful, put \
    them after a line containing only '---'; the app shows that part on screen but does not read \
    it aloud. Speech-to-text can mishear words; infer the intended meaning. When an image is \
    attached it is a screenshot of the user's screen: a red ring marks where their cursor was, \
    or a red box marks a region they circled with the mouse to point at it.
    """

    init(launch: Launch) {
        self.launch = launch
        self.sessionID = launch.resume
        self.forkPending = launch.fork && launch.resume != nil
    }

    var isRunning: Bool { proc?.isRunning == true }

    func configure(_ newLaunch: Launch) {
        stop()
        launch = newLaunch
        sessionID = newLaunch.resume
        forkPending = newLaunch.fork && newLaunch.resume != nil
    }

    func start() throws {
        if isRunning { return }
        let exe = try ClaudeBridge.locateClaude()
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--include-partial-messages",
                    "--verbose",
                    "--append-system-prompt", Self.voicePrompt,
                    "--permission-prompts", "none"]
        if let id = sessionID {
            args += ["--resume", id]
            if forkPending { args.append("--fork-session") }
        }
        if let model = launch.model { args += ["--model", model] }
        if let mode = launch.permissionMode { args += ["--permission-mode", mode] }
        args += launch.extraArgs

        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.currentDirectoryURL = launch.cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeBridge.loginPath
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async { self?.consume(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self else { return }
                self.stderrTail += String(decoding: d, as: UTF8.self)
                if self.stderrTail.count > 4000 { self.stderrTail = String(self.stderrTail.suffix(4000)) }
            }
        }
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.queue.async {
                let expected = self.expectingExit
                self.expectingExit = false
                let msg = "Claude Code exited (status \(proc.terminationStatus)). " + self.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
                if !expected { self.emit(.exited(msg)) }
            }
        }
        stdoutBuffer = Data()
        stderrTail = ""
        try p.run()
        proc = p
        stdinHandle = inPipe.fileHandleForWriting
    }

    func send(text: String, images: [Image]) throws {
        try start()
        var content: [[String: Any]] = images.map {
            ["type": "image",
             "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        try writeLine(msg)
        textBlocksThisTurn = 0
    }

    /// Ask Claude Code to stop the current turn (same control message the Agent SDK uses).
    func interrupt() {
        guard isRunning else { return }
        try? writeLine(["type": "control_request",
                        "request_id": UUID().uuidString,
                        "request": ["subtype": "interrupt"]])
    }

    func stop() {
        guard let p = proc else { return }
        expectingExit = true
        try? stdinHandle?.close()
        if p.isRunning { p.terminate() }
        proc = nil
        stdinHandle = nil
    }

    // MARK: - Private

    private func writeLine(_ obj: [String: Any]) throws {
        guard let h = stdinHandle else { throw BridgeError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: obj)
        data.append(0x0A)
        try h.write(contentsOf: data)
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func consume(_ d: Data) {
        stdoutBuffer.append(d)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ obj: [String: Any]) {
        let type = obj["type"] as? String
        switch type {
        case "system":
            if obj["subtype"] as? String == "init", let id = obj["session_id"] as? String {
                sessionID = id
                forkPending = false
                emit(.started(sessionID: id))
            }
        case "stream_event":
            // Only the top-level conversation; ignore subagent chatter.
            if let parent = obj["parent_tool_use_id"], !(parent is NSNull) { return }
            guard let ev = obj["event"] as? [String: Any], let evType = ev["type"] as? String else { return }
            if evType == "content_block_start", let block = ev["content_block"] as? [String: Any] {
                let bt = block["type"] as? String
                if bt == "text" {
                    if textBlocksThisTurn > 0 { emit(.text("\n\n")) }
                    textBlocksThisTurn += 1
                } else if bt == "tool_use" || bt == "server_tool_use" {
                    emit(.tool(block["name"] as? String ?? "a tool"))
                }
            } else if evType == "content_block_delta",
                      let delta = ev["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let t = delta["text"] as? String {
                emit(.text(t))
            }
        case "result":
            let isError = (obj["is_error"] as? Bool) ?? false
            let msg = obj["result"] as? String ?? (obj["subtype"] as? String)
            emit(.done(isError: isError, message: msg))
        default:
            break
        }
    }

    enum BridgeError: LocalizedError {
        case notRunning, claudeNotFound
        var errorDescription: String? {
            switch self {
            case .notRunning: return "Claude Code process is not running."
            case .claudeNotFound: return "Couldn't find the `claude` CLI (looked in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin and your login shell PATH)."
            }
        }
    }

    // MARK: - Locating the CLI

    static let loginPath: String = {
        var parts: [String] = []
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            parts = s.split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        for extra in ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        where !parts.contains(extra) { parts.append(extra) }
        return parts.joined(separator: ":")
    }()

    static func locateClaude() throws -> URL {
        let home = NSHomeDirectory()
        var candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        candidates += loginPath.split(separator: ":").map { "\($0)/claude" }
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw BridgeError.claudeNotFound
    }
}
