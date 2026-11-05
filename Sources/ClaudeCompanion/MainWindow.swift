import SwiftUI
import AVFoundation
import Speech

// MARK: - Design tokens
// Calm, paper-like neutrals with one warm accent. Serif display type for the
// few headings (New York, via .serif), SF for everything else.

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Theme {
    static let paper    = Color(light: 0xF6F3ED, dark: 0x171614)
    static let sidebar  = Color(light: 0xEFEBE3, dark: 0x1D1C19)
    static let surface  = Color(light: 0xFFFFFF, dark: 0x23221F)
    static let ink      = Color(light: 0x1E1C19, dark: 0xEEE9E1)
    static let muted    = Color(light: 0x8B857B, dark: 0x8E887E)
    static let hairline = Color(light: 0xE4DED3, dark: 0x302E2A)
    static let accent   = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let live     = Color(light: 0x7FBF93, dark: 0x8FCB9F)
    static let offline  = Color(light: 0xD9897A, dark: 0xE89A8A)   // soft red: "replies won't come back"   // soft sage: "this session is connected"

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
}

/// Orb + smoothing, sized for any surface.
struct LiveOrb: View {
    @ObservedObject var state: AppState
    var size: CGFloat
    @StateObject private var box = OrbFollower()

    var body: some View {
        TimelineView(.animation(minimumInterval: state.mood == .idle ? 1.0 / 30 : 1.0 / 60)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let _ = box.f.step(target: Double(state.level), time: t)
            OrbView(mood: state.mood, level: box.f.value, time: t)
                .frame(width: size, height: size)
        }
    }
}

final class OrbFollower: ObservableObject { let f = LevelFollower() }

// MARK: - Window root

enum Section: String, CaseIterable, Identifiable {
    case conversation = "Conversation", sessions = "Sessions", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .conversation: return "waveform"
        case .sessions: return "rectangle.stack"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @ObservedObject var state: AppState
    @State private var section: Section = .conversation

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            Group {
                switch section {
                case .conversation: ConversationView(state: state)
                case .sessions: SessionsView(state: state) { section = .conversation }
                case .settings: SettingsView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper.windowDraggable(state))
            .overlay(alignment: .top) {
                // A grab strip along the top edge (works even over scrolling content).
                Color.clear.frame(height: 22).windowDraggable(state)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 720, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LiveOrb(state: state, size: 18)
                Text("Companion").font(Theme.display(18)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                Spacer()
                Button { state.toggleExpand() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .help("Collapse to pill (⌥⇧Space or Esc)")
            }
            .padding(.top, 22).padding(.bottom, 22).padding(.horizontal, 6)

            ForEach(Section.allCases) { s in
                Button { section = s } label: {
                    HStack(spacing: 10) {
                        Image(systemName: s.symbol).frame(width: 16)
                        Text(s.rawValue)
                        Spacer()
                    }
                    .font(.system(size: 13, weight: section == s ? .semibold : .regular))
                    .foregroundStyle(section == s ? Theme.ink : Theme.muted)
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(section == s ? Theme.surface : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                TargetPicker(state: state)
                HStack(spacing: 4) {
                    Keycap("⌥"); Keycap("Space")
                    Text("hold to talk").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 196)
        .background(Theme.sidebar.windowDraggable(state))
    }
}

/// Drag the expanded window from any non-interactive area this is applied to.
struct WindowDragArea: ViewModifier {
    let state: AppState
    @State private var active = false
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in
                    if !active { active = true; state.onWindowDrag?(.began) }
                    state.onWindowDrag?(.changed)
                }
                .onEnded { _ in active = false; state.onWindowDrag?(.ended) })
    }
}

extension View {
    func windowDraggable(_ state: AppState) -> some View { modifier(WindowDragArea(state: state)) }
}

/// The footer's "who am I talking to" label, which is also the session picker:
/// "(o) Job Search · live ⌄". The ring's inner dot is green when replies come back, red when not.
/// Clicking opens a list of the Claude Code sessions open in iTerm (refreshed on open).
/// SwiftUI's macOS Menu flattens custom labels (it dropped the dot), so this is a popover.
/// Picking a session pins it (and stops following); "Follow active" unpins.
struct TargetPicker: View {
    @ObservedObject var state: AppState
    @State private var open = false
    @State private var refreshing = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                LiveDot(connected: state.targetConnected)
                if state.isPinned { Image(systemName: "pin.fill").font(.system(size: 8.5)) }
                Text(state.targetLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .semibold)).opacity(0.7)
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .help(state.followActive ? "Following the most recently active session. Click to pick one."
                                 : "Pinned to this session. Click to pick another, or follow the active one.")
        .popover(isPresented: $open, arrowEdge: .top) {
            // Popovers get their own window, which follows the system appearance, not the
            // app window's. Match the window so Theme colors resolve the same way.
            list.preferredColorScheme(scheme).environment(\.colorScheme, scheme)
        }
        .onChange(of: open) { _, isOpen in
            guard isOpen else { return }
            refreshing = true
            state.hub.refreshITerm { refreshing = false }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Claude Code sessions").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                Spacer()
                if refreshing { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            if state.liveSessions.isEmpty && !refreshing {
                Text("None open in iTerm. Start one with cc-voice.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 4)
            }
            ForEach(state.liveSessions) { s in
                row(connected: s.canPush, title: s.folderName,
                    detail: s.canPush ? "live" : "iTerm only, no replies", key: AppState.key(for: s))
            }
            Divider().padding(.vertical, 4)
            row(connected: true, title: "Background", detail: state.launch.cwd.lastPathComponent, key: "background")
            Toggle("Follow active session", isOn: $state.followActive)
                .toggleStyle(.checkbox).font(.system(size: 11.5)).padding(.horizontal, 8).padding(.top, 6)
        }
        .padding(10).frame(minWidth: 240)
        .background(Theme.surface)
    }

    private func row(connected: Bool, title: String, detail: String, key: String) -> some View {
        let selected = state.targetKey == key
        return Button { state.pick(key: key); open = false } label: {
            HStack(spacing: 7) {
                LiveDot(connected: connected)
                Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.ink.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Connection status, always shown next to the session label: a faint gray ring with a
/// tiny dot inside. Green = replies come back (push channel live, or the app's own
/// background session). Red = not connected: words can still be typed into the iTerm tab,
/// but nothing comes back (usually the session was started with `claude`, not `cc-voice`).
struct LiveDot: View {
    let connected: Bool
    var ring: Color = Theme.ink.opacity(0.18)   // the dark pill passes a light ring
    var body: some View {
        let dot = connected ? Theme.live : Theme.offline
        ZStack {
            Circle().strokeBorder(ring, lineWidth: 1)
            Circle().fill(dot).frame(width: 4, height: 4)
                .shadow(color: dot.opacity(0.9), radius: 2)
        }
        .frame(width: 10, height: 10).padding(.leading, 1)
        .help(connected ? "Connected: replies come back and are spoken."
                        : "Not connected: start the session with cc-voice to get replies back.")
        .accessibilityLabel(connected ? "Connected" : "Not connected")
    }
}

struct Keycap: View {
    let label: String
    init(_ l: String) { label = l }
    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.ink.opacity(0.75))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
    }
}

// MARK: - Conversation

struct ConversationView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            hero
            transcript
            Composer(state: state)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: state.mood)
        .animation(.easeOut(duration: 0.25), value: state.turns.count)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            LiveOrb(state: state, size: state.turns.isEmpty ? 150 : 96)
            headline
                .font(Theme.display(state.turns.isEmpty ? 26 : 20))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            if state.canRetryViaITerm {
                Button("Type it into iTerm instead") { state.retryViaITerm() }.buttonStyle(.bordered)
            }
            if state.phase == .listening {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(state.heard.isEmpty ? " " : state.heard)
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 520)
                            .frame(maxWidth: .infinity)
                        Color.clear.frame(height: 1).id("heardEnd")
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: state.heard) { _, _ in proxy.scrollTo("heardEnd", anchor: .bottom) }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, state.turns.isEmpty ? 70 : 36)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var headline: some View {
        switch state.phase {
        case .listening: Text("Listening") + Text("…").foregroundColor(Theme.muted)
        case .thinking: Text(state.activity ?? "Thinking").italic()
        case .responding: state.mood == .speaking ? Text("Speaking").italic() : Text(state.activity ?? "Thinking").italic()
        case .error(let m): Text(m).font(.system(size: 13)).foregroundColor(.red.opacity(0.8))
        case .idle:
            if state.mood == .speaking { Text("Speaking").italic() }
            else if state.turns.isEmpty { Text("Don't type, ") + Text("just talk.").italic() }
            else { Text("Hold ⌥Space to reply") }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(state.turns) { turn in
                        TurnRow(turn: turn).id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 8)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: state.turns.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct TurnRow: View {
    let turn: Turn
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(turn.role == .you ? "YOU" : "CLAUDE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(turn.role == .you ? Theme.muted : Theme.accent)
                if turn.imageCount > 0 {
                    Label("\(turn.imageCount) screenshot\(turn.imageCount == 1 ? "" : "s")", systemImage: "photo")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                }
            }
            Text(markdown(turn.text))
                .font(.system(size: turn.role == .you ? 14 : 14.5))
                .foregroundStyle(turn.role == .you ? Theme.ink.opacity(0.62) : Theme.ink)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct Composer: View {
    @ObservedObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(state.attachments) { a in
                        Image(decorative: a.image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 46)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
                            .overlay(alignment: .topTrailing) {
                                Button { state.removeAttachment(a) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.55))
                                }
                                .buttonStyle(.plain).padding(3)
                            }
                            .help(a.label)
                    }
                    Text("Attached to your next message").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 10) {
                TextField("Type to Claude, or hold ⌥Space to talk", text: $state.typed, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { state.sendTyped() }
                Menu {
                    Picker("What Claude sees", selection: $state.screenshotMode) {
                        ForEach(ScreenshotMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                    }
                    .pickerStyle(.inline)
                } label: { Image(systemName: state.screenshotMode.symbol) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Theme.muted)
                    .help("What Claude sees: \(state.screenshotMode.title)")
                IconButton(symbol: "crop", help: "Drag a region of the screen to attach") { state.attachDraggedRegion() }
                VoiceToggle(on: $state.speakReplies)
                micButton
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
        }
        .padding(.horizontal, 40).padding(.bottom, 22).padding(.top, 8)
        .frame(maxWidth: 760)
    }

    private var micButton: some View {
        let busy = state.mood != .idle
        return Button {
            if state.phase == .listening || !busy { state.micButton() } else { state.stopEverything() }
        } label: {
            Image(systemName: state.phase == .listening ? "arrow.up" : (busy ? "stop.fill" : "mic.fill"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(state.phase == .listening ? Theme.accent : Theme.ink.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .help(state.phase == .listening ? "Send" : (busy ? "Stop" : "Talk"))
    }
}

/// "Respond with voice" on/off, with an explicit label so the state is obvious.
struct VoiceToggle: View {
    @Binding var on: Bool
    var compact = false
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash")
                if !compact { Text(on ? "Voice on" : "Voice off").font(.system(size: 11.5, weight: .medium)) }
            }
            .foregroundStyle(on ? Theme.accent : Theme.muted)
            .padding(.horizontal, compact ? 6 : 9).padding(.vertical, 5)
            .background(Capsule().fill(on ? Theme.accent.opacity(0.14) : Theme.hairline.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help(on ? "Respond with voice: ON. Claude's replies are read aloud. Click for text only."
                 : "Respond with voice: OFF. Replies stay as text. Click to have them read aloud.")
    }
}

struct APIKeyField: View {
    let provider: TTSProvider
    let link: String
    @State private var draft = ""
    @State private var saved = false
    var body: some View {
        HStack(spacing: 8) {
            if saved {
                Label("API key saved in Keychain", systemImage: "key.fill").font(.system(size: 12.5))
                Spacer()
                Button("Remove") { if let a = provider.keychainAccount { Keychain.delete(a) }; saved = false }
            } else {
                SecureField("Paste API key", text: $draft).textFieldStyle(.roundedBorder)
                Button("Save") {
                    let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let a = provider.keychainAccount, !k.isEmpty, Keychain.set(k, for: a) { saved = true; draft = "" }
                }
                .disabled(draft.isEmpty)
                Link("Get a key", destination: URL(string: link)!).font(.system(size: 12))
            }
        }
        .onAppear { saved = provider.keychainAccount.flatMap { Keychain.get($0) } != nil }
        .id(provider)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.hairline.opacity(hover ? 0.8 : 0)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

// MARK: - Sessions

struct SessionsView: View {
    @ObservedObject var state: AppState
    var onPicked: () -> Void
    @State private var recent: [SessionInfo] = []
    @State private var query = ""
    @State private var refreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Sessions").font(Theme.display(26)).foregroundStyle(Theme.ink)
                    Spacer()
                    TextField("Search", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                .padding(.top, 28).padding(.bottom, 6)
                HStack(spacing: 6) {
                    Text("Talking to").foregroundStyle(Theme.muted)
                    Text(state.targetLabel).foregroundStyle(Theme.ink).fontWeight(.medium)
                    Text(state.isPinned ? "· pinned" : (state.followActive ? "· following active" : "· automatic")).foregroundStyle(Theme.muted)
                    if state.isPinned { Button("Unpin") { state.unpin() }.buttonStyle(.link) }
                    if !state.followActive { Button("Follow active") { state.followActive = true }.buttonStyle(.link) }
                }
                .font(.system(size: 12.5))
                .padding(.bottom, 22)

                header("Live in your terminals") {
                    Button(refreshing ? "Looking…" : "Find iTerm sessions") {
                        refreshing = true
                        state.hub.refreshITerm { refreshing = false }
                    }
                    .buttonStyle(.link).disabled(refreshing)
                }
                let live = state.liveSessions.filter(matches)
                if live.isEmpty {
                    Text("None yet. Start Claude Code with integration/cc-voice to get a live session (your words appear in that terminal), or click Find iTerm sessions to type into a tab that's already running claude.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                }
                ForEach(Array(live.enumerated()), id: \.element.id) { i, s in liveRow(s, index: i) }

                header("Background session") {
                    Button("New in folder…") { newSession() }.buttonStyle(.link)
                }
                bgRow
                ForEach(recent.filter { query.isEmpty || $0.snippet.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query) }) { r in recentRow(r) }
            }
            .padding(.horizontal, 40).padding(.bottom, 30)
        }
        .onAppear {
            recent = SessionCatalog.recent(limit: 15)
            refreshing = true
            state.hub.refreshITerm { refreshing = false }
        }
    }

    private func matches(_ s: LiveSession) -> Bool {
        query.isEmpty || s.folderName.localizedCaseInsensitiveContains(query) || (s.title ?? "").localizedCaseInsensitiveContains(query)
    }

    private func header<T: View>(_ title: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
            Spacer()
            trailing().font(.system(size: 12))
        }
        .padding(.top, 14).padding(.bottom, 8)
    }

    private func card<C: View>(highlight: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 14) { c() }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(highlight ? Theme.accent.opacity(0.7) : Theme.hairline))
            .padding(.bottom, 8)
    }

    private func isCurrent(_ s: LiveSession) -> Bool {
        if case .live(let t) = state.target { return t.tty == s.tty }
        return false
    }

    private func liveRow(_ s: LiveSession, index: Int) -> some View {
        card(highlight: isCurrent(s)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.folderName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(s.canPush ? "PUSH" : "ITERM").font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(s.canPush ? Theme.accent : Theme.muted)
                    if isCurrent(s) { Text("TALKING TO").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.muted) }
                }
                Text([s.title, s.cwd, s.tty].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button(state.isPinned(s) ? "Pinned" : "Pin") {
                if state.isPinned(s) { state.unpin() } else { state.pin(s); onPicked() }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: .command)
            .help(index < 9 ? "⌘\(index + 1)" : "")
        }
    }

    private var bgRow: some View {
        card(highlight: state.target == .background) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Companion's own session").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Runs claude -p in the background (\(state.sessionLabel)). Replies stream and are spoken as they arrive, but it isn't visible in a terminal.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(state.pinnedKey == "background" ? "Pinned" : "Pin") {
                if state.pinnedKey == "background" { state.unpin() } else { state.pinBackground(); onPicked() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func recentRow(_ r: SessionInfo) -> some View {
        card {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.folderName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    if state.currentSessionID == r.id { Text("CURRENT").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Theme.muted) }
                }
                Text(r.snippet).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Text(r.ageText).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            Button(r.isLikelyLive ? "Fork in background" : "Resume in background") {
                state.resume(r, fork: r.isLikelyLive); state.pinBackground(); onPicked()
            }
            .buttonStyle(.bordered)
        }
        .help(r.cwd)
    }

    private func newSession() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.prompt = "Start session here"
        p.directoryURL = state.launch.cwd
        if p.runModal() == .OK, let url = p.url { state.newSession(in: url); state.pinBackground(); onPicked() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var tick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Settings").font(Theme.display(26)).foregroundStyle(Theme.ink).padding(.top, 28)

                group("Respond with voice") {
                    Toggle("Read Claude's replies aloud", isOn: $state.speakReplies)
                    note("Off: replies stay as text (in the terminal session and this window). Same as the speaker button on the pill.")
                    Picker("Voice engine", selection: $state.ttsProvider) {
                        ForEach(TTSProvider.allCases) { Text($0.title).tag($0) }
                    }
                    switch state.ttsProvider {
                    case .macos:
                        Picker("Voice", selection: Binding(get: { state.voiceID ?? SpeechOutput.defaultVoice?.identifier ?? "" },
                                                           set: { state.voiceID = $0 })) {
                            ForEach(SpeechOutput.englishVoices(), id: \.identifier) { v in
                                Text("\(v.name) · \(v.language) · \(SpeechOutput.qualityLabel(v))").tag(v.identifier)
                            }
                        }
                        HStack {
                            note("Only installed voices are listed. Premium voices sound far better than the Compact ones: System Settings → Accessibility → Spoken Content → System voice → Manage Voices… (try Ava or Zoe Premium). Reopen Settings here afterwards.")
                            Button("Open Spoken Content") {
                                if let u = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent") { NSWorkspace.shared.open(u) }
                            }
                        }
                    case .openai:
                        APIKeyField(provider: .openai, link: "https://platform.openai.com/api-keys")
                        Picker("Voice", selection: $state.openAIVoice) {
                            ForEach(CloudTTS.openAIVoices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        note("Spoken text is sent to OpenAI to be voiced (only the reply text, never audio or screenshots). About $0.015 per minute of speech, roughly $1 per hour.")
                    case .elevenlabs:
                        APIKeyField(provider: .elevenlabs, link: "https://elevenlabs.io/app/settings/api-keys")
                        Picker("Voice", selection: $state.elevenVoiceID) {
                            ForEach(CloudTTS.elevenPresets, id: \.id) { Text($0.name).tag($0.id) }
                            if !CloudTTS.elevenPresets.contains(where: { $0.id == state.elevenVoiceID }) {
                                Text("Custom: \(state.elevenVoiceID)").tag(state.elevenVoiceID)
                            }
                        }
                        TextField("Or paste any voice ID from your ElevenLabs library", text: $state.elevenVoiceID)
                            .textFieldStyle(.roundedBorder)
                        note("Spoken text is sent to ElevenLabs to be voiced. Uses the Flash v2.5 model (lowest latency). Billed in credits: roughly $5–10 per hour of speech on a paid plan.")
                    }
                    HStack {
                        Button("Test voice") { state.testVoice() }
                        if let e = state.ttsError { Text(e).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3) }
                    }
                }

                group("Which session") {
                    Toggle("Follow the active session", isOn: $state.followActive)
                    note("On: Companion talks to whichever live session was most recently active (Claude ran a tool or finished a turn there, or you sent it something), and the label at the bottom left follows it. Off: it stays on the session you pinned. Picking a session from that label or from Sessions pins it and turns this off.")
                }

                group("Delivery to terminal sessions") {
                    Picker("Send my words by", selection: $state.deliveryMode) {
                        ForEach(DeliveryMode.allCases) { Text($0.title).tag($0) }
                    }
                    note("Push needs Claude Code channels. On a Team plan they're off until an Owner enables claude.ai → Organization settings → Claude Code → Channels; until then use “Type into its iTerm tab” (asks once for Automation → iTerm).")
                }

                group("What Claude sees") {
                    Picker("Screen", selection: $state.screenshotMode) {
                        ForEach(ScreenshotMode.allCases) { Text($0.title).tag($0) }
                    }
                    note("While you hold the talk key, circle something with the mouse to point at it. Claude gets a close-up plus the full screen with the area boxed.")
                }

                group("Claude Code") {
                    Picker("Model", selection: Binding(get: { state.launch.model ?? "" }, set: { state.setModel($0.isEmpty ? nil : $0) })) {
                        Text("Claude Code default").tag("")
                        Text("Opus").tag("opus"); Text("Sonnet").tag("sonnet"); Text("Haiku (fastest)").tag("haiku")
                    }
                    Picker("Tool permissions", selection: Binding(get: { state.launch.permissionMode ?? "" }, set: { state.setPermissionMode($0.isEmpty ? nil : $0) })) {
                        Text("Default: anything needing approval is denied").tag("")
                        Text("Accept edits").tag("acceptEdits")
                        Text("Auto mode").tag("auto")
                    }
                }

                group("Window") {
                    Toggle("Show the mini pill when this window isn't in front", isOn: $state.showPill)
                }

                group("Permissions") {
                    permRow("Microphone", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                            pane: "Privacy_Microphone")
                    permRow("Speech Recognition", granted: SFSpeechRecognizer.authorizationStatus() == .authorized,
                            pane: "Privacy_SpeechRecognition")
                    permRow("Screen & System Audio Recording", granted: ScreenCapture.hasPermission,
                            pane: "Privacy_ScreenCapture")
                    note("Already on in System Settings but still shown as off here? macOS is holding a permission for an older build of the app. Select Claude Companion in that list, click − to remove it, then quit and reopen Companion and allow again. (Toggling off and on also works sometimes.) Setting up stable signing (README) stops this happening after rebuilds.")
                }
                .id(tick)
                .onAppear { tick += 1 }
            }
            .padding(.horizontal, 40).padding(.bottom, 40)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.2).foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func permRow(_ name: String, granted: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle").foregroundStyle(granted ? Theme.accent : Theme.muted)
            Text(name)
            Spacer()
            if !granted {
                Button("Open System Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 13))
    }
}
