import AppKit
import Combine
import Carbon

struct Turn: Identifiable, Equatable {
    enum Role { case you, claude }
    let id = UUID()
    let role: Role
    var text: String
    var imageCount = 0
    let date = Date()
}

enum ScreenshotMode: String, CaseIterable, Identifiable {
    case off, always  // "Only what I circle" removed; a stored "circled" falls back to .always on load
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Never attach the screen"
        case .always: return "Screen + cursor every turn"
        }
    }
    var symbol: String {
        switch self {
        case .off: return "eye.slash"
        case .always: return "eye"
        }
    }
}

/// Orchestrates: hotkey -> listen -> transcribe -> (screenshot) -> Claude -> stream -> speak.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle, listening, thinking, responding, error(String)
    }

    @Published var phase: Phase = .idle
    @Published var heard = ""
    @Published var reply = "" {
        didSet {
            guard !reply.isEmpty else { return }
            if let last = turns.last, last.role == .claude, last.id == replyTurnID {
                turns[turns.count - 1].text = reply
            } else {
                let t = Turn(role: .claude, text: reply)
                replyTurnID = t.id
                turns.append(t)
            }
        }
    }
    @Published var turns: [Turn] = []
    private var replyTurnID: UUID?
    @Published var showPill = UserDefaults.standard.object(forKey: "showPill") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPill, forKey: "showPill") }
    }
    @Published var activity: String?
    @Published var level: Float = 0
    @Published var attachments: [Attachment] = []
    @Published var typed = "" {
        didSet {
            // Editing a transcript under review pauses its auto-send; clearing it cancels.
            guard let r = reviewText, typed != r else { return }
            if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cancelReview() }
            else if reviewEndsAt != nil { reviewEndsAt = nil; DiagLog.log("review.paused", "edited") }
        }
    }
    /// Transcript waiting to be sent (review window). nil = nothing pending.
    @Published var reviewText: String?
    /// When the pending transcript auto-sends. nil while paused (you edited it).
    @Published var reviewEndsAt: Date?
    /// "Review before sending": hold each voice transcript a few seconds so it can be fixed or cancelled.
    @Published var reviewBeforeSend: Bool = UserDefaults.standard.object(forKey: "reviewBeforeSend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reviewBeforeSend, forKey: "reviewBeforeSend") }
    }
    @Published var reviewDelay: Double = UserDefaults.standard.object(forKey: "reviewDelay") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(reviewDelay, forKey: "reviewDelay") }
    }
    @Published var sessionLabel = ""
    @Published var screenshotMode: ScreenshotMode {
        didSet { UserDefaults.standard.set(screenshotMode.rawValue, forKey: "screenshotMode") }
    }
    @Published var voiceID: String? {
        didSet { speaker.voiceID = voiceID; UserDefaults.standard.set(voiceID, forKey: "voiceID") }
    }
    @Published var muted = false {
        didSet { if muted { speaker.stop() } }
    }
    /// Caption card above the pill (what you said / Claude's reply).
    @Published var captionVisible = false
    /// Full window (the pill morphs into it). Set by the window controller.
    @Published var expanded = false {
        didSet { if expanded { hideWork?.cancel() } else { scheduleCaptionHide() } }
    }
    /// Background-only frame while the window morphs between pill and full size.
    @Published var morphing = false
    /// Caption card goes below the pill when the pill sits in the top half of the screen.
    @Published var cardBelow = false
    /// Window controller hooks.
    // Live terminal sessions (push via channel / typing into iTerm).
    let hub = LiveSessionHub()
    let server = LocalServer()
    var storedImages: [String: Data] = [:]
    var voicePending: [String: Date] = [:]      // tty -> when we sent a voice turn
    var lastHookAt: [String: Date] = [:]        // tty -> last hook/tool call seen from that session
    var pendingDelivery: PendingDelivery?
    @Published var deliveryMode: DeliveryMode = DeliveryMode(rawValue: UserDefaults.standard.string(forKey: "deliveryMode") ?? "") ?? .push {
        didSet { UserDefaults.standard.set(deliveryMode.rawValue, forKey: "deliveryMode") }
    }
    /// "Respond with voice": read Claude's replies aloud in the app (else text only).
    @Published var speakReplies: Bool = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(speakReplies, forKey: "speakReplies")
            if !speakReplies { speaker.stop() }
        }
    }
    @Published var ttsProvider: TTSProvider = TTSProvider(rawValue: UserDefaults.standard.string(forKey: "ttsProvider") ?? "") ?? .macos {
        didSet { UserDefaults.standard.set(ttsProvider.rawValue, forKey: "ttsProvider"); speaker.provider = ttsProvider }
    }
    @Published var openAIVoice: String = UserDefaults.standard.string(forKey: "openAIVoice") ?? "coral" {
        didSet { UserDefaults.standard.set(openAIVoice, forKey: "openAIVoice"); speaker.openAIVoice = openAIVoice }
    }
    @Published var elevenVoiceID: String = UserDefaults.standard.string(forKey: "elevenVoiceID") ?? CloudTTS.elevenPresets[0].id {
        didSet { UserDefaults.standard.set(elevenVoiceID, forKey: "elevenVoiceID"); speaker.elevenVoiceID = elevenVoiceID }
    }
    @Published var ttsError: String?

    func testVoice() {
        speaker.stop()
        ttsError = nil
        speaker.say("Hi Nick. This is how I'll sound when I answer you.")
    }
    @Published var liveSessions: [LiveSession] = []
    @Published var pinnedKey: String? = UserDefaults.standard.string(forKey: "pinnedTarget") {
        didSet { UserDefaults.standard.set(pinnedKey, forKey: "pinnedTarget") }
    }
    /// Follow active: talk to whichever live session was most recently active (see `target`).
    /// Turning it on drops the pin; turning it off pins the current target so it stays put.
    @Published var followActive: Bool = UserDefaults.standard.object(forKey: "followActive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(followActive, forKey: "followActive")
            if followActive { pinnedKey = nil } else if pinnedKey == nil { pinCurrentTarget() }
        }
    }
    @Published var serverError: String?

    var interactiveFrames: [CGRect] = []
    var pillRect = CGRect(x: 0, y: 0, width: 56, height: 44)
    var onSummon: (() -> Void)?
    var onToggleExpand: (() -> Void)?
    var onIdle: (() -> Void)?
    var onDrag: ((DragPhase) -> Void)?
    var onWindowDrag: ((DragPhase) -> Void)?
    enum DragPhase { case began, changed, ended }

    func toggleExpand() { onToggleExpand?() }
    @Published var hovering = false {
        didSet { if hovering { hideWork?.cancel() } else { scheduleCaptionHide() } }
    }
    private var hideWork: DispatchWorkItem?

    /// Set by --demo to show each look without a mic or Claude.
    @Published var demoMood: OrbMood?

    var mood: OrbMood {
        if let demoMood { return demoMood }
        switch phase {
        case .idle: return speaker.isSpeaking ? .speaking : .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .responding: return speaker.isSpeaking ? .speaking : .thinking
        case .error: return .error
        }
    }

    var statusText: String? {
        switch phase {
        case .idle: return nil
        case .listening: return nil
        case .thinking: return activity ?? "Thinking"
        case .responding: return activity
        case .error(let m): return m
        }
    }

    let hotkeyLabel = "⌥Space"
    private let listener = SpeechInput()
    private let speaker = SpeechOutput()
    private let bridge: ClaudeBridge
    private let watcher = CursorWatcher()
    private var speakable = SpeakableStream()
    private var hotkey: HotKey?
    private var downAt: Date?
    private var toggleRecording = false
    private var starting = false
    private var finishing = false
    private var upWhileStarting: Date?
    /// A reply that arrived while he was recording; shown and spoken once he's done.
    var heldReply: String? { didSet { replyWaiting = heldReply != nil } }
    private var heldReplySpoken = false
    private var deferredPhase: Phase?
    @Published var replyWaiting = false

    /// Recording in any stage. Nothing outside the recording flow may change `phase` then.
    var recordingActive: Bool { phase == .listening || starting || finishing || listener.isRecording }

    /// Phase changes from replies, delivery results and errors go through here so they can't
    /// knock an in-progress recording out of `.listening` (which used to make the next
    /// hands-free tap start a new recording and throw the old one away).
    func setPhase(_ p: Phase) {
        if recordingActive {
            deferredPhase = p
            DiagLog.log("phase.deferred", "\(p) (recording in progress)")
        } else {
            phase = p
        }
    }

    /// After recording: apply what was held back. `sending` = a new message is going out.
    private func releaseHeld(sending: Bool) {
        if let d = deferredPhase, !sending { phase = d }
        deferredPhase = nil
        if let r = heldReply {
            heldReply = nil
            DiagLog.log("reply.release", "\(r.count) chars")
            presentReply(r, alreadySpoken: heldReplySpoken)
        }
        heldReplySpoken = false
        speaker.holding = false
        listener.feedPaused = false
    }

    /// Tap "reply waiting" while recording: hear it now. The mic stops feeding the recognizer
    /// while it plays so Claude's voice isn't transcribed into your message.
    func playHeldReplyNow() {
        guard let r = heldReply, !heldReplySpoken else { return }
        heldReplySpoken = true
        DiagLog.log("reply.play-now", "\(r.count) chars while recording")
        listener.feedPaused = true
        var s = SpeakableStream()
        (s.feed(r) + s.finish()).forEach { speaker.say($0, force: true) }
    }
    private var turnDone = true
    private var circledThisTurn = false
    private var permissionsChecked = false

    init() {
        let d = UserDefaults.standard
        screenshotMode = ScreenshotMode(rawValue: d.string(forKey: "screenshotMode") ?? "") ?? .always
        voiceID = d.string(forKey: "voiceID")
        let cwdPath = d.string(forKey: "cwd") ?? (NSHomeDirectory() + "/Documents/self")
        bridge = ClaudeBridge(launch: .init(cwd: URL(fileURLWithPath: cwdPath),
                                            model: d.string(forKey: "model"),
                                            permissionMode: d.string(forKey: "permissionMode")))
        speaker.voiceID = voiceID
        speaker.provider = ttsProvider
        speaker.openAIVoice = openAIVoice
        speaker.elevenVoiceID = elevenVoiceID
        speaker.onProviderError = { [weak self] m in self?.ttsError = "Cloud voice failed, used macOS voice instead. \(m)" }
        updateSessionLabel()

        listener.onPartial = { [weak self] t in self?.heard = t }
        listener.onLevel = { [weak self] l in self?.level = l }
        speaker.onIdle = { [weak self] in self?.speechDrained() }
        speaker.onLevel = { [weak self] l in
            guard let self, self.phase != .listening else { return }
            self.level = l
        }
        bridge.onEvent = { [weak self] e in self?.handle(e) }
        watcher.onCircle = { [weak self] r in self?.circled(r) }
        startLiveServices()

        hotkey = HotKey(keyCode: 49, modifiers: UInt32(optionKey)) // ⌥Space
        hotkey?.onDown = { [weak self] in self?.hotkeyDown() }
        hotkey?.onUp = { [weak self] in self?.hotkeyUp() }
        if hotkey?.registered == false { phase = .error("\(hotkeyLabel) is taken by another app. Use the mic button for now.") }
    }

    // MARK: - Hotkey: hold to talk, or tap to start / tap to stop

    func hotkeyDown() {
        if finishing { DiagLog.log("hotkey.down", "ignored: still finishing previous recording"); return }
        if reviewText != nil, phase != .listening {
            DiagLog.log("hotkey.down", "re-record: dropping transcript under review")
            cancelReview()
        }
        if listener.isRecording && phase != .listening && !starting {
            // Something changed the phase mid-recording; the recorder is the source of truth.
            DiagLog.log("hotkey.down", "recorder still running while phase=\(phase); restoring listening")
            phase = .listening
        }
        if phase == .listening || starting {
            if toggleRecording {
                DiagLog.log("hotkey.down", "second tap -> stop (hands-free)")
                toggleRecording = false
                Task { await finishListening(reason: "second tap") }
            } else {
                DiagLog.log("hotkey.down", "ignored (key repeat while held)")
            }
            return
        }
        DiagLog.log("hotkey.down", "start")
        downAt = Date()
        upWhileStarting = nil
        onSummon?()
        Task { await startListening() }
    }

    func hotkeyUp() {
        guard let downAt else { DiagLog.log("hotkey.up", "ignored (no matching down)"); return }
        if starting {
            // Released before the mic was ready: decide once listening has started.
            upWhileStarting = Date()
            DiagLog.log("hotkey.up", "while starting, deferred")
            return
        }
        guard phase == .listening else { self.downAt = nil; return }
        self.downAt = nil
        applyRelease(heldFor: Date().timeIntervalSince(downAt))
    }

    private func applyRelease(heldFor held: Double) {
        if held < 0.35 {
            toggleRecording = true    // quick tap: keep listening until the next tap
            DiagLog.log("hotkey.up", String(format: "tap (%.2fs) -> hands-free", held))
        } else {
            DiagLog.log("hotkey.up", String(format: "released after %.2fs -> stop", held))
            Task { await finishListening(reason: "key released") }
        }
    }

    func micButton() {
        if phase == .listening { toggleRecording = false; Task { await finishListening(reason: "mic button") } }
        else { toggleRecording = true; Task { await startListening() } }
    }

    // MARK: - Flow

    func startListening() async {
        // Barge-in: talking over Claude stops it.
        speaker.stop()
        if !turnDone { bridge.interrupt() }
        if !permissionsChecked {
            let p = await SpeechInput.requestPermissions()
            permissionsChecked = p.mic && p.speech
            if !p.mic { phase = .error("Microphone access is off. See README → Permissions."); return }
            if !p.speech { phase = .error("Speech Recognition access is off. See README → Permissions."); return }
        }
        heard = ""
        circledThisTurn = false
        starting = true
        defer {
            starting = false
            if let up = upWhileStarting, let down = downAt, phase == .listening {
                upWhileStarting = nil
                downAt = nil
                applyRelease(heldFor: up.timeIntervalSince(down))
            }
        }
        do {
            try listener.start(contextualStrings: ["Claude", "Claude Code", "Swift", "SwiftUI", "repo", "commit", "README"])
            phase = .listening
            speaker.holding = true          // replies wait until he's done talking (no echo)
            DiagLog.log("record.start", "on-device=\(listener.isOnDevice)")
            showCaption()
            if screenshotMode != .off { watcher.start() }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }

    func finishListening(reason: String = "") async {
        guard (phase == .listening || listener.isRecording), !finishing else { return }
        finishing = true
        defer { finishing = false }
        DiagLog.log("record.stop", reason)
        watcher.stop()
        level = 0
        activity = "Finishing transcription…"
        let text = await listener.stop()
        activity = nil
        DiagLog.log("record.text", "\(text.count) chars: \"\(text)\"")
        guard !text.isEmpty else {
            phase = .idle
            releaseHeld(sending: false)
            scheduleCaptionHide(after: 1)
            return
        }
        heard = text
        finishing = false
        if reviewBeforeSend {
            phase = .idle
            releaseHeld(sending: false)
            beginReview(text)
            return
        }
        phase = .thinking
        releaseHeld(sending: true)
        await send(text)
    }

    // MARK: - Review before sending

    /// Put the transcript in the input box and send it after `reviewDelay` seconds unless
    /// it's edited (pauses), cancelled, or re-recorded (⌥Space again replaces it).
    func beginReview(_ text: String) {
        typed = text                 // set before reviewText so didSet doesn't treat it as an edit
        reviewText = text
        let ends = Date().addingTimeInterval(reviewDelay)
        reviewEndsAt = ends
        showCaption()
        DiagLog.log("review.start", "\(reviewDelay)s, \(text.count) chars")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.reviewDelay ?? 3) * 1_000_000_000))
            guard let self, self.reviewText != nil, self.reviewEndsAt == ends else { return }
            self.commitReview()
        }
    }

    /// Send what's in the input box now (the transcript, edited or not).
    func commitReview() {
        guard reviewText != nil else { return }
        DiagLog.log("review.send")
        sendTyped()
    }

    /// Drop the pending transcript without sending.
    func cancelReview() {
        guard reviewText != nil else { return }
        DiagLog.log("review.cancel")
        reviewText = nil
        reviewEndsAt = nil
        typed = ""
        heard = ""
        scheduleCaptionHide(after: 1)
    }

    /// Stop the countdown and keep the text for editing (Return sends).
    func pauseReview() {
        guard reviewText != nil else { return }
        reviewEndsAt = nil
        DiagLog.log("review.paused", "edit")
    }

    func cancelListening() {
        DiagLog.log("record.cancel")
        defer { releaseHeld(sending: false) }
        watcher.stop()
        listener.cancel()
        level = 0
        phase = .idle
        heard = ""
        scheduleCaptionHide(after: 1)
    }

    func sendTyped() {
        reviewText = nil
        reviewEndsAt = nil
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        heard = t
        Task { await send(t) }
    }

    func send(_ text: String) async {
        speaker.stop()
        if screenshotMode == .always && !circledThisTurn {
            await attachScreenWithCursor()
        }
        if case .live(let s) = target {
            sendLive(text, to: s)
            return
        }
        let images = attachments.map { ClaudeBridge.Image(mediaType: "image/jpeg", data: $0.jpeg) }
        var prompt = text
        if !attachments.isEmpty {
            prompt += "\n\n[Attached: " + attachments.map(\.label).joined(separator: "; ") + "]"
        }
        turns.append(Turn(role: .you, text: text, imageCount: attachments.count))
        replyTurnID = nil
        reply = ""
        activity = nil
        speakable.reset()
        turnDone = false
        phase = .thinking
        showCaption()
        do {
            try bridge.send(text: prompt, images: images)
            attachments.removeAll()
            updateSessionLabel()
        } catch {
            turnDone = true
            phase = .error(error.localizedDescription)
        }
    }

    func stopEverything() {
        speaker.stop()
        if !turnDone { bridge.interrupt() }
        if phase == .listening { cancelListening() }
        phase = .idle
        level = 0
        scheduleCaptionHide(after: 2)
    }

    // MARK: - Claude events

    private func handle(_ e: ClaudeBridge.Event) {
        switch e {
        case .started:
            updateSessionLabel()
        case .text(let t):
            if phase == .thinking { phase = .responding }
            activity = nil
            reply += t
            if !muted && speakReplies { speakable.feed(t).forEach { speaker.say($0) } }
        case .tool(let name):
            activity = "Using \(Self.friendlyTool(name))…"
        case .done(let isError, let message):
            turnDone = true
            activity = nil
            if !muted && speakReplies { speakable.finish().forEach { speaker.say($0) } }
            if isError {
                setPhase(.error(message ?? "Claude Code reported an error."))
            } else if reply.isEmpty, let message, !message.isEmpty {
                reply = message
                if !muted && speakReplies { speaker.say(message) }
            }
            if !speaker.isSpeaking, phase != .listening, !isErrorPhase { phase = .idle; scheduleCaptionHide() }
        case .exited(let msg):
            turnDone = true
            activity = nil
            setPhase(.error(msg))
        }
    }

    var isErrorPhase: Bool { if case .error = phase { return true }; return false }

    private func speechDrained() {
        if listener.feedPaused { listener.feedPaused = false }   // tap-to-hear finished; keep transcribing
        if turnDone, phase == .responding || phase == .thinking { phase = .idle }
        objectWillChange.send()
        scheduleCaptionHide()
    }

    func showCaption() {
        hideWork?.cancel()
        captionVisible = true
    }

    /// Fade the caption a few seconds after things go quiet, unless pinned or hovered.
    func scheduleCaptionHide(after seconds: Double = 6) {
        hideWork?.cancel()
        guard !expanded, !hovering, phase == .idle || isErrorPhase, !speaker.isSpeaking else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.expanded, !self.hovering, self.phase == .idle || self.isErrorPhase else { return }
            self.captionVisible = false
            self.onIdle?()
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (isErrorPhase ? 10 : seconds), execute: w)
    }

    static func friendlyTool(_ name: String) -> String {
        if name.hasPrefix("mcp__") { return name.split(separator: "__").dropFirst().joined(separator: " ") }
        return name
    }

    // MARK: - Screen

    private func circled(_ rect: CGRect) {
        circledThisTurn = true
        FlashOverlay.show(rect)
        Task { await attachRegion(rect) }
    }

    func attachRegion(_ rect: CGRect) async {
        let padded = rect.insetBy(dx: -24, dy: -24)
        do {
            let shot = try await ScreenCapture.captureScreen(containing: CGPoint(x: rect.midX, y: rect.midY))
            if let crop = ScreenCapture.crop(shot, region: padded),
               let a = ScreenCapture.makeAttachment(crop, label: "close-up of the region the user circled") {
                attachments.append(a)
            }
            let ctx = ScreenCapture.screenWithRegion(shot, region: padded)
            if let a = ScreenCapture.makeAttachment(ctx, label: "full screen, circled region boxed in red") {
                attachments.append(a)
            }
        } catch {
            screenError(error)
        }
    }

    func attachScreenWithCursor() async {
        let cursor = NSEvent.mouseLocation
        do {
            let shot = try await ScreenCapture.captureScreen(containing: cursor)
            let img = ScreenCapture.screenWithCursor(shot, cursor: cursor)
            if let a = ScreenCapture.makeAttachment(img, label: "user's screen, red ring = cursor position") {
                attachments.append(a)
            }
        } catch {
            screenError(error)
        }
    }

    func attachDraggedRegion() {
        Task {
            if let img = await ScreenCapture.dragRegion(),
               let a = ScreenCapture.makeAttachment(img, label: "region the user selected") {
                attachments.append(a)
                showCaption()
            }
        }
    }

    func removeAttachment(_ a: Attachment) { attachments.removeAll { $0.id == a.id } }

    private func screenError(_ error: Error) {
        if !ScreenCapture.hasPermission {
            ScreenCapture.requestPermission()
            activity = "Screen Recording isn't active for this build. If it's already on in System Settings, remove Claude Companion there with −, reopen the app and allow again."
        } else {
            activity = "Screenshot failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Sessions & settings

    var launch: ClaudeBridge.Launch { bridge.launch }
    var currentSessionID: String? { bridge.sessionID }

    func newSession(in dir: URL) {
        UserDefaults.standard.set(dir.path, forKey: "cwd")
        var l = bridge.launch
        l.cwd = dir; l.resume = nil; l.fork = false
        bridge.configure(l)
        reply = ""; heard = ""; turns.removeAll()
        updateSessionLabel()
    }

    func resume(_ s: SessionInfo, fork: Bool) {
        var l = bridge.launch
        l.cwd = URL(fileURLWithPath: s.cwd); l.resume = s.id; l.fork = fork
        bridge.configure(l)
        reply = ""; heard = ""; turns.removeAll()
        sessionLabel = "\(fork ? "Fork of" : "Resumed") “\(s.snippet.prefix(28))…”"
    }

    func setModel(_ m: String?) {
        UserDefaults.standard.set(m, forKey: "model")
        var l = bridge.launch; l.model = m; l.resume = bridge.sessionID; l.fork = false
        bridge.configure(l)
    }

    func setPermissionMode(_ m: String?) {
        UserDefaults.standard.set(m, forKey: "permissionMode")
        var l = bridge.launch; l.permissionMode = m; l.resume = bridge.sessionID; l.fork = false
        bridge.configure(l)
    }

    private func updateSessionLabel() {
        let folder = bridge.launch.cwd.lastPathComponent
        if let id = bridge.sessionID {
            sessionLabel = "\(folder) · \(id.prefix(8))"
        } else {
            sessionLabel = "\(folder) · new session"
        }
    }

    /// `--demo`: cycle idle -> listening -> thinking -> speaking with a synthetic voice level.
    func runDemo() {
        let steps: [(OrbMood, String, String, Double)] = [
            (.idle, "", "", 2.5),
            (.listening, "Why is the build failing on this screen?", "", 4),
            (.thinking, "Why is the build failing on this screen?", "", 3),
            (.speaking, "Why is the build failing on this screen?",
             "The linker can't find **Carbon**. Add it to `linkerSettings` in Package.swift and rebuild.", 5),
        ]
        var t0 = Date()
        var idx = 0
        func apply() {
            let s = steps[idx]
            demoMood = s.0
            heard = s.1
            reply = s.2
            captionVisible = s.0 != .idle
            activity = s.0 == .thinking ? "Using Read…" : nil
            phase = s.0 == .thinking ? .thinking : .idle
            t0 = Date()
        }
        apply()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(t0)
                let s = steps[idx]
                if s.0 == .listening || s.0 == .speaking {
                    // Syllable-ish envelope.
                    let env = max(0, sin(t * 9) * 0.5 + sin(t * 3.3) * 0.35 + 0.2)
                    self.level = Float(min(1, env * Double.random(in: 0.7...1.0)))
                } else { self.level = 0 }
                if t > s.3 { idx = (idx + 1) % steps.count; apply() }
            }
        }
    }

    // Used by AppState+Live.
    func say(_ s: String) { speaker.say(s) }
    var isSpeakingNow: Bool { speaker.isSpeaking }
    func turnDoneFromLive() { turnDone = true }

    func shutdown() {
        bridge.stop()
        speaker.stop()
    }
}
