import SwiftUI

/// The whole floating UI: a caption card that appears above a small dark pill.
/// Everything is leading-aligned and the orb is kept at a fixed spot (`AppDelegate.orbInset`
/// from the content's left edge), so when the pill grows (hover, listening, a waiting reply)
/// it grows to the right and the orb stays where it is on screen.
struct CompanionView: View {
    @ObservedObject var state: AppState
    @StateObject private var follower = FollowerBox()
    @FocusState private var fieldFocused: Bool
    @State private var dragging = false
    @State private var tip: PillTip?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.cardBelow { pill }
            if state.captionVisible {
                CaptionCard(state: state, fieldFocused: $fieldFocused)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: state.cardBelow ? .top : .bottom)))
            }
            if !state.cardBelow { pill }
        }
        .padding(16)
        .coordinateSpace(name: PillTip.space)
        .onPreferenceChange(PillTipKey.self) { tip = $0 }
        .overlay { if let tip { PillTipLabel(tip: tip, below: state.cardBelow).transition(.opacity) } }
        .animation(.easeOut(duration: 0.12), value: tip)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.captionVisible)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.expanded)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: state.mood)
        .animation(.easeOut(duration: 0.2), value: state.hovering)
        .environment(\.colorScheme, .dark)
    }

    private var isActive: Bool { state.mood != .idle }

    /// The orb's center measured from the capsule's left edge: the pill's horizontal padding
    /// plus half the orb. It changes with the state (18 idle, 22 hovered, 27 active), and the
    /// pill is inset by the difference so the orb's center never moves.
    private var orbCenter: CGFloat { (isActive || state.hovering ? 12 : 8) + (isActive ? 15 : 10) }

    private var pill: some View {
        TimelineView(.animation(minimumInterval: isActive ? 1.0 / 60 : 1.0 / 24)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let _ = follower.f.step(target: Double(state.level), time: t)
            HStack(spacing: 10) {
                OrbView(mood: state.mood, level: follower.f.value, time: t)
                    .frame(width: isActive ? 30 : 20, height: isActive ? 30 : 20)
                    .pillTip("Hold \(state.hotkeyLabel) to talk · click to expand · drag to move")
                if isActive {
                    WaveBars(mood: state.mood, history: follower.f.history, time: t)
                        .frame(width: 92, height: 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
                }
                if state.replyWaiting {
                    Button { state.playHeldReplyNow() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.bubble.fill")
                            Text("reply waiting")
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(OrbMood.speaking.colors[0])
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .pillTip("Claude answered while you were talking · click to hear it now (mic pauses while it plays)")
                    .transition(.opacity)
                }
                if state.hovering || state.expanded {
                    controls.transition(.opacity)
                } else if !isActive && !state.attachments.isEmpty {
                    Image(systemName: "photo").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, isActive || state.hovering ? 12 : 8)
            .padding(.vertical, isActive ? 7 : 5)
            .background(PillBackground())
        }
        .frame(height: 44)
        .contentShape(Capsule())
        .onHover { state.hovering = $0 }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { v in
                if !dragging { dragging = true; state.onDrag?(.began) }
                state.onDrag?(.changed)
            }
            .onEnded { _ in dragging = false; state.onDrag?(.ended) })
        .onTapGesture { state.toggleExpand() }
        .reportFrame()
        .background(GeometryReader { g in Color.clear.preference(key: PillRectKey.self, value: g.frame(in: .global)) })
        .padding(.leading, AppDelegate.orbInset - orbCenter)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Screen", selection: $state.screenshotMode) {
                    ForEach(ScreenshotMode.allCases) { m in Label(m.title, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: state.screenshotMode.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .pillTip("What Claude sees: \(state.screenshotMode.title)")
            PillButton(symbol: "crop", tip: "Drag a region of the screen to attach") { state.attachDraggedRegion() }
            PillButton(symbol: state.speakReplies ? "speaker.wave.2.fill" : "speaker.slash.fill",
                       tip: state.speakReplies ? "Voice on: replies are read aloud (click for text only)"
                                               : "Voice off: replies stay as text (click to hear them)") { state.speakReplies.toggle() }
            if state.mood != .idle {
                PillButton(symbol: "stop.fill",
                           tip: state.phase == .listening ? "Cancel listening (nothing is sent)"
                                                          : "Stop Claude (\(state.hotkeyLabel) also interrupts)") { state.stopEverything() }
            } else {
                PillButton(symbol: "mic.fill", tip: "Talk hands-free (tap \(state.hotkeyLabel) to send)") { state.micButton() }
            }
            PillButton(symbol: "arrow.up.left.and.arrow.down.right", tip: "Expand window (⌥⇧Space)") { state.toggleExpand() }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.85))
    }
}

private final class FollowerBox: ObservableObject { let f = LevelFollower() }

struct PillBackground: View {
    var body: some View {
        ZStack {
            Capsule().fill(.ultraThinMaterial)
            Capsule().fill(Color.black.opacity(0.62))
            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }
}

struct PillButton: View {
    let symbol: String
    let tip: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pillTip(tip)
    }
}

// MARK: - Hover labels

/// The pill's own tooltip. `.help()` never shows here: macOS only draws tooltips for the
/// active app, and the pill is a non-activating panel of an accessory app (the expanded
/// window activates, so `.help()` is fine there). Each control reports its label and frame
/// through a preference after a short hover; CompanionView draws the one label on the card's
/// side of the pill (the side with room inside the panel), clamped to the pill's width.
struct PillTip: Equatable {
    static let space = "pill"
    let text: String
    let frame: CGRect           // in the `space` coordinate space
}

struct PillTipKey: PreferenceKey {
    static var defaultValue: PillTip? = nil
    static func reduce(value: inout PillTip?, nextValue: () -> PillTip?) { if let n = nextValue() { value = n } }
}

extension View {
    func pillTip(_ text: String) -> some View { modifier(PillTipModifier(text: text)) }
}

private struct PillTipModifier: ViewModifier {
    let text: String
    @State private var shown = false
    @State private var delay: Task<Void, Never>?
    func body(content: Content) -> some View {
        content
            .onHover { inside in
                delay?.cancel()
                if inside {
                    delay = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        if !Task.isCancelled { shown = true }
                    }
                } else { shown = false }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: PillTipKey.self,
                                       value: shown ? PillTip(text: text, frame: g.frame(in: .named(PillTip.space))) : nil)
            })
    }
}

struct PillTipLabel: View {
    let tip: PillTip
    let below: Bool
    private let gap: CGFloat = 7
    var body: some View {
        GeometryReader { g in
            Text(tip.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.72)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                )
                .fixedSize()
                // Centered on the control, kept inside the content area (the 16 pt padding).
                .alignmentGuide(.leading) { d in
                    let pad = AppDelegate.pillShadowPad
                    let x = min(max(tip.frame.midX - d.width / 2, pad), max(pad, g.size.width - pad - d.width))
                    return -x
                }
                .alignmentGuide(.top) { d in -(below ? tip.frame.maxY + gap : tip.frame.minY - gap - d.height) }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

/// What you said, Claude's reply, attachments and (when pinned) a text field.
struct CaptionCard: View {
    @ObservedObject var state: AppState
    var fieldFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                LiveDot(connected: state.targetConnected, ring: .white.opacity(0.28))
                if state.isPinned { Image(systemName: "pin.fill").font(.system(size: 8.5)) }
                Marquee(text: state.targetDisplayLabel, maxWidth: 150)
                Spacer(minLength: 8)
                Image(systemName: state.speakReplies ? "speaker.wave.2.fill" : "speaker.slash")
                Text(state.speakReplies ? "voice" : "text only")
            }
            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38))
            if !state.heard.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(state.heard)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(state.phase == .listening ? 0.8 : 0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("heardEnd")
                    }
                    .frame(maxHeight: state.phase == .listening ? 140 : 54)
                    .onChange(of: state.heard) { _, _ in proxy.scrollTo("heardEnd", anchor: .bottom) }
                }
            } else if state.phase == .listening {
                Text("Listening…").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.4))
            }
            ReviewBar(state: state, onDark: true, onEdit: { state.onSummon?() })
            if !state.reply.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(markdown(state.reply))
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: state.expanded ? 320 : 150)
                    .onChange(of: state.reply) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            if state.canRetryViaITerm {
                Button("Type it into iTerm instead") { state.retryViaITerm() }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let s = state.statusText {
                HStack(spacing: 6) {
                    if case .error = state.phase { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    Text(s).lineLimit(3)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
            }
            if !state.attachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(state.attachments) { a in
                        Image(decorative: a.image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.15)))
                            .help(a.label)
                            .onTapGesture { state.removeAttachment(a) }
                    }
                    Text("sent with your next message · click to remove")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(14)
        .frame(width: AppDelegate.cardWidth)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        )
        .onHover { state.hovering = $0 }
        .reportFrame()
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

// MARK: - Click-through support

/// Frames (in the hosting view's top-left coordinates) of the parts that should take clicks.
/// The panel is large and transparent; everything else lets clicks fall through.
struct InteractiveFramesKey: PreferenceKey {
    static var defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    func reportFrame() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: InteractiveFramesKey.self, value: [g.frame(in: .global)])
        })
    }
}
