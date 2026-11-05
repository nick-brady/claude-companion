import AppKit

/// Detects "I'm circling this" with the mouse: a roughly closed loop drawn within
/// a short time window. Pure geometry, no permissions needed.
///
/// Approach: keep the last ~1.6 s of cursor points (resampled to >= 5 pt spacing),
/// walk backwards summing the signed turning angle between successive segments.
/// A full loop accumulates ~360 degrees; back-and-forth wiggles cancel out, straight
/// moves accumulate ~0, and sharp reversals (> ~115 degrees) break the run.
struct CircleGestureDetector {
    var windowSeconds: Double = 1.6
    var requiredTurn: Double = 2 * .pi * 0.85
    var minSize: CGFloat = 24
    var maxSize: CGFloat = 1100
    var minSpacing: CGFloat = 5
    var maxAspect: CGFloat = 4

    private var pts: [(p: CGPoint, t: Double)] = []

    mutating func reset() { pts.removeAll() }

    /// Feed a cursor sample. Returns the loop's bounding box (same coordinates) when a circle completes.
    mutating func add(_ p: CGPoint, at t: Double) -> CGRect? {
        pts.removeAll { t - $0.t > windowSeconds }
        if let last = pts.last, hypot(p.x - last.p.x, p.y - last.p.y) < minSpacing { return nil }
        pts.append((p, t))
        guard pts.count >= 8 else { return nil }

        var turn = 0.0
        var k = pts.count - 2
        while k >= 1 {
            let a = atan2(Double(pts[k + 1].p.y - pts[k].p.y), Double(pts[k + 1].p.x - pts[k].p.x))
            let b = atan2(Double(pts[k].p.y - pts[k - 1].p.y), Double(pts[k].p.x - pts[k - 1].p.x))
            var d = a - b
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            if abs(d) > 2.0 { break }           // sharp reversal: scribble, not a loop
            turn += d
            if abs(turn) >= requiredTurn {
                let loop = pts[(k - 1)...].map(\.p)
                if let box = Self.accept(loop, minSize: minSize, maxSize: maxSize, maxAspect: maxAspect) {
                    pts.removeAll()
                    return box
                }
                break
            }
            k -= 1
        }
        return nil
    }

    private static func accept(_ loop: [CGPoint], minSize: CGFloat, maxSize: CGFloat, maxAspect: CGFloat) -> CGRect? {
        let xs = loop.map(\.x), ys = loop.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return nil }
        let w = x1 - x0, h = y1 - y0
        guard min(w, h) >= minSize, max(w, h) <= maxSize, max(w, h) / max(1, min(w, h)) <= maxAspect else { return nil }
        // Loosely closed: end comes back near the start.
        if let s = loop.first, let e = loop.last, hypot(s.x - e.x, s.y - e.y) > 0.75 * max(w, h) { return nil }
        return CGRect(x: x0, y: y0, width: w, height: h)
    }
}

/// Polls the cursor position at 60 Hz while active (NSEvent.mouseLocation needs no permission)
/// and reports circles.
final class CursorWatcher {
    private var timer: Timer?
    private var detector = CircleGestureDetector()
    private var lastFire: Double = 0
    var onCircle: ((CGRect) -> Void)?

    var isActive: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        detector.reset()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let r = detector.add(NSEvent.mouseLocation, at: now), now - lastFire > 0.8 {
            lastFire = now
            onCircle?(r)
        }
    }
}

/// Brief on-screen confirmation of what was captured.
enum FlashOverlay {
    private static var windows: [NSWindow] = []

    static func show(_ rect: CGRect, color: NSColor = .systemRed) {
        let r = rect.insetBy(dx: -8, dy: -8)
        let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .transient]
        let v = NSView(frame: NSRect(origin: .zero, size: r.size))
        v.wantsLayer = true
        v.layer?.borderColor = color.cgColor
        v.layer?.borderWidth = 3
        v.layer?.cornerRadius = 10
        v.layer?.backgroundColor = color.withAlphaComponent(0.08).cgColor
        w.contentView = v
        w.orderFrontRegardless()
        windows.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                w.animator().alphaValue = 0
            }, completionHandler: {
                w.orderOut(nil)
                windows.removeAll { $0 === w }
            })
        }
    }
}
