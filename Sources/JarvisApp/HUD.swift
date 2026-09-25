import SwiftUI

let accent = Color(red: 0.36, green: 0.88, blue: 0.90)
let warning = Color(red: 0.94, green: 0.68, blue: 0.27)
let danger = Color(red: 0.88, green: 0.27, blue: 0.24)
let hudBackground = Color(red: 0.024, green: 0.043, blue: 0.071)
let surface = Color(red: 0.040, green: 0.067, blue: 0.098)
let surfaceHigh = Color(red: 0.067, green: 0.118, blue: 0.157)
let ink = Color(red: 0.86, green: 0.90, blue: 0.925)
let muted = Color(red: 0.49, green: 0.58, blue: 0.63)
let hairline = accent.opacity(0.2)

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

/// Short L-shaped brackets on the top-left and bottom-right corners.
struct CornerBrackets: Shape {
    var size: CGFloat = 12
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + size))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + size, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - size, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - size))
        return p
    }
}

extension View {
    func hudPanel(_ tint: Color = accent, padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [surfaceHigh.opacity(0.65), surface.opacity(0.9)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Chamfer())
            .overlay(Chamfer().stroke(tint.opacity(0.28), lineWidth: 1))
            .overlay(CornerBrackets().stroke(tint, lineWidth: 2))
    }
    func microLabel(_ color: Color = muted, size: CGFloat = 10) -> some View {
        self.font(.system(size: size, weight: .medium, design: .monospaced))
            .tracking(size * 0.16).textCase(.uppercase).foregroundStyle(color)
    }
}

/// Kicker line plus page title, used at the top of every workspace page.
struct PageHeader<Trailing: View>: View {
    let kicker: String
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kicker).microLabel(accent)
                Text(title).font(.system(size: 24, weight: .semibold))
            }
            Spacer()
            trailing
        }
    }
}
extension PageHeader where Trailing == EmptyView {
    init(kicker: String, title: String) { self.init(kicker: kicker, title: title) { EmptyView() } }
}

struct HUDButtonStyle: ButtonStyle {
    var tint: Color = accent
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).textCase(.uppercase)
            .padding(.horizontal, 12).frame(height: 30)
            .foregroundStyle(filled ? hudBackground : tint)
            .background(filled ? tint.opacity(configuration.isPressed ? 0.8 : 1) : tint.opacity(configuration.isPressed ? 0.14 : 0.04))
            .overlay(Rectangle().stroke(tint.opacity(filled ? 0 : 0.35)))
            .contentShape(Rectangle())
    }
}

/// Grid, center glow and scanlines behind everything.
struct HUDBackdrop: View {
    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(hudBackground))
            ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [accent.opacity(0.045), .clear]),
                                                       center: CGPoint(x: size.width / 2, y: size.height / 2),
                                                       startRadius: 0, endRadius: max(size.width, size.height) * 0.62))
            var grid = Path()
            for x in stride(from: 0, through: size.width, by: 28) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: 0, through: size.height, by: 28) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
            ctx.stroke(grid, with: .color(accent.opacity(0.05)), lineWidth: 1)
            var scan = Path()
            for y in stride(from: 3, through: size.height, by: 4) { scan.addRect(CGRect(x: 0, y: y, width: size.width, height: 1)) }
            ctx.fill(scan, with: .color(.white.opacity(0.012)))
        }
        .ignoresSafeArea()
    }
}

struct Vignette: View {
    var body: some View {
        GeometryReader { geo in
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center,
                           startRadius: min(geo.size.width, geo.size.height) * 0.45,
                           endRadius: max(geo.size.width, geo.size.height) * 0.8)
        }
        .allowsHitTesting(false).ignoresSafeArea()
    }
}
