import AppKit
import DaisyCore
import Observation
import SwiftUI

/// The chosen accent and the palette worked out from it. Views read colors through `HUD`, which
/// reads this, so Observation redraws exactly the views that use a color when the accent changes.
@Observable final class ThemeStore {
    static let shared = ThemeStore()
    private static let key = "themeAccent"

    private(set) var accent: RGB
    private(set) var palette: ThemePalette
    @ObservationIgnored private var iconUpdate: Task<Void, Never>?

    private init() {
        let saved = UserDefaults.standard.string(forKey: Self.key).flatMap(RGB.init(hex:))
        accent = saved ?? ThemePalette.defaultAccent
        palette = ThemePalette.derived(from: saved ?? ThemePalette.defaultAccent)
    }

    func set(_ color: RGB) {
        guard color != accent else { return }
        accent = color
        palette = ThemePalette.derived(from: color)
        UserDefaults.standard.set(color.hex, forKey: Self.key)
        scheduleDockIcon()
    }
    func reset() { set(ThemePalette.defaultAccent) }

    /// The Dock shows the icon in the current accent while the app runs. Redrawn after the picker
    /// settles rather than on every drag step.
    func scheduleDockIcon(delay: Duration = .milliseconds(250)) {
        iconUpdate?.cancel()
        let palette = palette
        iconUpdate = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let data = AppIconArt.png(palette: palette, size: 512) else { return }
            NSApp.applicationIconImage = NSImage(data: data)
        }
    }
}

extension Color {
    init(_ rgb: RGB) { self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// Palette and type for the HUD. Near-black ground tinted by the accent, the accent itself, gold
/// only for decisions, pink only for stop and delete (both move if the accent sits too close).
enum HUD {
    private static var palette: ThemePalette { ThemeStore.shared.palette }
    static var void: Color { Color(palette.void) }
    static var deep: Color { Color(palette.deep) }
    static var panel: Color { Color(palette.panel) }
    static var line: Color { Color(palette.line) }
    static var accent: Color { Color(palette.accent) }
    static var ember: Color { Color(palette.ember) }
    static var thinking: Color { Color(palette.thinking) }
    static var ice: Color { Color(palette.ice) }
    static var steel: Color { Color(palette.steel) }
    static var dim: Color { Color(palette.dim) }
    static var amber: Color { Color(palette.approval) }
    static var crimson: Color { Color(palette.danger) }

    /// Small tracked caps for readouts and field labels.
    static func label(_ size: CGFloat = 9) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    /// Numbers and live values.
    static func readout(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .monospaced) }
    static let wordmark = Font.system(size: 13, weight: .bold, design: .monospaced)
    static let title = Font.system(size: 22, weight: .semibold)
}

/// Window ground: a 28pt line grid, a faint glow in the middle, scanlines and a vignette.
struct HUDBackground: View {
    var body: some View {
        // Read here so the grid redraws when the accent changes; the Canvas closure alone isn't tracked.
        let ground = HUD.void, glow = HUD.accent, gridLine = HUD.line
        ZStack {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(rect), with: .color(ground))
                context.fill(Path(rect), with: .radialGradient(Gradient(colors: [glow.opacity(0.045), .clear]),
                                                               center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                               startRadius: 0, endRadius: max(size.width, size.height) * 0.62))
                var grid = Path()
                for x in stride(from: 0, through: size.width, by: 28) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: 28) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(grid, with: .color(gridLine.opacity(0.05)), lineWidth: 1)
                var scan = Path()
                for y in stride(from: 3, through: size.height, by: 4) { scan.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
                context.fill(scan, with: .color(.white.opacity(0.012)))
            }
            GeometryReader { geo in
                RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center,
                               startRadius: min(geo.size.width, geo.size.height) * 0.45,
                               endRadius: max(geo.size.width, geo.size.height) * 0.8)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Panel outline with the top-right and bottom-left corners cut off.
struct Chamfer: Shape {
    var cut: CGFloat = 12
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cut, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - cut))
        p.closeSubpath()
        return p
    }
}

/// L-shaped brackets on the top-left and bottom-right corners, the two that aren't cut.
struct CornerBrackets: Shape {
    var radius: CGFloat = 0
    var length: CGFloat = 12
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + length))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + length, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - length, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - length))
        return p
    }
}

/// Flat gradient plate with a cut outline and lit brackets.
struct HUDPanel: ViewModifier {
    var radius: CGFloat = 14
    var tint: Color = HUD.accent
    var brackets = true
    func body(content: Content) -> some View {
        content
            .background(LinearGradient(colors: [HUD.panel.opacity(0.65), HUD.deep.opacity(0.9)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Chamfer())
            .overlay { Chamfer().stroke(tint.opacity(0.28), lineWidth: 1) }
            .overlay { if brackets { CornerBrackets().stroke(tint, lineWidth: 2) } }
    }
}

extension View {
    func hudPanel(radius: CGFloat = 14, tint: Color = HUD.accent, brackets: Bool = true) -> some View {
        modifier(HUDPanel(radius: radius, tint: tint, brackets: brackets))
    }
    /// Section caption: small tracked caps.
    func hudCaption(_ color: Color = HUD.dim) -> some View {
        font(HUD.label(10)).tracking(1.6).foregroundStyle(color)
    }
}

/// Buttons: primary is lit red, critical is amber (approve, send), danger is pink (stop,
/// delete), ghost is an outline for everything else. Square, monospace caps.
struct HUDButtonStyle: ButtonStyle {
    enum Kind { case primary, critical, danger, ghost }
    var kind: Kind = .ghost
    var compact = false
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
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
        let color: Color = kind == .critical ? HUD.amber : kind == .danger ? HUD.crimson : HUD.accent
        let filled = kind != .ghost
        configuration.label
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .monospaced))
            .tracking(1.1).textCase(.uppercase)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minHeight: compact ? 26 : 32)
            .foregroundStyle(filled ? HUD.void : color)
            .background(Rectangle().fill(filled ? color.opacity(hovering ? 1 : 0.9) : color.opacity(hovering ? 0.14 : 0.04)))
            .overlay(Rectangle().strokeBorder(color.opacity(filled ? 0 : (hovering ? 0.7 : 0.35)), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
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
            .background(Rectangle().fill(HUD.void.opacity(0.7)))
            .overlay(Rectangle().strokeBorder(HUD.line.opacity(0.2), lineWidth: 1))
    }
}

/// The always-listening switch: a lit track when the microphone is open for "Hey Daisy".
struct HUDSwitch: View {
    let title: String
    let isOn: Bool
    var detail: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(HUD.label(10)).tracking(1.6).foregroundStyle(isOn ? HUD.accent : HUD.steel)
                    Text(detail ?? (isOn ? "ON" : "OFF")).font(.system(size: 10)).foregroundStyle(HUD.dim)
                }
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? HUD.accent.opacity(0.85) : Color.white.opacity(0.08))
                        .overlay(Capsule().strokeBorder(isOn ? .clear : HUD.dim.opacity(hovering ? 0.8 : 0.5), lineWidth: 1))
                        .frame(width: 34, height: 19)
                    Circle().fill(isOn ? HUD.void : HUD.dim).frame(width: 13, height: 13).padding(3)
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

/// A square dot and a caption, for link and microphone state in the top bar.
struct StatusPill: View {
    let text: String
    let color: Color
    var lit = true
    var body: some View {
        HStack(spacing: 7) {
            Rectangle().fill(color).frame(width: 6, height: 6)
            Text(text).font(HUD.label(10)).tracking(1.5).foregroundStyle(lit ? color : HUD.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Rectangle().fill(color.opacity(lit ? 0.05 : 0.02)))
        .overlay(Rectangle().strokeBorder(color.opacity(lit ? 0.3 : 0.15), lineWidth: 1))
    }
}

/// A live input level, drawn as a row of bars.
struct LevelBars: View {
    let level: Double
    var bars = 12
    var color: Color = HUD.accent
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                let lit = Double(index) / Double(bars) < level
                Rectangle().fill(lit ? color : color.opacity(0.15))
                    .frame(width: 3, height: 5 + CGFloat(index % 4) * 2)
            }
        }
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
