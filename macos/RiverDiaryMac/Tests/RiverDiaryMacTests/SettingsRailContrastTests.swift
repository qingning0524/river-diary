import XCTest
@testable import RiverDiaryMac

/// 左栏底色的区分度：逐套配色 × 明暗，验证左栏与内容画布确实分得开。
final class SettingsRailContrastTests: XCTestCase {

    private func rgb(_ hex: String) -> [CGFloat] {
        let v = hex.replacingOccurrences(of: "#", with: "")
        var n: UInt64 = 0
        Scanner(string: v).scanHexInt64(&n)
        return [CGFloat((n >> 16) & 0xFF), CGFloat((n >> 8) & 0xFF), CGFloat(n & 0xFF)]
    }

    private func railHex(for palette: RiverPalette, dark: Bool) -> String {
        let set = dark ? palette.theme.dark : palette.theme.light
        guard let blended = blendHex(
            NSColor(hex: set.ink),
            overHex: NSColor(hex: set.sidebar),
            fraction: settingsRailBlendAmount
        ), let srgb = blended.usingColorSpace(.sRGB) else {
            return set.sidebar
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(srgb.redComponent * 255)),
            Int(round(srgb.greenComponent * 255)),
            Int(round(srgb.blueComponent * 255))
        )
    }

    func testRailIsDistinctFromCanvasInEveryPalette() {
        for palette in RiverPalette.allCases {
            for dark in [false, true] {
                let set = dark ? palette.theme.dark : palette.theme.light
                let rail = rgb(railHex(for: palette, dark: dark))
                let canvas = rgb(set.canvas)
                let delta = zip(rail, canvas).map { abs($0 - $1) }.max() ?? 0
                XCTAssertGreaterThanOrEqual(
                    delta, 8,
                    "\(palette.rawValue) \(dark ? "深色" : "浅色")：左栏与画布只差 \(Int(delta)) 个色阶，两栏会糊成一片"
                )
            }
        }
    }

    func testRailStepsAwayFromCanvasInTheSameDirection() {
        // 左栏必须"离开"画布而不是和画布同色系微调：
        // 浅色下更亮、深色下更亮（内容画布是最深/最亮的那一档，左栏是它的相邻面）。
        for palette in RiverPalette.allCases {
            for dark in [false, true] {
                let set = dark ? palette.theme.dark : palette.theme.light
                let rail = rgb(railHex(for: palette, dark: dark))
                let canvas = rgb(set.canvas)
                let railLum = rail[0] * 0.299 + rail[1] * 0.587 + rail[2] * 0.114
                let canvasLum = canvas[0] * 0.299 + canvas[1] * 0.587 + canvas[2] * 0.114
                XCTAssertNotEqual(
                    Int(railLum), Int(canvasLum),
                    "\(palette.rawValue)：左栏与画布亮度相同"
                )
            }
        }
    }
}
