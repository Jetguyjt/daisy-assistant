import SwiftUI

struct OrbView: View {
    @ObservedObject var audio: AudioController
    let phase: AssistantPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in draw(context: &context, size: size, time: time) }
        }
        .accessibilityLabel("Jarvis is \(phase.rawValue.lowercased())")
        .accessibilityHidden(true)
    }
    private func draw(context: inout GraphicsContext, size: CGSize, time: Double) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.29
                let active = phase == .listening || phase == .speaking
                let energy = active ? audio.level : (phase == .thinking || phase == .transcribing ? 0.3 : 0.06)
                let tint = phase == .listening ? Color.mint : Color.cyan
                let glow = CGRect(x: center.x - radius * 1.6, y: center.y - radius * 1.6, width: radius * 3.2, height: radius * 3.2)
                context.fill(Path(ellipseIn: glow), with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.17 + energy * 0.1), .blue.opacity(0.04), .clear]),
                    center: center, startRadius: 0, endRadius: radius * 1.6))
                let body = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: body), with: .radialGradient(Gradient(colors: [Color(red: 0.015, green: 0.10, blue: 0.17), Color(red: 0.01, green: 0.03, blue: 0.07)]), center: center, startRadius: 0, endRadius: radius))
                for ring in 0..<22 {
                    var path = Path()
                    let fraction = Double(ring) / 21
                    for point in 0...128 {
                        let angle = Double(point) / 128 * .pi * 2
                        let slowWave: Double = sin(angle * 3 + time * 0.7 + fraction * 4) * 0.07
                        let fastWave: Double = cos(angle * 5 - time * 0.55 + fraction * 3) * (0.025 + energy * 0.065)
                        let audioWave: Double = sin(angle * 2 - time * 0.8) * energy * 0.05
                        let wave = slowWave + fastWave + audioWave
                        let r = radius * (0.57 + fraction * 0.43 + wave)
                        let p = CGPoint(x: center.x + cos(angle) * r,
                                        y: center.y + sin(angle) * r * (0.90 + sin(time * 0.4 + fraction * 2) * 0.05))
                        if point == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                    let color = ring % 5 == 0 ? Color(red: 0.31, green: 0.48, blue: 1) : tint
                    context.stroke(path, with: .color(color.opacity(0.12 + fraction * 0.5)), lineWidth: ring % 4 == 0 ? 1.5 : 0.6)
                }
                for particle in 0..<36 {
                    let seed = Double(particle)
                    let angle = seed * 2.39996 + time * 0.08
                    let r = radius * (1.17 + 0.15 * sin(seed * 7 + time * 0.3))
                    let dot = CGRect(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r, width: particle % 4 == 0 ? 2 : 1, height: particle % 4 == 0 ? 2 : 1)
                    context.fill(Path(ellipseIn: dot), with: .color(tint.opacity(0.18 + 0.3 * abs(sin(seed + time * 0.5)))))
                }
    }
}
