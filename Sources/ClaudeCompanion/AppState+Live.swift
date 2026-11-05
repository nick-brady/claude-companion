import AppKit

/// Delivery into Claude Code sessions that are already open in a terminal.
extension AppState {

    // MARK: Target & pinning

    /// Pinned target if it's reachable (and not following); otherwise the most recently
    /// active push-capable live session; otherwise the app's own background session.
    /// "Most recently active" = the last session that sent us a hook (PreToolUse / Stop /
    /// speak tool) or that we sent a message to, so a session Nick is typing into in the
    /// terminal counts. (Typing into an iTerm tab only happens when that session is pinned.)
    var target: Target {
        let live = liveSessions
        if !followActive, pinnedKey == "background" { return .background }
        if !followActive, let key = pinnedKey, key.hasPrefix("live:") {
            let parts = key.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
            let tty = parts.first ?? ""
            let cwd = parts.count > 1 ? parts[1] : nil
            if let s = live.first(where: { $0.tty == tty && ($0.canPush || $0.canType) }) { return .live(s) }
            if let cwd, let s = live.first(where: { $0.cwd == cwd && $0.canPush }) { return .live(s) }
        }
        if let s = live.first(where: { $0.canPush }) { return .live(s) }
        return .background
    }

    var targetLabel: String {
        switch target {
        case .background: return "Background · \(launch.cwd.lastPathComponent)"
        case .live(let s): return "\(s.folderName) · \(s.canPush ? "live" : "iTerm")"
        }
    }

    /// The targeted session is live right now (its channel has checked in recently).
    var targetIsLive: Bool {
        if case .live(let s) = target { return s.canPush }
        return false
    }

    /// Replies will come back from the target: a live push session, or the background session.
    var targetConnected: Bool {
        if case .live(let s) = target { return s.canPush }
        return true
    }

    var isPinned: Bool { !followActive && pinnedKey != nil }

    /// Pin key for a live session (the same string `pinnedKey` stores).
    static func key(for s: LiveSession) -> String { "live:\(s.tty)|\(s.cwd ?? "")" }

    /// Key of what we're talking to right now (the picker's checkmark).
    var targetKey: String {
        switch target {
        case .background: return "background"
        case .live(let s): return Self.key(for: s)
        }
    }

    /// Pinning is a manual choice, so it switches follow-active off.
    func pin(_ s: LiveSession) { pinnedKey = Self.key(for: s); followActive = false }
    func pinBackground() { pinnedKey = "background"; followActive = false }
    func unpin() { pinnedKey = nil }
    func isPinned(_ s: LiveSession) -> Bool { !followActive && pinnedKey?.hasPrefix("live:\(s.tty)|") == true }

    /// Picker choice by key (see `targetKey`).
    func pick(key: String) {
        if key == "background" { pinBackground() }
        else if let s = liveSessions.first(where: { Self.key(for: $0) == key }) { pin(s) }
    }

    /// Pin whatever we'd talk to right now (used when follow-active is switched off).
    func pinCurrentTarget() {
        switch target {
        case .live(let s): pinnedKey = Self.key(for: s)
        case .background: pinnedKey = "background"
        }
    }

    func refreshLiveSessions() {
        hub.refreshITerm()
    }

    // MARK: Server

    func startLiveServices() {
        hub.onChange = { [weak self] in self?.liveSessions = self?.hub.all ?? [] }
        server.handler = { [weak self] req, reply in self?.route(req, reply) ?? reply(.init(status: 503)) }
        server.onFailure = { [weak self] m in self?.serverError = m; NSLog("%@", m) }
        do { try server.start() } catch { serverError = "Couldn't open local port \(LocalServer.port): \(error.localizedDescription)" }
        // iTerm is only queried when you open Sessions (it triggers macOS's Automation prompt once).
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.liveSessions = self.hub.all
            }
        }
    }

    private func route(_ req: LocalServer.Request, _ reply: @escaping (LocalServer.Response) -> Void) {
        let tty = req.headers["x-claude-tty"] ?? req.query["tty"] ?? ""
        if ProcessInfo.processInfo.environment["COMPANION_DEBUG"] != nil {
            NSLog("route %@ %@ tty=%@ body=%d json=%@ pending=%@", req.method, req.path, tty, req.body.count,
                  req.json == nil ? "nil" : "ok", voicePending.keys.joined(separator: ","))
        }
        switch (req.method, req.path) {
        case ("POST", "/channel/register"):
            let j = req.json ?? [:]
            hub.register(tty: tty, cwd: j["cwd"] as? String, pid: Int32((j["pid"] as? Int) ?? 0))
            reply(.init())
        case ("GET", "/channel/poll"):
            hub.poll(tty: tty, reply: reply)
        case ("GET", "/attachment"):
            if let id = req.query["id"], let d = storedImages[id] {
                reply(.init(json: ["media_type": "image/jpeg", "data": d.base64EncodedString()]))
            } else { reply(.init(status: 404, json: ["error": "no such screenshot"])) }
        case ("GET", "/look"):
            Task { @MainActor in
                let cursor = NSEvent.mouseLocation
                do {
                    let shot = try await ScreenCapture.captureScreen(containing: cursor)
                    let img = ScreenCapture.screenWithCursor(shot, cursor: cursor)
                    if let a = ScreenCapture.makeAttachment(img, label: "screen") {
                        reply(.init(json: ["media_type": "image/jpeg", "data": a.jpeg.base64EncodedString()]))
                    } else { reply(.init(status: 500, json: ["error": "encode failed"])) }
                } catch {
                    if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
                    reply(.init(status: 500, json: ["error": "Screen capture failed (Screen Recording permission?): \(error.localizedDescription)"]))
                }
            }
        case ("POST", "/send"):
            // Send text to the current target as if spoken (used by scripts/tests).
            if let t = req.json?["text"] as? String, !t.isEmpty {
                heard = t
                Task { await self.send(t) }
                reply(.init(json: ["ok": true, "target": targetLabel]))
            } else { reply(.init(status: 400, json: ["error": "text required"])) }
        case ("GET", "/status"):
            reply(.init(json: ["target": targetLabel, "phase": "\(phase)", "activity": activity ?? "", "reply": self.reply,
                               "live": liveSessions.map { ["tty": $0.tty, "cwd": $0.cwd ?? "", "method": $0.method] }]))
        case ("POST", "/channel/bye"):
            hub.unregister(tty: tty, pid: Int32((req.json?["pid"] as? Int) ?? 0))
            reply(.init())
        case ("POST", "/channel/ack"):
            if let id = req.json?["id"] as? String {
                hub.ack(id)
                DiagLog.log("channel.ack", id)
                if pendingDelivery?.id == id {
                    pendingDelivery?.acked = Date()
                    activity = "Delivered to \(pendingDelivery?.folder ?? "session") · waiting for Claude…"
                }
            }
            reply(.init())
        case ("POST", "/speak"):
            lastHookAt[tty] = Date()
            hub.markActive(tty)
            DiagLog.log("speak.tool", "tty=\(tty)")
            if let t = (req.json?["text"] as? String), !t.isEmpty, speakReplies, !muted { say(t) }   // held while recording
            reply(.init())
        case ("POST", "/hook/activity"):
            lastHookAt[tty] = Date()
            hub.markActive(tty)
            if voicePending[tty] != nil, let tool = req.json?["tool_name"] as? String {
                activity = "Using \(Self.friendlyTool(tool))…"
            }
            reply(.init())
        case ("POST", "/hook/stop"):
            lastHookAt[tty] = Date()
            hub.markActive(tty)
            DiagLog.log("hook.stop", "tty=\(tty) pending=\(voicePending[tty] != nil) recording=\(recordingActive)")
            if let t = req.json?["last_assistant_message"] as? String {
                speakFromSession(t, tty: tty, force: speakAllReplies)
            }
            reply(.init())
        default:
            reply(.init(status: 404, json: ["error": "unknown route"]))
        }
    }

    var speakAllReplies: Bool { UserDefaults.standard.bool(forKey: "speakAllReplies") }

    /// A finished reply from a terminal session: show it and read it aloud if it answers
    /// something we sent by voice (or "speak every reply" is on).
    private func speakFromSession(_ text: String, tty: String, force: Bool) {
        let pending = voicePending[tty].map { Date().timeIntervalSince($0) < 1800 } ?? false
        guard pending || force else { return }
        voicePending[tty] = nil
        hub.markActive(tty)
        if recordingActive {
            // Never touch an in-progress recording: hold the reply until he's done talking.
            heldReply = text
            pendingDelivery = nil
            DiagLog.log("reply.held", "\(text.count) chars, recording in progress")
            return
        }
        presentReply(text)
    }

    /// Show a terminal session's reply in the caption/transcript and read it aloud.
    func presentReply(_ text: String, alreadySpoken: Bool = false) {
        activity = nil
        turnDoneFromLive()
        reply = text
        showCaption()
        pendingDelivery = nil
        if !muted && speakReplies && !alreadySpoken {
            var s = SpeakableStream()
            (s.feed(text) + s.finish()).forEach { say($0) }
        }
        if !isSpeakingNow { setPhase(.idle); scheduleCaptionHide() } else { setPhase(.responding) }
    }

    // MARK: Sending

    func sendLive(_ text: String, to s: LiveSession) {
        var ids: [String] = []
        var paths: [String] = []
        for a in attachments {
            let id = String(UUID().uuidString.prefix(8)).lowercased()
            storedImages[id] = a.jpeg
            ids.append(id)
            let url = LocalServer.supportDir.appendingPathComponent("shots/\(id).jpg")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? a.jpeg.write(to: url)
            paths.append(url.path)
        }
        if storedImages.count > 40 { storedImages = storedImages.filter { ids.contains($0.key) } }
        turns.append(Turn(role: .you, text: text, imageCount: attachments.count))
        let labels = attachments.map(\.label)
        attachments.removeAll()
        reply = ""
        voicePending[s.tty] = Date()
        hub.markActive(s.tty)
        phase = .thinking
        showCaption()

        var typed = ITerm.singleLine(text)
        if !paths.isEmpty {
            typed += " [screenshots: " + zip(labels, paths).map { "\($0) at \($1)" }.joined(separator: "; ") + "]"
        }
        let msgID = UUID().uuidString
        pendingDelivery = PendingDelivery(id: msgID, tty: s.tty, folder: s.folderName, typedText: typed, sent: Date())

        DiagLog.log("send", "to=\(s.folderName) tty=\(s.tty) mode=\(deliveryMode.rawValue) canPush=\(s.canPush) \(typed.count) chars: \"\(typed)\"")
        if deliveryMode == .push && s.canPush {
            activity = "Sending to \(s.folderName)…"
            hub.push(to: s.tty, text: text, attachmentIDs: ids, id: msgID)
            watchDelivery(msgID)
        } else {
            typeIntoITerm(tty: s.tty, folder: s.folderName, text: typed)
        }
    }

    /// Re-send the last undelivered message by typing it into the session's iTerm tab.
    func retryViaITerm() {
        guard let p = pendingDelivery else { return }
        DiagLog.log("send.retry-iterm", p.folder)
        hub.cancel(tty: p.tty, id: p.id)
        typeIntoITerm(tty: p.tty, folder: p.folder, text: p.typedText)
    }

    var canRetryViaITerm: Bool { pendingDelivery != nil && isErrorPhase }

    private func typeIntoITerm(tty: String, folder: String, text: String) {
        activity = "Typing into \(folder) in iTerm…"
        phase = .thinking
        let go: () -> Void = { [weak self] in
            guard let self else { return }
            guard let iid = self.hub.session(tty: tty)?.itermID else {
                self.setPhase(.error("\(folder) isn't in an iTerm tab I can find (or Automation → iTerm is off), so I can't type into it."))
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ITerm.type(text, intoSession: iid)
                DiagLog.log("iterm.type", "session=\(iid) result=\(r ?? "nil") \(text.count) chars")
                DispatchQueue.main.async {
                    if r == "ok" {
                        self.activity = "Typed into \(folder) · waiting for Claude…"
                        if let id = self.pendingDelivery?.id { self.watchResponse(id, after: Date()) }
                    } else {
                        self.setPhase(.error("Couldn't type into iTerm (Automation permission for iTerm, or the tab closed)."))
                    }
                }
            }
        }
        if hub.session(tty: tty)?.itermID != nil { go() } else { hub.refreshITerm { go() } }
    }

    /// Push delivery: the channel server must ack within a few seconds (else requeue once, then
    /// fall back / fail). After the ack, Claude should start (a hook fires) within ~30 s.
    private func watchDelivery(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.pendingDelivery, p.id == id, p.acked == nil else { return }
                // Possibly handed to a poll from a process that just died: try once more.
                self.hub.cancel(tty: p.tty, id: id)
                self.hub.push(to: p.tty, text: p.typedText, attachmentIDs: [], id: id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let p = self.pendingDelivery, p.id == id, p.acked == nil else { return }
                        self.hub.cancel(tty: p.tty, id: id)
                        DiagLog.log("channel.no-ack", "falling back for \(p.folder)")
                        if self.hub.session(tty: p.tty)?.itermID != nil || ITerm.isRunning {
                            self.activity = "Channel didn't answer, typing into iTerm instead…"
                            self.typeIntoITerm(tty: p.tty, folder: p.folder, text: p.typedText)
                        } else {
                            self.setPhase(.error("Couldn't deliver to \(p.folder): its companion channel isn't responding. Is that session still running?"))
                        }
                    }
                }
            }
        }
        watchResponse(id, after: Date())
    }

    private func watchResponse(_ id: String, after start: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.pendingDelivery, p.id == id, self.phase == .thinking else { return }
                if let h = self.lastHookAt[p.tty], h > start { return }       // Claude is working
                let viaChannel = p.acked != nil
                self.phase = .error(viaChannel
                    ? "\(p.folder) hasn't picked up your message yet. If it's mid-task it will after the current turn. If nothing ever arrives, channels are blocked for your org: Team plans need an Owner to enable claude.ai → Organization settings → Claude Code → Channels. Or set Delivery to “Type into iTerm”."
                    : "\(p.folder) hasn't responded yet. It may be busy, or waiting on a permission prompt in the terminal.")
            }
        }
    }
}

struct PendingDelivery {
    let id: String
    let tty: String
    let folder: String
    let typedText: String
    let sent: Date
    var acked: Date?
}

enum DeliveryMode: String, CaseIterable, Identifiable {
    case push, iterm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .push: return "Push into the session (channels), fall back to typing"
        case .iterm: return "Type into its iTerm tab"
        }
    }
}
