import Foundation
import DaisyCore

final class ThemeTests {
    private func close(_ a: RGB, _ b: RGB, within tolerance: Double = 0.03) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    func testDefaultIsCream() {
        expectEqual(ThemePalette.defaultAccent.hex, "#FAEAB7")
        let p = ThemePalette.derived(from: ThemePalette.defaultAccent)
        expectEqual(p.accent.hex, "#FAEAB7")
        // Cream sits next to the gold approval color, so approvals move to violet to stay distinct.
        expectFalse(p.approval == ThemePalette.gold)
        expectEqual(p.danger, ThemePalette.pink)
    }

    func testRedPresetMatchesTheEarlierTheme() {
        let p = ThemePalette.derived(from: ThemePalette.red)
        expectTrue(close(p.accent, RGB(0.98, 0.26, 0.26)))
        expectTrue(close(p.void, RGB(0.047, 0.024, 0.028)))
        expectTrue(close(p.panel, RGB(0.150, 0.055, 0.066)))
        expectTrue(close(p.ice, RGB(0.95, 0.90, 0.90)))
        expectTrue(close(p.dim, RGB(0.62, 0.48, 0.49)))
        expectTrue(close(p.thinking, RGB(1.0, 0.50, 0.30), within: 0.08))
        expectEqual(p.approval, ThemePalette.gold)
        expectEqual(p.danger, ThemePalette.pink)
    }

    func testHexRoundTripsAndRejectsJunk() throws {
        let color = try unwrap(RGB(hex: "#FA4242"))
        expectEqual(color.hex, "#FA4242")
        try expectEqual(try unwrap(RGB(hex: "fa4242")), color)
        expectTrue(RGB(hex: "#FA42") == nil)
        expectTrue(RGB(hex: "zzzzzz") == nil)
    }

    func testHSBRoundTrips() {
        for color in ThemePalette.presets.map(\.color) {
            let (h, s, v) = color.hsb
            expectTrue(close(RGB(h: h, s: s, v: v), color, within: 0.005))
        }
    }

    func testDecisionAndDangerColorsMoveAwayFromTheAccent() {
        let gold = ThemePalette.derived(from: RGB(0.96, 0.72, 0.25))
        expectFalse(gold.approval == ThemePalette.gold)
        let pink = ThemePalette.derived(from: RGB(0.98, 0.30, 0.62))
        expectFalse(pink.danger == ThemePalette.pink)
        let cyan = ThemePalette.derived(from: RGB(0.36, 0.88, 0.90))
        expectEqual(cyan.approval, ThemePalette.gold)
        expectEqual(cyan.danger, ThemePalette.pink)
    }

    func testDarkAccentsAreLiftedAndGroundsStayDark() {
        let p = ThemePalette.derived(from: RGB(0.1, 0.0, 0.2))
        expectTrue(p.accent.hsb.v >= 0.6 - 0.001)
        expectTrue(p.void.hsb.v < 0.06)
        expectTrue(p.panel.hsb.v < 0.2)
    }

    func testIconRendersAPNG() throws {
        let data = try unwrap(AppIconArt.png(palette: .derived(from: RGB(0.3, 0.9, 0.5)), size: 64))
        expectEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}
