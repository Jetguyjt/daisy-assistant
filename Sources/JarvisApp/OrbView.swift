import SwiftUI

/// What the core is showing. Colour and motion come from here, not from the phase directly.
enum OrbMood: Equatable {
    case idle, standby, listening, thinking, approval, speaking, offline
    var tint: Color {
        switch self {
        case .approval: return HUD.amber
        case .offline: return HUD.crimson
        case .thinking: return Color(red: 0.36, green: 0.72, blue: 1.0)
        default: return HUD.cyan
        }
    }
    /// Overall brightness, 0...1.
    var energy: Double {
        switch self {
        case .idle: return 0.58
        case .standby: return 0.78
        case .offline: return 0.4
        case .approval: return 0.85
        default: return 1
        }
    }
    /// Rotation speed multiplier for the rings.
    var speed: Double {
        switch self {
        case .offline: return 0.2
        case .idle, .approval: return 0.6
        case .standby: return 0.8
        case .thinking: return 2.6
        default: return 1.1
        }
    }
    var active: Bool { ![.idle, .offline].contains(self) }
    var hearsAudio: Bool { self == .listening || self == .speaking || self == .standby }
}

/// The reactor core: tick ring, counter-rotating arcs, a segment ring with a travelling
/// highlight, a sweep while working, and radial bars that follow the microphone or the voice.
struct OrbView: View {
    @ObservedObject var audio: AudioController
    let mood: OrbMood
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let rate = mood.active ? 30.0 : 20.0
        let slowed = activeState == .inactive ? min(rate, 12) : rate
        TimelineView(.animation(minimumInterval: 1 / slowed, paused: reduceMotion || !visible)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in draw(&context, size: size, time: time) }
        }
        .drawingGroup()
        .accessibilityHidden(true)
    }

    private func point(_ center: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
    private func arc(_ center: CGPoint, _ radius: Double, from start: Double, length: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(start + length), clockwise: false)
        return path
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let R = min(size.width, size.height) / 2 * 0.94
        guard R > 4 else { return }
        let tint = mood.tint
        let energy = mood.energy
        let speed = mood.speed
        let level = mood.hearsAudio ? min(1, audio.level) : 0
        let fine = R > 60

        // Light behind everything.
        context.fill(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)),
                     with: .radialGradient(Gradient(colors: [tint.opacity(0.26 * energy + level * 0.18), tint.opacity(0.05 * energy), .clear]),
                                           center: c, startRadius: 0, endRadius: R))

        // Outer hairline and tick ring.
        context.stroke(Path(ellipseIn: CGRect(x: c.x - R * 0.97, y: c.y - R * 0.97, width: R * 1.94, height: R * 1.94)),
                       with: .color(tint.opacity(0.2 * energy + 0.05)), lineWidth: 1)
        if fine {
            var ticks = Path()
            let count = 72
            let turn = -t * 0.05 * speed
            for index in 0..<count {
                let angle = turn + Double(index) / Double(count) * 2 * .pi
                let long = index % 6 == 0
                ticks.move(to: point(c, R * 0.90, angle))
                ticks.addLine(to: point(c, R * (long ? 0.84 : 0.87), angle))
            }
            context.stroke(ticks, with: .color(tint.opacity(0.18 + 0.25 * energy)), lineWidth: 1)
        }

        // Counter-rotating arcs.
        let a = t * 0.34 * speed, b = -t * 0.21 * speed
        let arcs: [(Double, Double, Double, Double)] = [
            (0.79, a, 1.25, 2.4), (0.79, a + .pi, 0.62, 2.4),
            (0.73, b + 0.8, 2.05, 1.4), (0.73, b + 3.9, 0.45, 1.4)
        ]
        for (index, (radius, start, length, width)) in arcs.enumerated() {
            // The inner pair runs in blue for depth, except when the whole core is signalling.
            let color = index >= 2 && (mood == .idle || mood == .standby || mood == .listening || mood == .speaking) ? HUD.blue : tint
            context.stroke(arc(c, R * radius, from: start, length: length),
                           with: .color(color.opacity(0.4 + 0.55 * energy)), style: StrokeStyle(lineWidth: width * max(0.6, R / 160), lineCap: .round))
        }

        // Sweep while working.
        if mood == .thinking {
            let head = t * 2.4
            let gradient = Gradient(stops: [.init(color: .clear, location: 0), .init(color: tint.opacity(0.9), location: 0.25), .init(color: .clear, location: 0.26)])
            context.stroke(Path(ellipseIn: CGRect(x: c.x - R * 0.67, y: c.y - R * 0.67, width: R * 1.34, height: R * 1.34)),
                           with: .conicGradient(gradient, center: c, angle: .radians(head)), lineWidth: max(2, R * 0.025))
        }

        // Segment ring with a highlight that travels around it.
        let segments = 30
        let gap = 0.05
        let wave = t * 1.3 * speed
        for index in 0..<segments {
            let start = Double(index) / Double(segments) * 2 * .pi
            let length = 2 * .pi / Double(segments) - gap
            let lit = pow(max(0, cos(start - wave)), 6)
            context.stroke(arc(c, R * 0.60, from: start, length: length),
                           with: .color(tint.opacity(0.12 + 0.2 * energy + 0.55 * lit * energy)), lineWidth: max(1.5, R * 0.035))
        }

        // Radial bars that follow the microphone or the voice.
        if level > 0.02 {
            var bars = Path()
            let count = fine ? 72 : 40
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * .pi
                let jitter = 0.35 + 0.65 * abs(sin(Double(index) * 1.73 + t * 7.5))
                let length = R * (0.02 + 0.12 * level * jitter)
                bars.move(to: point(c, R * 0.44, angle))
                bars.addLine(to: point(c, R * 0.44 + length, angle))
            }
            context.stroke(bars, with: .color(HUD.ice.opacity(0.35 + 0.5 * level)), style: StrokeStyle(lineWidth: max(1, R * 0.012), lineCap: .round))
        }

        // Core.
        let pulse = 1 + 0.03 * sin(t * 1.7) + level * 0.10
        let core = R * 0.30 * pulse
        context.fill(Path(ellipseIn: CGRect(x: c.x - core, y: c.y - core, width: core * 2, height: core * 2)),
                     with: .radialGradient(Gradient(stops: [
                        .init(color: HUD.ice.opacity(0.55 + 0.4 * energy), location: 0),
                        .init(color: tint.opacity(0.85 * energy + 0.1), location: 0.42),
                        .init(color: tint.opacity(0.22 * energy), location: 0.8),
                        .init(color: .clear, location: 1)
                     ]), center: c, startRadius: 0, endRadius: core))
        context.stroke(Path(ellipseIn: CGRect(x: c.x - core * 1.2, y: c.y - core * 1.2, width: core * 2.4, height: core * 2.4)),
                       with: .color(tint.opacity(0.25 + 0.4 * energy)), lineWidth: 1.2)
        if fine {
            context.stroke(Path(ellipseIn: CGRect(x: c.x - core * 0.62, y: c.y - core * 0.62, width: core * 1.24, height: core * 1.24)),
                           with: .color(HUD.ice.opacity(0.5 * energy)), lineWidth: 1)
        }
    }
}
