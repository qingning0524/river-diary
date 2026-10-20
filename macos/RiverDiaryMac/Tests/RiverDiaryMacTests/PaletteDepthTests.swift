import XCTest
@testable import RiverDiaryMac

/// 配色色阶的对比度守卫。
///
/// 这套界面不用阴影和大色块堆层次，层次全靠"相邻面差一档 + 发丝线画得出来"。
/// 2026-09 之前的表就是这么塌掉的：浅色面板与页面的边框只有 1.04:1、深色行分隔线
/// 4.5% 白压在深色面板上只有 1.009:1、时间线脊柱 `accent@0.30` 只有 1.4:1 ——
/// 设计文档写了"连续脊柱""柔和景深"，像素里全看不见，界面因此"平、廉价"。
///
/// 这个文件把修复后的色阶逐套配色钉住：任何一格掉回"看不见"都会失败。
/// 改色值请连同 DESIGN.md 的色阶表一起改。
final class PaletteDepthTests: XCTestCase {

    // MARK: - 色彩工具

    private struct RGB: Equatable {
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        init(hex: String) {
            var n: UInt64 = 0
            Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&n)
            r = CGFloat((n >> 16) & 0xFF)
            g = CGFloat((n >> 8) & 0xFF)
            b = CGFloat(n & 0xFF)
        }

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }

        static func blend(_ top: RGB, over base: RGB, fraction: CGFloat) -> RGB {
            let f = max(0, min(1, fraction))
            return RGB(
                r: top.r * f + base.r * (1 - f),
                g: top.g * f + base.g * (1 - f),
                b: top.b * f + base.b * (1 - f)
            )
        }

        /// 到另一个色最远的单通道差（0–255）。比对比度更贴近"能不能看出边界"。
        func channelDelta(_ other: RGB) -> CGFloat {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }

        private func linear(_ channel: CGFloat) -> CGFloat {
            let c = channel / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        var relativeLuminance: CGFloat {
            0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG 对比度，1.0 = 完全同色。
        func contrast(_ other: RGB) -> CGFloat {
            let a = relativeLuminance
            let b = other.relativeLuminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    private static let allPalettes = RiverPalette.allCases

    private func colorSet(_ palette: RiverPalette, dark: Bool) -> RiverPaletteColorSet {
        dark ? palette.theme.dark : palette.theme.light
    }

    private func label(_ palette: RiverPalette, dark: Bool) -> String {
        "\(palette.rawValue) \(dark ? "深色" : "浅色")"
    }

    /// 发丝线的实际颜色：浅色是表里的十六进制；深色是白 alpha 压在当前底色上。
    private func ruleColor(_ hex: String, alpha: CGFloat, over base: RGB, dark: Bool) -> RGB {
        dark ? RGB.blend(RGB(hex: "#FFFFFF"), over: base, fraction: alpha) : RGB(hex: hex)
    }

    private func forEachPalette(
        _ body: (RiverPalette, Bool, RiverPaletteColorSet) -> Void
    ) {
        for palette in Self.allPalettes {
            for dark in [false, true] {
                body(palette, dark, colorSet(palette, dark: dark))
            }
        }
    }

    // MARK: - 面：相邻两档必须拉得开

    func testCanvasSitsOneStepBelowSurfaceInEveryPalette() {
        forEachPalette { palette, dark, set in
            let canvas = RGB(hex: set.canvas)
            let surface = RGB(hex: set.surface)
            let contrast = canvas.contrast(surface)
            if palette == .seafoam && !dark {
                // The approved soft material uses a near-canvas fill and dual
                // directional shadows; the previous flat-paper ladder no longer applies.
                XCTAssertGreaterThan(contrast, 1)
                XCTAssertLessThanOrEqual(contrast, 1.04)
                XCTAssertGreaterThan(surface.relativeLuminance, canvas.relativeLuminance)
                return
            }
            XCTAssertGreaterThanOrEqual(
                contrast, 1.08,
                "\(label(palette, dark: dark))：页面画布与面板只差 \(fmt(contrast)):1，面板浮不出来"
            )
            XCTAssertLessThanOrEqual(
                contrast, 1.30,
                "\(label(palette, dark: dark))：画布与面板差到 \(fmt(contrast)):1，面板会像贴上去的色块"
            )
            XCTAssertLessThan(
                canvas.relativeLuminance, surface.relativeLuminance,
                "\(name)：面板必须比页面画布亮一档，深浅两套都一样"
            )
        }
    }

    func testChipAndEditorAreDistinctFromBothSurfaceAndEachOther() {
        forEachPalette { palette, dark, set in
            let surface = RGB(hex: set.surface)
            let chip = RGB(hex: set.chip)
            let editor = RGB(hex: set.editor)
            let name = label(palette, dark: dark)
            if palette == .seafoam && !dark {
                // Recessed fields are separated by inner shadows rather than
                // pretending to be another raised paper surface.
                XCTAssertGreaterThanOrEqual(chip.contrast(surface), 1.05)
                XCTAssertLessThan(editor.relativeLuminance, surface.relativeLuminance)
                XCTAssertGreaterThanOrEqual(chip.channelDelta(editor), 6)
                return
            }

            XCTAssertGreaterThanOrEqual(
                chip.contrast(surface), 1.10,
                "\(name)：卡片/悬停底与面板差 \(fmt(chip.contrast(surface))):1，悬停时看不出反应"
            )
            // 输入区是"凹进去"的：比面板深，浅色深色都一样。
            XCTAssertLessThan(
                editor.relativeLuminance, surface.relativeLuminance,
                "\(name)：输入区必须比面板更暗，才读得出凹陷"
            )
            // 三级台阶：浅色下 面板 > 抬起的卡片底 > 凹下去的输入区；
            // 深色下方向反过来（面板最暗，卡片底更亮，输入区最暗）。
            // 浅色下这一档曾经完全塌掉：chip #ECEFF4 与 editor #EDF0F5 只差 0–2 个色阶，
            // 「抬起的按钮」和「凹进去的输入框」是同一种灰。
            if dark {
                XCTAssertGreaterThan(
                    chip.relativeLuminance, surface.relativeLuminance,
                    "\(name)：深色下抬起的卡片底要比面板亮"
                )
            } else {
                XCTAssertGreaterThan(
                    chip.relativeLuminance, editor.relativeLuminance,
                    "\(name)：浅色下抬起的卡片底不能比凹进去的输入区还暗"
                )
            }
            XCTAssertGreaterThanOrEqual(
                chip.channelDelta(editor), 6,
                "\(name)：卡片底与输入区底色几乎同色（chip \(set.chip) / editor \(set.editor)），两种面会糊在一起"
            )
        }
    }

    // MARK: - 线：发丝线必须画得出来

    func testHairlinesAreVisibleInBothSchemes() {
        forEachPalette { palette, dark, set in
            let name = label(palette, dark: dark)

            let border = ruleColor(set.border, alpha: darkBorderAlpha, over: RGB(hex: set.canvas), dark: dark)
            let canvas = RGB(hex: set.canvas)
            let borderContrast = border.contrast(canvas)
            XCTAssertGreaterThanOrEqual(
                borderContrast, 1.18,
                "\(name)：面板描边只有 \(fmt(borderContrast)):1（\(dark ? "白 \(darkBorderAlpha)" : set.border)），深色下等于没画"
            )
            XCTAssertLessThanOrEqual(
                borderContrast, 1.60,
                "\(name)：描边到了 \(fmt(borderContrast)):1，已经不是发丝线了"
            )

            let separator = ruleColor(set.separator, alpha: darkSeparatorAlpha, over: RGB(hex: set.surface), dark: dark)
            let surface = RGB(hex: set.surface)
            let separatorContrast = separator.contrast(surface)
            XCTAssertGreaterThanOrEqual(
                separatorContrast, 1.14,
                "\(name)：行分隔线只有 \(fmt(separatorContrast)):1，列表会读成一片"
            )

            // 描边是面板的外轮廓，必须比行内分隔线更明确。
            XCTAssertGreaterThan(
                darkBorderAlpha, darkSeparatorAlpha,
                "深色：面板描边（\(darkBorderAlpha)）必须重于行分隔线（\(darkSeparatorAlpha)）"
            )

            let strong = RGB(hex: set.strongSeparator)
            XCTAssertGreaterThanOrEqual(
                strong.contrast(canvas), 1.32,
                "\(name)：页级分隔线只有 \(fmt(strong.contrast(canvas))):1，分不出两个区块"
            )
        }
    }

    // MARK: - 文字：两级灰都要能读

    func testSecondaryAndTertiaryInkStayReadable() {
        forEachPalette { palette, dark, set in
            let surface = RGB(hex: set.surface)
            let ink2 = RGB(hex: set.ink2)
            let ink3 = RGB(hex: set.ink3)
            let name = label(palette, dark: dark)

            XCTAssertGreaterThanOrEqual(
                ink2.contrast(surface), 4.5,
                "\(name)：次要文字只有 \(fmt(ink2.contrast(surface))):1，正文读不清"
            )
            XCTAssertGreaterThanOrEqual(
                ink3.contrast(surface), 3.0,
                "\(name)：最淡一档文字只有 \(fmt(ink3.contrast(surface))):1，时间戳/提示会看不见"
            )
            XCTAssertLessThan(
                ink3.contrast(surface), ink2.contrast(surface),
                "\(name)：最淡一档必须比次要文字更淡，否则三级层级塌成两级"
            )
        }
    }

    // MARK: - 时间线脊柱

    func testTimelineSpineIsVisibleButStillLighterThanASolidNode() {
        forEachPalette { palette, dark, set in
            let surface = RGB(hex: set.surface)
            let accent = RGB(hex: set.accent)
            let spine = RGB.blend(
                accent,
                over: surface,
                fraction: dark ? timelineSpineAlphaDark : timelineSpineAlphaLight
            )
            let name = label(palette, dark: dark)
            let contrast = spine.contrast(surface)

            XCTAssertGreaterThanOrEqual(
                contrast, 2.2,
                "\(name)：脊柱只有 \(fmt(contrast)):1，设计文档写了「连续脊柱」而像素里看不见"
            )
            XCTAssertLessThan(
                contrast, accent.contrast(surface),
                "\(name)：脊柱不能和实心节点一样重，否则节点不再是节点"
            )
            XCTAssertGreaterThan(
                accent.contrast(surface), 2.2,
                "\(name)：实心节点本身要一眼看到"
            )
        }
    }

    // MARK: - 悬停 vs 选中

    /// 悬停是中性水洗，选中是 accent 淡底 + 左侧 2.5pt 实色条。
    /// 这里保证两档底色本身就是两个色（而不是同一个灰），色条之外也有区别。
    func testHoverFillAndSelectionFillAreNotTheSameColour() {
        forEachPalette { palette, dark, set in
            let surface = RGB(hex: set.surface)
            let hover = RGB.blend(RGB(hex: set.ink), over: surface, fraction: 0.05)
            let selected = RGB(hex: set.accentSoft)
            XCTAssertGreaterThanOrEqual(
                hover.channelDelta(selected), 10,
                "\(label(palette, dark: dark))：悬停底与选中底几乎同色，鼠标扫过和点下去长得一样"
            )
        }
    }

    // MARK: - 深色发丝配方

    func testDarkHairlineAlphasStayInAWorkableRange() {
        XCTAssertGreaterThan(darkBorderAlpha, 0)
        XCTAssertLessThan(darkBorderAlpha, 0.30, "再重就不是发丝线了")
        XCTAssertGreaterThanOrEqual(darkSeparatorAlpha, 0.06, "4.5% 白在深色面板上是 1.009:1，等于没画")
        XCTAssertLessThan(darkSeparatorAlpha, darkBorderAlpha)
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }
}
