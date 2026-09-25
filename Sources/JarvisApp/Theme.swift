import SwiftUI

/// Palette and type for the HUD. Deep navy ground, cyan light, white text, amber and crimson
/// only where something needs a decision or can be stopped.
enum HUD {
    static let void = Color(red: 0.012, green: 0.027, blue: 0.059)
    static let deep = Color(red: 0.027, green: 0.063, blue: 0.122)
    static let panel = Color(red: 0.035, green: 0.090, blue: 0.170)
    static let line = Color(red: 0.55, green: 0.85, blue: 1.0)
    static let cyan = Color(red: 0.24, green: 0.89, blue: 1.0)
    static let blue = Color(red: 0.25, green: 0.50, blue: 0.98)
    static let ice = Color(red: 0.91, green: 0.96, blue: 1.0)
    static let steel = Color(red: 0.62, green: 0.74, blue: 0.84)
    static let dim = Color(red: 0.45, green: 0.58, blue: 0.69)
    static let amber = Color(red: 1.0, green: 0.56, blue: 0.24)
    static let crimson = Color(red: 1.0, green: 0.27, blue: 0.38)

    /// Small tracked caps for readouts and field labels.
    static func label(_ size: CGFloat = 9) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    /// Numbers and live values.
    static func readout(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    static let wordmark = Font.system(size: 13, weight: .semibold).width(.expanded)
    static let title = Font.system(size: 20, weight: .semibold).width(.expanded)
}

/// Window ground: navy with two soft light sources and a faint dot grid.
struct HUDBackground: View {
    var body: some View {
        ZStack {
            HUD.void
            RadialGradient(colors: [HUD.blue.opacity(0.20), .clear], center: UnitPoint(x: 0.88, y: 1.0), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [HUD.cyan.opacity(0.09), .clear], center: UnitPoint(x: 0.18, y: 0.0), startRadius: 0, endRadius: 620)
            Canvas { context, size in
                let step: CGFloat = 26
                var dots = Path()
                var y = step / 2
                while y < size.height {
                    var x = step / 2
                    while x < size.width { dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)); x += step }
                    y += step
                }
                context.fill(dots, with: .color(HUD.line.opacity(0.07)))
            }
        }
        .ignoresSafeArea()
    }
}

/// Short strokes that hug a rounded rectangle's four corners.
struct CornerBrackets: Shape {
    var radius: CGFloat
    var length: CGFloat = 12
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = min(radius, min(rect.width, rect.height) / 2), l = length
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r + l, y: rect.minY))
        path.move(to: CGPoint(x: rect.maxX - r - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r + l))
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - r - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX - r - l, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + r + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r - l))
        return path
    }
}

/// Frosted glass over the window ground, a hairline edge, and lit corners.
struct HUDPanel: ViewModifier {
    var radius: CGFloat = 14
    var tint: Color = HUD.cyan
    var brackets = true
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(HUD.panel.opacity(0.62)))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [HUD.line.opacity(0.24), HUD.line.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .overlay {
                if brackets { CornerBrackets(radius: radius).stroke(tint.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round)) }
            }
    }
}

extension View {
    func hudPanel(radius: CGFloat = 14, tint: Color = HUD.cyan, brackets: Bool = true) -> some View {
        modifier(HUDPanel(radius: radius, tint: tint, brackets: brackets))
    }
    /// Section caption: small tracked caps.
    func hudCaption(_ color: Color = HUD.dim) -> some View {
        font(HUD.label(9)).tracking(1.6).foregroundStyle(color)
    }
}

/// Buttons: primary is lit cyan, critical is amber (approve, send), danger is crimson (stop,
/// delete), ghost is an outline for everything else.
struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, critical, danger, ghost }
    var kind: Kind = .ghost
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        HUDButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct HUDButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: HUDButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        let color: Color = kind == .critical ? HUD.amber : kind == .danger ? HUD.crimson : HUD.cyan
        let filled = kind != .ghost
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minHeight: compact ? 26 : 32)
            .foregroundStyle(filled ? HUD.void : color)
            .background(shape.fill(filled ? color.opacity(hovering ? 1 : 0.88) : color.opacity(hovering ? 0.16 : 0.07)))
            .overlay(shape.strokeBorder(color.opacity(filled ? 0 : (hovering ? 0.7 : 0.4)), lineWidth: 1))
            .shadow(color: filled ? color.opacity(hovering ? 0.55 : 0.3) : .clear, radius: hovering ? 12 : 7, y: 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(shape)
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

extension View {
    /// Text fields sit in a dark well with a hairline edge.
    func hudField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(HUD.ice)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.28)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
    }
}

/// The always-listening switch: a lit track when the microphone is open for "Hey Jarvis".
struct HUDSwitch: View {
    let title: String
    let isOn: Bool
    var detail: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? HUD.cyan.opacity(0.28) : Color.white.opacity(0.06))
                        .overlay(Capsule().strokeBorder(isOn ? HUD.cyan.opacity(0.8) : HUD.dim.opacity(hovering ? 0.8 : 0.5), lineWidth: 1))
                        .frame(width: 34, height: 19)
                    Circle().fill(isOn ? HUD.ice : HUD.dim).frame(width: 13, height: 13).padding(3)
                        .shadow(color: isOn ? HUD.cyan : .clear, radius: 6)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(HUD.label(8.5)).tracking(1.2).foregroundStyle(isOn ? HUD.ice : HUD.steel)
                    Text(detail ?? (isOn ? "ON" : "OFF")).font(HUD.label(8.5)).tracking(1.2).foregroundStyle(isOn ? HUD.cyan : HUD.dim)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isOn)
        .accessibilityLabel(title.capitalized)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A dot and a caption, for link and microphone state in the top bar.
struct StatusPill: View {
    let text: String
    let color: Color
    var lit = true
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6).shadow(color: lit ? color : .clear, radius: 4)
            Text(text).font(HUD.label(9)).tracking(1.3).foregroundStyle(lit ? HUD.ice.opacity(0.9) : HUD.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 11).frame(height: 26)
        .background(Capsule().fill(Color.black.opacity(0.25)))
        .overlay(Capsule().strokeBorder(color.opacity(lit ? 0.35 : 0.18), lineWidth: 1))
    }
}

/// A live input level, drawn as a row of bars.
struct LevelBars: View {
    let level: Double
    var bars = 12
    var color: Color = HUD.cyan
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let lit = Double(index) / Double(bars) < level
                RoundedRectangle(cornerRadius: 1).fill(lit ? color : color.opacity(0.15))
                    .frame(width: 3, height: 5 + CGFloat(index % 4) * 2)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
