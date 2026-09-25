import SwiftUI

/// Arc-reactor style orb. Drawn in a 240-unit space and scaled to fit.
/// Standby rotates slowly, listening pulses with the mic, work spins the arcs, speaking adds a radial waveform.
struct OrbView: View {
    @ObservedObject var audio: AudioController
    let phase: AssistantPhase
    var offline = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in draw(context: context, size: size, time: time) }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
    private var working: Bool { [.preparing, .thinking, .searching, .transcribing, .synthesizing].contains(phase) }
    private func draw(context: GraphicsContext, size: CGSize, time: Double) {
        let s = min(size.width, size.height) / 240
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let tint = offline ? warning : accent
        let level = phase == .listening || phase == .speaking ? min(1, audio.level) : 0
        let slow = working ? 2.4 : 18, fast = working ? 2.4 : 12
        let cw = time * 2 * .pi / slow, ccw = -time * 2 * .pi / fast
        let pulse = phase == .listening ? 0.5 + 0.5 * sin(time * 2 * .pi / 0.9) : 0
        let dim = phase == .idle && !offline ? 0.75 : 1.0

        func circle(_ r: Double) -> Path { Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s)) }
        func spun(_ p: Path, _ angle: Double) -> Path {
            p.applying(CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle).translatedBy(x: -c.x, y: -c.y))
        }
        func point(_ r: Double, _ a: Double) -> CGPoint { CGPoint(x: c.x + cos(a) * r * s, y: c.y + sin(a) * r * s) }
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
            ctx.opacity = dim
            let color = { (o: Double) in GraphicsContext.Shading.color(tint.opacity(o)) }
            ctx.stroke(circle(108), with: color(0.25), lineWidth: 0.6 * s)
            ctx.stroke(spun(circle(96), cw), with: color(0.55 + level * 0.3), style: StrokeStyle(lineWidth: 1 * s, dash: [2 * s, 9 * s]))
            ctx.stroke(spun(circle(81), ccw), with: color(0.78), style: StrokeStyle(lineWidth: 2 * s, dash: [40 * s, 12 * s, 8 * s, 18 * s]))
            ctx.stroke(spun(circle(66), cw), with: color(0.9), style: StrokeStyle(lineWidth: 0.8 * s, dash: [3 * s, 5 * s]))
            ctx.stroke(spun(gear, ccw), with: color(0.8), lineWidth: 1 * s)
            ctx.stroke(ticks, with: color(0.5), lineWidth: 1 * s)
            let core = 1 - 0.38 * pulse
            ctx.stroke(circle(35 * coreScale), with: color(core), lineWidth: 1.5 * s)
            ctx.stroke(circle(23 * coreScale), with: color(0.5 * core), lineWidth: 5 * s)
            ctx.fill(circle(8 + level * 4), with: color(0.9))
            if phase == .speaking {
                var wave = Path()
                for i in 0..<72 {
                    let a = Double(i) / 72 * 2 * .pi
                    let wobble = 0.5 + 0.5 * sin(time * 9 + Double(i) * 0.9) * sin(time * 3.1 + Double(i) * 0.37)
                    let length = 3 + 16 * max(level, 0.2) * wobble
                    wave.move(to: point(114, a)); wave.addLine(to: point(114 + length, a))
                }
                ctx.stroke(wave, with: color(0.7), lineWidth: 1 * s)
            }
        }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 2.5 * s))
            strokes(glow)
        }
        strokes(context)
    }
}
