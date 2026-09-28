import SwiftUI

/// What the core is showing. Colour and motion come from here, not from the phase directly.
enum OrbMood: Equatable {
    case idle, standby, listening, thinking, approval, speaking, offline
    var tint: Color {
        switch self {
        case .approval: return HUD.amber
        case .offline: return HUD.crimson
        case .thinking: return HUD.thinking
        default: return HUD.accent
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

/// Arc-reactor core, drawn in a 240-unit space and scaled to fit: tick ring, dashed and segmented
/// rings that rotate with the mood, a gear, a pulsing core, a sweep while working, and radial bars
/// that follow the microphone or the voice.
struct OrbView: View {
    @ObservedObject var audio: AudioController
    let mood: OrbMood
    var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let rate = mood.active ? 30.0 : 20.0
        let slowed = activeState == .inactive ? min(rate, 12) : rate
        // Touch the palette so an accent change redraws the core even while its animation is paused.
        let _ = HUD.accent
        TimelineView(.animation(minimumInterval: 1 / slowed, paused: reduceMotion || !visible)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in draw(context, size: size, time: time) }
        }
        .accessibilityHidden(true)
    }

    private func draw(_ context: GraphicsContext, size: CGSize, time t: Double) {
        let s = min(size.width, size.height) / 240
        guard s > 0.05 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let tint = mood.tint
        let energy = mood.energy
        let level = mood.hearsAudio ? min(1, audio.level) : 0
        let fine = s > 0.4
        let cw = t * 2 * .pi / 18 * mood.speed, ccw = -t * 2 * .pi / 12 * mood.speed
        let pulse = mood == .listening ? 0.5 + 0.5 * sin(t * 2 * .pi / 0.9) : 0

        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)) }
        func point(_ r: Double, _ a: Double) -> CGPoint { CGPoint(x: c.x + cos(a) * r * s, y: c.y + sin(a) * r * s) }
        func spun(_ p: Path, _ angle: Double) -> Path {
            p.applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y))
        }
        var gear = Path()
        for i in 0..<28 {
            let p = point(i % 2 == 0 ? 63 : 54, Double(i) / 28 * 2 * .pi - .pi / 2)
            if i == 0 { gear.move(to: p) } else { gear.addLine(to: p) }
        }
        gear.closeSubpath()
        var ticks = Path()
        for i in 0..<24 {
            let a = Double(i) * .pi / 12
            ticks.move(to: point(112, a)); ticks.addLine(to: point(i % 3 == 0 ? 103 : 107, a))
        }
        let coreScale = 1 - 0.04 * pulse + 0.12 * level

        func strokes(_ ctx: GraphicsContext) {
            var ctx = ctx
            ctx.opacity = 0.45 + 0.55 * energy
            let color = { (o: Double) in GraphicsContext.Shading.color(tint.opacity(o)) }
            ctx.stroke(circle(108), with: color(0.25), lineWidth: 0.6 * s)
            if fine { ctx.stroke(ticks, with: color(0.5), lineWidth: 1 * s) }
            ctx.stroke(spun(circle(96), cw), with: color(0.55 + level * 0.3), style: StrokeStyle(lineWidth: 1 * s, dash: [2 * s, 9 * s]))
            ctx.stroke(spun(circle(81), ccw), with: color(0.8), style: StrokeStyle(lineWidth: 2 * s, dash: [40 * s, 12 * s, 8 * s, 18 * s]))
            ctx.stroke(spun(circle(66), cw), with: color(0.9), style: StrokeStyle(lineWidth: 0.8 * s, dash: [3 * s, 5 * s]))
            ctx.stroke(spun(gear, ccw), with: color(0.8), lineWidth: 1 * s)
            let core = 1 - 0.38 * pulse
            ctx.stroke(circle(35 * coreScale), with: color(core), lineWidth: 1.5 * s)
            ctx.stroke(circle(23 * coreScale), with: color(0.5 * core), lineWidth: 5 * s)
            ctx.fill(circle(8 + level * 4), with: color(0.9))
            if mood == .thinking {
                let gradient = Gradient(stops: [.init(color: .clear, location: 0), .init(color: tint.opacity(0.9), location: 0.25), .init(color: .clear, location: 0.26)])
                ctx.stroke(circle(74), with: .conicGradient(gradient, center: c, angle: .radians(t * 2.4)), lineWidth: 2 * s)
            }
            if level > 0.02 {
                var bars = Path()
                let count = fine ? 72 : 40
                for i in 0..<count {
                    let a = Double(i) / Double(count) * 2 * .pi
                    let wobble = 0.35 + 0.65 * abs(sin(Double(i) * 1.73 + t * 7.5))
                    bars.move(to: point(114, a)); bars.addLine(to: point(114 + 3 + 16 * level * wobble, a))
                }
                ctx.stroke(bars, with: color(0.7), lineWidth: 1 * s)
            }
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.5 * s))
            strokes(glow)
        }
        strokes(context)
    }
}
