import SwiftUI

/// Visual state shared by the orb and the waveform.
enum OrbMood: Equatable {
    case idle, listening, thinking, speaking, error

    var colors: [Color] {
        switch self {
        case .idle:      return [Color(white: 0.75), Color(white: 0.45)]
        case .listening: return [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.45, green: 0.66, blue: 1.0)]
        case .thinking:  return [Color(red: 0.72, green: 0.58, blue: 1.0), Color(red: 0.85, green: 0.47, blue: 0.34)]
        case .speaking:  return [Color(red: 1.0, green: 0.78, blue: 0.62), Color(red: 0.85, green: 0.47, blue: 0.34)]
        case .error:     return [Color(red: 1.0, green: 0.55, blue: 0.5), Color(red: 0.8, green: 0.2, blue: 0.2)]
        }
    }
}

/// Smooths a jumpy 0...1 level (fast attack, slow release) and keeps a short history
/// for the bars. Mutated during rendering; deliberately not observable.
final class LevelFollower {
    private(set) var value: Double = 0
    private(set) var history: [Double] = Array(repeating: 0, count: 24)
    private var lastPush: Double = 0
    private var lastTime: Double = 0

    func step(target: Double, time: Double) {
        let dt = max(0, min(0.1, time - lastTime))
        lastTime = time
        let k = target > value ? 1 - exp(-dt * 28) : 1 - exp(-dt * 7)
        value += (target - value) * k
        if time - lastPush > 0.045 {
            lastPush = time
            history.removeFirst()
            history.append(value)
        }
    }
}

/// A soft, living orb: a wobbling blob with layered glows. Its energy follows the
/// current level (Claude's voice while speaking, Nick's mic while listening).
struct OrbView: View {
    var mood: OrbMood
    var level: Double            // smoothed 0...1
    var time: Double

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let base = min(size.width, size.height) / 2
            let energy: Double = {
                switch mood {
                case .idle: return 0.04
                case .thinking: return 0.22
                case .error: return 0.05
                case .listening, .speaking: return 0.10 + level * 0.9
                }
            }()
            let breathe = 0.5 + 0.5 * sin(time * (mood == .idle ? 1.1 : 2.2))
            let r = base * (0.62 + 0.06 * breathe * (mood == .idle ? 1 : 0.4) + 0.18 * (mood == .speaking || mood == .listening ? level : 0))
            let cols = mood.colors

            // Outer glow
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: base * 0.16))
                g.opacity = 0.30 + 0.45 * energy
                let gr = min(r * 1.12, base * 0.84)
                g.fill(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                       with: .color(cols[1]))
            }

            // Two wobbling blobs, additive, slightly out of phase.
            for layer in 0..<2 {
                let phase = Double(layer) * 1.7
                let spin = mood == .thinking ? time * 2.4 : time * 0.6
                let path = blob(center: c, radius: r * (layer == 0 ? 1 : 0.86), time: time + phase,
                                wobble: 0.035 + energy * 0.16, spin: spin + phase)
                let grad = Gradient(colors: layer == 0 ? cols : cols.reversed())
                let a = CGPoint(x: c.x + cos(spin) * r, y: c.y + sin(spin) * r)
                let b = CGPoint(x: c.x - cos(spin) * r, y: c.y - sin(spin) * r)
                ctx.drawLayer { g in
                    g.blendMode = layer == 0 ? .normal : .plusLighter
                    g.opacity = layer == 0 ? 0.95 : 0.55
                    g.fill(path, with: .linearGradient(grad, startPoint: a, endPoint: b))
                }
            }

            // Specular highlight
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: r * 0.18))
                g.opacity = 0.55
                g.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.62, width: r * 0.7, height: r * 0.45)),
                       with: .color(.white))
            }

            // Expanding ring on voice peaks.
            if mood == .speaking || mood == .listening {
                let ringR = r * (1.12 + 0.35 * level)
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2)),
                           with: .color(cols[0].opacity(0.15 + 0.5 * level)), lineWidth: 1.2)
            }
        }
    }

    private func blob(center c: CGPoint, radius r: Double, time t: Double, wobble: Double, spin: Double) -> Path {
        var p = Path()
        let n = 72
        for i in 0...n {
            let th = Double(i) / Double(n) * 2 * .pi
            let d = 1
                + wobble * 0.55 * sin(3 * th + t * 1.9 + spin)
                + wobble * 0.30 * sin(5 * th - t * 2.7)
                + wobble * 0.15 * sin(7 * th + t * 3.4)
            let pt = CGPoint(x: c.x + cos(th) * r * d, y: c.y + sin(th) * r * d)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Rounded vertical bars (a VU meter that scrolls), centered vertically.
struct WaveBars: View {
    var mood: OrbMood
    var history: [Double]
    var time: Double
    var count = 18

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let samples = Array(history.suffix(count))
            for i in 0..<count {
                var v: Double
                switch mood {
                case .thinking:
                    v = 0.18 + 0.16 * (0.5 + 0.5 * sin(time * 5 - Double(i) * 0.55))
                case .idle, .error:
                    v = 0.08
                case .listening, .speaking:
                    let s = i < samples.count ? samples[i] : 0
                    // Taper toward the edges so it reads as a shape, not a bar chart.
                    let x = Double(i) / Double(count - 1) * 2 - 1
                    let taper = 0.55 + 0.45 * cos(x * .pi / 2)
                    v = 0.08 + s * 0.92 * taper
                }
                let h = max(w, size.height * CGFloat(min(1, v)))
                let rect = CGRect(x: CGFloat(i) * (w + gap), y: (size.height - h) / 2, width: w, height: h)
                let color: Color = {
                    switch mood {
                    case .listening: return .white
                    case .speaking: return mood.colors[0]
                    case .thinking: return mood.colors[0].opacity(0.85)
                    default: return .white.opacity(0.35)
                    }
                }()
                ctx.fill(Path(roundedRect: rect, cornerRadius: w / 2), with: .color(color))
            }
        }
    }
}
