import AppKit
import SwiftUI
import AVFoundation
import Carbon

/// One borderless window that is either the pill (+ caption card) or the full
/// window, and morphs between them. Its frame always hugs its content.
final class CompanionPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 80, height: 44),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { true }

    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

struct PillRectKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let n = nextValue(); if n.width > 0 { value = n } }
}

/// Root content: pill, morph frame, or full window.
struct RootView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ZStack {
            if state.morphing {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.paper.opacity(0.88)))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
                    .overlay { LiveOrb(state: state, size: 30) }
                    .transition(.opacity)
            } else if state.expanded {
                MainView(state: state)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6))
                    .transition(.opacity)
            } else {
                CompanionView(state: state)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: state.cardBelow ? .topLeading : .bottomLeading)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.14), value: state.morphing)
        .onPreferenceChange(InteractiveFramesKey.self) { state.interactiveFrames = $0 }
        .onPreferenceChange(PillRectKey.self) { if $0.width > 0 { state.pillRect = $0 } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var state: AppState!
    private var panel: CompanionPanel!
    private var host: NSHostingView<RootView>!
    private var statusItem: NSStatusItem!
    private var tickTimer: Timer?
    private var toggleKey: HotKey?

    /// Center of the orb, global Cocoa coordinates. The pill grows to the right of it, so it is
    /// the one point that stays put across idle, hover, listening/speaking and a waiting reply.
    /// (It is also the center of the idle pill, which is just the orb with 8 pt either side.)
    private var anchor = CGPoint.zero
    private var home = CGPoint.zero
    private var dragOffset = CGPoint.zero
    private var dragging = false
    private var animatingUntil = Date.distantPast

    static let pillShadowPad: CGFloat = 16      // CompanionView's padding
    static let orbInset: CGFloat = 27           // orb center from the content's left edge (12 pt padding + half the 30 pt active orb)
    static let cardWidth: CGFloat = 440         // CaptionCard's width
    static let expandedSize = NSSize(width: 820, height: 600)

    func applicationDidFinishLaunching(_ note: Notification) {
        MainActor.assumeIsolated {
            state = AppState()
            panel = CompanionPanel()
            host = NSHostingView(rootView: RootView(state: state))
            host.sizingOptions = []
            panel.contentView = host
            panel.onEscape = { [weak self] in MainActor.assumeIsolated { self?.escape() } }

            home = loadHome()
            anchor = home
            state.cardBelow = cardShouldGoBelow(anchor)
            panel.setFrame(pillFrame(), display: true)
            panel.orderFrontRegardless()

            state.onSummon = { [weak self] in self?.summonToCursor() }
            state.onToggleExpand = { [weak self] in self?.toggleExpand() }
            state.onIdle = { [weak self] in self?.returnHome() }
            state.onDrag = { [weak self] p in self?.drag(p) }
            state.onWindowDrag = { [weak self] p in self?.dragWindow(p) }

            toggleKey = HotKey(keyCode: 49, modifiers: UInt32(optionKey | shiftKey))   // ⌥⇧Space
            toggleKey?.onDown = { [weak self] in MainActor.assumeIsolated { self?.toggleExpand() } }

            startTick()
            setUpStatusItem()
            if CommandLine.arguments.contains("--demo") { state.runDemo() }
            if CommandLine.arguments.contains("--muted") { state.muted = true }
            if CommandLine.arguments.contains("--expanded") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in MainActor.assumeIsolated { self?.expand() } }
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }

    // MARK: - Geometry

    private func screen(for p: CGPoint) -> NSScreen {
        ScreenCapture.screen(containing: p) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func cardShouldGoBelow(_ p: CGPoint) -> Bool { p.y > screen(for: p).visibleFrame.midY }

    static let pillPanelSize = NSSize(width: 520, height: 440)

    /// Fixed-size transparent frame whose content is leading-aligned so that the orb sits on
    /// `anchor` (card above or below, opening to the right). Areas outside the pill/card are
    /// click-through.
    @MainActor
    private func pillFrame() -> NSRect {
        let s = Self.pillPanelSize
        let pad = Self.pillShadowPad
        let x = anchor.x - pad - Self.orbInset - edgeNudge()
        let y = state.cardBelow ? anchor.y + 22 + pad - s.height : anchor.y - 22 - pad
        return NSRect(x: x.rounded(), y: y.rounded(), width: s.width, height: s.height)
    }

    /// How far the panel is pushed left so the pill and card stay on screen when they grow to
    /// the right near the screen's right edge. The only time the orb moves.
    @MainActor
    private func edgeNudge() -> CGFloat {
        guard let right = state.interactiveFrames.map(\.maxX).max() else { return 0 }
        let vf = screen(for: anchor).visibleFrame
        return max(0, anchor.x - Self.pillShadowPad - Self.orbInset + right + 8 - vf.maxX)
    }

    /// The visible capsule itself on screen (morph start/end): the pill's last laid-out frame
    /// (panel coordinates) at the panel's pill position.
    @MainActor
    private func capsuleRect() -> NSRect {
        let r = state.pillRect
        return NSRect(x: pillFrame().minX + r.minX, y: anchor.y - 22, width: max(44, r.width), height: 44)
    }

    @MainActor
    /// Where the expanded window goes: where he last left it (remembered separately from the
    /// pill's home), else centered on the pill. Always kept fully on a screen.
    private func expandedFrame() -> NSRect {
        let s = Self.expandedSize
        let d = UserDefaults.standard
        var r: NSRect
        if d.object(forKey: "expandedX") != nil {
            r = NSRect(x: d.double(forKey: "expandedX"), y: d.double(forKey: "expandedY"), width: s.width, height: s.height)
        } else {
            r = NSRect(x: anchor.x - s.width / 2, y: anchor.y - s.height / 2, width: s.width, height: s.height)
        }
        return clampToScreen(r)
    }

    private func clampToScreen(_ rect: NSRect) -> NSRect {
        var r = rect
        let center = CGPoint(x: r.midX, y: r.midY)
        let vf = (NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? screen(for: anchor)).visibleFrame
        r.origin.x = min(max(r.minX, vf.minX + 8), vf.maxX - r.width - 8)
        r.origin.y = min(max(r.minY, vf.minY + 8), vf.maxY - r.height - 8)
        return r
    }

    // MARK: - Dragging the expanded window (position remembered separately)

    private var windowDragOffset = CGPoint.zero

    @MainActor
    private func dragWindow(_ phase: AppState.DragPhase) {
        guard state.expanded, !state.morphing else { return }
        let m = NSEvent.mouseLocation
        switch phase {
        case .began:
            windowDragOffset = CGPoint(x: panel.frame.minX - m.x, y: panel.frame.minY - m.y)
        case .changed:
            panel.setFrameOrigin(NSPoint(x: m.x + windowDragOffset.x, y: m.y + windowDragOffset.y))
        case .ended:
            let r = clampToScreen(panel.frame)
            if r != panel.frame { animate(to: r, duration: 0.2) }
            UserDefaults.standard.set(r.minX, forKey: "expandedX")
            UserDefaults.standard.set(r.minY, forKey: "expandedY")
        }
    }

    /// Keeps a summoned orb where the caption card (which opens to its right) fits on screen.
    private func clampAnchor(_ p: CGPoint) -> CGPoint {
        let vf = screen(for: p).visibleFrame
        return CGPoint(x: min(max(p.x, vf.minX + Self.orbInset + 12), vf.maxX - Self.cardWidth + Self.orbInset - 12),
                       y: min(max(p.y, vf.minY + 30), vf.maxY - 30))
    }

    /// The saved home is the idle pill's center, which is the orb's center too, so homes saved
    /// when `anchor` meant the pill's center load unchanged.
    private func loadHome() -> CGPoint {
        let d = UserDefaults.standard
        if d.object(forKey: "homeX") != nil {
            let p = CGPoint(x: d.double(forKey: "homeX"), y: d.double(forKey: "homeY"))
            if NSScreen.screens.contains(where: { NSMouseInRect(p, $0.frame, false) }) { return p }
        }
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return CGPoint(x: vf.minX + 140, y: vf.maxY - 34)          // default: top-left
    }

    private func saveHome() {
        UserDefaults.standard.set(home.x, forKey: "homeX")
        UserDefaults.standard.set(home.y, forKey: "homeY")
    }

    // MARK: - Motion

    private func animate(to frame: NSRect, duration: Double, alpha: CGFloat? = nil,
                         curve: CAMediaTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1),
                         completion: (() -> Void)? = nil) {
        animatingUntil = Date().addingTimeInterval(duration + 0.05)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = curve
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
            if let alpha { panel.animator().alphaValue = alpha }
        }, completionHandler: completion)
    }

    /// Hotkey pressed: the pill glides to just below the cursor.
    @MainActor
    private func summonToCursor() {
        guard !state.expanded else { return }
        let m = NSEvent.mouseLocation
        let target = clampAnchor(CGPoint(x: m.x, y: m.y - 54))
        panel.alphaValue = max(panel.alphaValue, 0.001)
        panel.orderFrontRegardless()
        anchor = target
        state.cardBelow = cardShouldGoBelow(anchor)
        animate(to: pillFrame(), duration: 0.26, alpha: 1)
    }

    /// After a quiet spell: fade a little and glide back home.
    @MainActor
    private func returnHome() {
        guard !state.expanded, !dragging, state.phase == .idle else { return }
        let atHome = hypot(anchor.x - home.x, anchor.y - home.y) < 2
        let hideAtHome = !state.showPill
        if atHome {
            if hideAtHome { animate(to: panel.frame, duration: 0.3, alpha: 0) }
            return
        }
        anchor = home
        state.cardBelow = cardShouldGoBelow(anchor)
        animate(to: pillFrame(), duration: 0.55, alpha: 0.35,
                curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.panel.animator().alphaValue = hideAtHome ? 0 : 1
            }
        }
    }

    @MainActor
    private func toggleExpand() {
        if state.expanded { collapse() } else { expand() }
    }

    @MainActor
    private func expand() {
        guard !state.expanded, !state.morphing else { return }
        state.captionVisible = false
        state.hovering = false
        state.morphing = true
        panel.alphaValue = 1
        panel.setFrame(capsuleRect(), display: true)
        panel.orderFrontRegardless()
        animate(to: expandedFrame(), duration: 0.42) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.morphing = false
                self.state.expanded = true
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKey()
            }
        }
    }

    @MainActor
    private func collapse() {
        guard state.expanded, !state.morphing else { return }
        state.expanded = false
        state.morphing = true
        state.cardBelow = cardShouldGoBelow(anchor)
        animate(to: capsuleRect(), duration: 0.38) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.morphing = false
                self.panel.setFrame(self.pillFrame(), display: true)
                self.state.scheduleCaptionHide()
            }
        }
    }

    @MainActor
    private func escape() {
        if state.expanded { collapse() }
        else if state.phase == .listening { state.cancelListening() }
    }

    // MARK: - Dragging the pill (its drop point becomes home)

    @MainActor
    private func drag(_ phase: AppState.DragPhase) {
        guard !state.expanded else { return }
        let m = NSEvent.mouseLocation
        switch phase {
        case .began:
            dragging = true
            dragOffset = CGPoint(x: anchor.x - m.x, y: anchor.y - m.y)
        case .changed:
            anchor = CGPoint(x: m.x + dragOffset.x, y: m.y + dragOffset.y)
            panel.setFrame(pillFrame(), display: true)
        case .ended:
            dragging = false
            // Gentle snap to nearby screen edges, using the capsule as it is now (hovered, so
            // room for the controls is kept on the right).
            let vf = screen(for: anchor).visibleFrame
            let r = state.pillRect
            let w = max(44, r.width)
            let orbX = Self.pillShadowPad + Self.orbInset - r.minX       // orb center from the capsule's left edge
            var p = anchor
            let snap: CGFloat = 36, margin: CGFloat = 12
            if p.x - orbX - vf.minX < snap { p.x = vf.minX + orbX + margin }
            if vf.maxX - (p.x - orbX + w) < snap { p.x = vf.maxX - (w - orbX) - margin }
            if p.y - 22 - vf.minY < snap { p.y = vf.minY + 22 + margin }
            if vf.maxY - (p.y + 22) < snap { p.y = vf.maxY - 22 - margin }
            if abs(p.x - vf.midX) < 18 { p.x = vf.midX }                 // center detent (the orb, i.e. the idle pill)
            anchor = p
            home = p
            saveHome()
            let below = cardShouldGoBelow(anchor)
            if below != state.cardBelow { state.cardBelow = below }
            animate(to: pillFrame(), duration: 0.2)
        }
    }

    // MARK: - Per-frame housekeeping

    private func startTick() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    @MainActor
    private func tick() {
        // Follow the content's width: the panel only moves when the pill or card would run
        // past the right screen edge (edgeNudge), and never over a drag or an animation.
        if !state.expanded && !state.morphing && !dragging && Date() > animatingUntil {
            let f = pillFrame()
            if abs(f.minX - panel.frame.minX) > 0.5 || abs(f.minY - panel.frame.minY) > 0.5 { panel.setFrame(f, display: false) }
        }
        // Click-through outside the pill/card (the window has padding for shadows).
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - panel.frame.minX, y: host.bounds.height - (p.y - panel.frame.minY))
        let inside = state.expanded || state.morphing || state.interactiveFrames.contains { $0.insetBy(dx: -4, dy: -4).contains(local) }
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        if !inside && state.hovering { state.hovering = false }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Claude Companion")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { buildMenu(menu) }
    }

    @MainActor
    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = state!
        menu.addItem(disabled("Hold \(s.hotkeyLabel) to talk · tap for hands-free"))
        menu.addItem(item("Talk", #selector(talk)))
        menu.addItem(item(s.expanded ? "Collapse to pill  (⌥⇧Space)" : "Expand window  (⌥⇧Space)", #selector(toggleExpanded)))
        menu.addItem(.separator())

        menu.addItem(disabled("Session: \(s.sessionLabel)"))
        menu.addItem(item("New session in folder…", #selector(newSession)))
        let recent = NSMenuItem(title: "Resume recent session", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for info in SessionCatalog.recent() {
            let live = info.isLikelyLive
            let it = NSMenuItem(title: "\(info.folderName) — \(info.snippet)  (\(info.ageText)\(live ? ", live → fork" : ""))",
                                action: #selector(resumeSession(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = info
            it.toolTip = "\(info.cwd)\n\(info.id)" + (live ? "\nLooks open elsewhere, so this forks it (the original is untouched)." : "")
            sub.addItem(it)
        }
        if sub.items.isEmpty { sub.addItem(disabled("No sessions found")) }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())

        let screen = NSMenuItem(title: "What Claude sees", action: nil, keyEquivalent: "")
        let ssub = NSMenu()
        for m in ScreenshotMode.allCases {
            let it = NSMenuItem(title: m.title, action: #selector(setScreenMode(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = m.rawValue; it.state = s.screenshotMode == m ? .on : .off
            ssub.addItem(it)
        }
        screen.submenu = ssub
        menu.addItem(screen)

        let voice = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let vsub = NSMenu()
        let current = s.voiceID ?? SpeechOutput.defaultVoice?.identifier
        for v in SpeechOutput.englishVoices().prefix(30) {
            let it = NSMenuItem(title: "\(v.name) (\(v.language), \(SpeechOutput.qualityLabel(v)))",
                                action: #selector(setVoice(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = v.identifier; it.state = v.identifier == current ? .on : .off
            vsub.addItem(it)
        }
        vsub.addItem(.separator())
        vsub.addItem(disabled("Better voices: System Settings → Accessibility →"))
        vsub.addItem(disabled("Spoken Content → System voice → Manage Voices…"))
        voice.submenu = vsub
        menu.addItem(voice)

        let model = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let msub = NSMenu()
        for (title, value) in [("Claude Code default", nil), ("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku (fastest)", "haiku")] as [(String, String?)] {
            let it = NSMenuItem(title: title, action: #selector(setModel(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = value; it.state = s.launch.model == value ? .on : .off
            msub.addItem(it)
        }
        model.submenu = msub
        menu.addItem(model)

        let perm = NSMenuItem(title: "Tool permissions", action: nil, keyEquivalent: "")
        let psub = NSMenu()
        for (title, value) in [("Default: anything needing approval is denied", nil),
                               ("Accept edits (file edits allowed)", "acceptEdits"),
                               ("Auto mode (classifier decides)", "auto")] as [(String, String?)] {
            let it = NSMenuItem(title: title, action: #selector(setPermission(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = value; it.state = s.launch.permissionMode == value ? .on : .off
            psub.addItem(it)
        }
        perm.submenu = psub
        menu.addItem(perm)

        menu.addItem(.separator())
        menu.addItem(item("Reset pill home to top-left of this screen", #selector(recenter)))
        menu.addItem(item("Quit Claude Companion", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func talk() { MainActor.assumeIsolated { state.micButton() } }
    @objc private func toggleExpanded() { MainActor.assumeIsolated { toggleExpand() } }
    @objc private func recenter() {
        MainActor.assumeIsolated {
            home = loadDefaultHome(); anchor = home; saveHome()
            state.cardBelow = cardShouldGoBelow(anchor)
            animate(to: state.expanded ? expandedFrame() : pillFrame(), duration: 0.3, alpha: 1)
        }
    }

    private func loadDefaultHome() -> CGPoint {
        let vf = screen(for: NSEvent.mouseLocation).visibleFrame
        return CGPoint(x: vf.minX + 140, y: vf.maxY - 34)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func newSession() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Start session here"
        p.directoryURL = MainActor.assumeIsolated { state.launch.cwd }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let url = p.url {
            MainActor.assumeIsolated { state.newSession(in: url) }
        }
    }

    @objc private func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? SessionInfo else { return }
        MainActor.assumeIsolated { state.resume(info, fork: info.isLikelyLive) }
    }

    @objc private func setScreenMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = ScreenshotMode(rawValue: raw) else { return }
        MainActor.assumeIsolated { state.screenshotMode = m }
    }

    @objc private func setVoice(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { state.voiceID = sender.representedObject as? String }
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { state.setModel(sender.representedObject as? String) }
    }

    @objc private func setPermission(_ sender: NSMenuItem) {
        MainActor.assumeIsolated { state.setPermissionMode(sender.representedObject as? String) }
    }
}
