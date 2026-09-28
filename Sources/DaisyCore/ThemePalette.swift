import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An sRGB color with components in 0...1.
public struct RGB: Equatable, Codable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = min(1, max(0, r)); self.g = min(1, max(0, g)); self.b = min(1, max(0, b))
    }

    /// "#FA4242" or "fa4242". Nil for anything that isn't six hex digits.
    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Hue, saturation and brightness, each 0...1.
    public var hsb: (h: Double, s: Double, v: Double) {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        var h = 0.0
        if delta > 0 {
            if high == r { h = (g - b) / delta } else if high == g { h = (b - r) / delta + 2 } else { h = (r - g) / delta + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, high == 0 ? 0 : delta / high, high)
    }
    public init(h: Double, s: Double, v: Double) {
        let h = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = min(1, max(0, s)), v = min(1, max(0, v))
        let c = v * s, x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
        let (r, g, b): (Double, Double, Double)
        switch Int(h) {
        case 0: (r, g, b) = (c, x, 0)
        case 1: (r, g, b) = (x, c, 0)
        case 2: (r, g, b) = (0, c, x)
        case 3: (r, g, b) = (0, x, c)
        case 4: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        self.init(r + m, g + m, b + m)
    }

    public func mixed(with other: RGB, _ amount: Double) -> RGB {
        RGB(r + (other.r - r) * amount, g + (other.g - g) * amount, b + (other.b - b) * amount)
    }
}

/// Every HUD color, worked out from one accent. Grounds and text take the accent's hue at low
/// saturation; stop and delete use a hotter version of the accent itself; the decision color (gold) stays fixed unless the accent
/// sits close to them, in which case they move so they never blend in.
public struct ThemePalette: Equatable, Sendable {
    public var accent, line, ember, thinking: RGB
    public var void, deep, panel: RGB
    public var ice, steel, dim: RGB
    public var approval, danger: RGB

    /// The warm cream the app ships with, #FAEAB7.
    public static let defaultAccent = RGB(hex: "#FAEAB7")!
    public static let red = RGB(0.98, 0.26, 0.26)
    public static let presets: [(name: String, color: RGB)] = [
        ("Cream", defaultAccent), ("Red", red), ("Cyan", RGB(0.36, 0.88, 0.90)), ("Blue", RGB(0.33, 0.56, 1.0)),
        ("Violet", RGB(0.66, 0.45, 1.0)), ("Green", RGB(0.30, 0.90, 0.52)), ("Orange", RGB(1.0, 0.55, 0.18)),
        ("Gold", RGB(0.96, 0.78, 0.30)), ("White", RGB(0.90, 0.92, 0.95))
    ]

    public static let gold = RGB(0.96, 0.70, 0.28)

    public static func derived(from input: RGB) -> ThemePalette {
        var (h, s, v) = input.hsb
        // Dark accents disappear on a near-black ground, so lift them to a usable brightness.
        v = max(v, 0.6)
        let accent = RGB(h: h, s: s, v: v)
        let colorful = s > 0.25
        return ThemePalette(
            accent: accent,
            line: accent.mixed(with: RGB(1, 1, 1), 0.05),
            ember: RGB(h: h - 4.0 / 360, s: min(1, s * 1.13), v: v * 0.735),
            thinking: RGB(h: h + 17.0 / 360, s: s * 0.95, v: 1),
            void: RGB(h: h, s: s * 0.67, v: 0.047),
            deep: RGB(h: h, s: s * 0.75, v: 0.078),
            panel: RGB(h: h, s: s * 0.86, v: 0.15),
            ice: RGB(h: h, s: s * 0.072, v: 0.95),
            steel: RGB(h: h, s: s * 0.17, v: 0.80),
            dim: RGB(h: h, s: s * 0.31, v: 0.62),
            approval: colorful && hueDistance(h, gold.hsb.h) < 30.0 / 360 ? RGB(0.55, 0.62, 1.0) : gold,
            // Same hue as the accent, more saturated, so stop reads as urgent without a foreign color.
            danger: RGB(h: h, s: min(1, max(s * 1.6, s + 0.25)), v: min(1, v * 1.02)))
    }

    /// Shortest way around the hue circle, 0...0.5.
    public static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 1)
        return min(d, 1 - d)
    }
}

/// The app icon: an arc-reactor core on a dark rounded tile, in the palette's accent.
public enum AppIconArt {
    public static func png(palette: ThemePalette, size: Int = 1024) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        draw(ctx, palette: palette, space: space)
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static func draw(_ ctx: CGContext, palette p: ThemePalette, space: CGColorSpace) {
        func color(_ c: RGB, _ a: Double = 1) -> CGColor { CGColor(colorSpace: space, components: [c.r, c.g, c.b, a])! }
        func accent(_ a: Double) -> CGColor { color(p.accent, a) }
        // macOS icon grid: an 824pt tile centered in 1024.
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
        let c = CGPoint(x: 512, y: 512)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(RGB(0, 0, 0), 0.45))
        ctx.addPath(tilePath); ctx.setFillColor(color(p.void)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tilePath); ctx.clip()
        let top = RGB(h: p.panel.hsb.h, s: p.panel.hsb.s, v: 0.17), bottom = RGB(h: p.void.hsb.h, s: p.void.hsb.s, v: 0.04)
        let bg = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        // Faint HUD grid.
        ctx.setStrokeColor(accent(0.06)); ctx.setLineWidth(2)
        for v in stride(from: tile.minX, through: tile.maxX, by: 52) {
            ctx.move(to: CGPoint(x: v, y: tile.minY)); ctx.addLine(to: CGPoint(x: v, y: tile.maxY))
            ctx.move(to: CGPoint(x: tile.minX, y: v)); ctx.addLine(to: CGPoint(x: tile.maxX, y: v))
        }
        ctx.strokePath()
        let glow = CGGradient(colorsSpace: space, colors: [accent(0.28), accent(0.06), accent(0)] as CFArray, locations: [0, 0.45, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 400, options: [])

        // Reactor, drawn in the app's 240-unit orb space scaled to the tile.
        let s: CGFloat = 3.0
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s) }
        func point(_ r: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + cos(a) * r * s, y: c.y + sin(a) * r * s) }
        func reactor(_ boost: Double) {
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(accent(0.3 * boost)); ctx.setLineWidth(1.2 * s); ctx.strokeEllipse(in: circle(116))
            ctx.setStrokeColor(accent(0.6 * boost)); ctx.setLineWidth(1.4 * s)
            for i in 0..<24 {
                let a = CGFloat(i) * .pi / 12
                ctx.move(to: point(122, a)); ctx.addLine(to: point(i % 3 == 0 ? 110 : 115, a))
            }
            ctx.strokePath()
            ctx.setStrokeColor(accent(0.7 * boost)); ctx.setLineWidth(1.6 * s); ctx.setLineDash(phase: 0, lengths: [3 * s, 8 * s])
            ctx.strokeEllipse(in: circle(100)); ctx.setLineDash(phase: 0, lengths: [])
            ctx.setStrokeColor(accent(0.95 * boost)); ctx.setLineWidth(6 * s)
            for i in 0..<6 {
                let start = CGFloat(i) * .pi / 3 + 0.12
                ctx.addArc(center: c, radius: 84 * s, startAngle: start, endAngle: start + .pi / 3 - 0.3, clockwise: false)
                ctx.strokePath()
            }
            ctx.setStrokeColor(accent(0.85 * boost)); ctx.setLineWidth(2 * s); ctx.setLineJoin(.miter)
            for i in 0..<28 {
                let q = point(i % 2 == 0 ? 66 : 57, CGFloat(i) / 28 * 2 * .pi - .pi / 2)
                if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
            }
            ctx.closePath(); ctx.strokePath()
            ctx.setStrokeColor(accent(boost)); ctx.setLineWidth(3 * s); ctx.strokeEllipse(in: circle(38))
            ctx.setStrokeColor(accent(0.55 * boost)); ctx.setLineWidth(9 * s); ctx.strokeEllipse(in: circle(24))
        }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: accent(0.9))
        reactor(0.8)
        ctx.restoreGState()
        reactor(1)
        let hot = p.accent.mixed(with: RGB(1, 1, 1), 0.88)
        let core = CGGradient(colorsSpace: space, colors: [color(hot), accent(1), accent(0)] as CFArray, locations: [0, 0.35, 1])!
        ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16 * s, options: [])
        ctx.restoreGState()

        // Thin rim so the tile reads on light and dark docks.
        ctx.addPath(tilePath); ctx.setStrokeColor(accent(0.25)); ctx.setLineWidth(3); ctx.strokePath()
    }
}
