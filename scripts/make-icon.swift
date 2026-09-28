// Draws the app icon (red arc-reactor orb on a dark tile) as a 1024px PNG.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
let red = (r: CGFloat(0.98), g: CGFloat(0.26), b: CGFloat(0.26))
func accent(_ a: CGFloat) -> CGColor { rgb(red.r, red.g, red.b, a) }

// macOS icon grid: 824pt tile centered in 1024 with a continuous-corner radius.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
let c = CGPoint(x: 512, y: 512)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.047, 0.024, 0.028)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.17, 0.06, 0.07), rgb(0.04, 0.02, 0.025)] as CFArray, locations: [0, 1])!
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
func drawReactor(boost: CGFloat) {
    ctx.setLineCap(.butt)
    ctx.setStrokeColor(accent(0.3 * boost)); ctx.setLineWidth(1.2 * s); ctx.strokeEllipse(in: circle(116))
    // Tick marks.
    ctx.setStrokeColor(accent(0.6 * boost)); ctx.setLineWidth(1.4 * s)
    for i in 0..<24 {
        let a = CGFloat(i) * .pi / 12
        ctx.move(to: point(122, a)); ctx.addLine(to: point(i % 3 == 0 ? 110 : 115, a))
    }
    ctx.strokePath()
    ctx.setStrokeColor(accent(0.7 * boost)); ctx.setLineWidth(1.6 * s); ctx.setLineDash(phase: 0, lengths: [3 * s, 8 * s])
    ctx.strokeEllipse(in: circle(100)); ctx.setLineDash(phase: 0, lengths: [])
    // Segmented arc ring.
    ctx.setStrokeColor(accent(0.95 * boost)); ctx.setLineWidth(6 * s)
    for i in 0..<6 {
        let start = CGFloat(i) * .pi / 3 + 0.12
        ctx.addArc(center: c, radius: 84 * s, startAngle: start, endAngle: start + .pi / 3 - 0.3, clockwise: false)
        ctx.strokePath()
    }
    // Gear.
    ctx.setStrokeColor(accent(0.85 * boost)); ctx.setLineWidth(2 * s); ctx.setLineJoin(.miter)
    for i in 0..<28 {
        let p = point(i % 2 == 0 ? 66 : 57, CGFloat(i) / 28 * 2 * .pi - .pi / 2)
        if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
    }
    ctx.closePath(); ctx.strokePath()
    // Core.
    ctx.setStrokeColor(accent(boost)); ctx.setLineWidth(3 * s); ctx.strokeEllipse(in: circle(38))
    ctx.setStrokeColor(accent(0.55 * boost)); ctx.setLineWidth(9 * s); ctx.strokeEllipse(in: circle(24))
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: accent(0.9))
drawReactor(boost: 0.8)
ctx.restoreGState()
drawReactor(boost: 1)
let core = CGGradient(colorsSpace: space, colors: [rgb(1, 0.93, 0.9), accent(1), accent(0)] as CFArray, locations: [0, 0.35, 1])!
ctx.drawRadialGradient(core, startCenter: c, startRadius: 0, endCenter: c, endRadius: 16 * s, options: [])
ctx.restoreGState()

// Thin rim so the tile reads on light and dark docks.
ctx.addPath(tilePath); ctx.setStrokeColor(accent(0.25)); ctx.setLineWidth(3); ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
