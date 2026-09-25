import SwiftUI
import XCTest

@testable import RiverDiaryMac

/// 日带的布局守卫。
///
/// 起因是实机截图：时间线页的日带与"今天"面板之间出现 **260pt 的纯画布空白**。
/// 根因是刻度区的 `GeometryReader` 只给了 `frame(minHeight: 12)`——`GeometryReader`
/// 在两个方向上都是贪心的，只给下限等于不设上限。日带躺在会滚动的面板里时，
/// ScrollView 用"理想高度"提案，贪心看不出来；钉进页头之后，窗口把真实高度提案给
/// 页头，刻度区把提案整个吃掉，把页面从日带下面推出去两百多 pt。
///
/// 这两条测试把"日带是一个**固定高度**的部件"钉死：谁再把它放进无界提案的环境，
/// 或者把刻度区改回 `minHeight`，都会在这里失败。
@MainActor
final class TimelineRibbonTests: XCTestCase {

    private static let scale: CGFloat = 2

    private func day(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    private var ribbonItems: [ActivityTimelineItem] {
        [
            ActivityTimelineItem(
                id: "a", kind: .activity, start: day(1, 10), end: day(1, 40),
                sessions: [ActivitySession(
                    appName: "Chrome", bundleID: "test.Chrome", windowTitle: nil,
                    category: "浏览", start: day(1, 10), end: day(1, 40)
                )]
            ),
            ActivityTimelineItem(
                id: "b", kind: .activity, start: day(7, 0), end: day(7, 30),
                sessions: [ActivitySession(
                    appName: "Xcode", bundleID: "test.Xcode", windowTitle: nil,
                    category: "工作", start: day(7, 0), end: day(7, 30)
                )]
            )
        ]
    }

    /// 日带下面铺一块品红色标记：品红不在任何一套配色里，出现在哪一行，
    /// 日带就在哪里结束。
    private struct RibbonHost: View {
        let date: Date
        let items: [ActivityTimelineItem]

        var body: some View {
            VStack(spacing: 0) {
                RiverDayRibbon(date: date, items: items)
                Rectangle().fill(Self.magenta)
            }
            .frame(width: 600, height: 300)
            .background(Color.white)
        }

        static let magenta = Color(red: 1, green: 0, blue: 1)
    }

    /// 页头.compose：真实钉住的构成（页头 + 日带），下面同样铺品红标记。
    private struct HeaderBandHost: View {
        let date: Date
        let items: [ActivityTimelineItem]

        var body: some View {
            VStack(spacing: 0) {
                RiverHeaderBand {
                    PageHeader("时间线", context: nil) {}
                    RiverDayRibbon(date: date, items: items)
                }
                Rectangle().fill(RibbonHost.magenta)
            }
            .frame(width: 800, height: 500)
            .background(Color.white)
        }
    }

    private func render(_ view: some View) throws -> (pixels: [UInt8], width: Int, height: Int) {
        PaletteStore.currentID = RiverPalette.seafoam.rawValue
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (pixels, image.width, image.height)
    }

    /// 第一行"至少 60% 的像素都是品红"的 y。用占比而不是单像素，避免撞上
    /// 日带自己的抗锯齿边缘。
    private func firstSolidMagentaRow(_ image: (pixels: [UInt8], width: Int, height: Int)) throws -> Int {
        for y in 0..<image.height {
            var hits = 0
            var total = 0
            for x in stride(from: 40, to: image.width - 40, by: 4) {
                let i = (y * image.width + x) * 4
                let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
                total += 1
                if r > 200, b > 200, g < 80 { hits += 1 }
            }
            if Double(hits) / Double(total) > 0.6 { return y }
        }
        return image.height
    }

    func testTheRibbonIsAFixedHeightComponent() throws {
        let image = try render(RibbonHost(date: day(9, 0), items: ribbonItems))
        let ribbonHeightPT = Double(try firstSolidMagentaRow(image)) / Double(Self.scale)

        XCTAssertGreaterThanOrEqual(
            ribbonHeightPT, RiverDayRibbon.trackHeight + RiverDayRibbon.axisHeight - 2,
            "日带比轨道加刻度还矮：刻度区没画出来"
        )
        XCTAssertLessThanOrEqual(
            ribbonHeightPT, RiverDayRibbon.trackHeight + RiverDayRibbon.axisHeight + 12,
            String(format: "日带占了 %.0fpt（应为 %.0fpt）：它在吞掉给它的所有高度", ribbonHeightPT, RiverDayRibbon.trackHeight + RiverDayRibbon.axisHeight)
        )
    }

    func testThePinnedHeaderLeavesThePageAlone() throws {
        let image = try render(HeaderBandHost(date: day(9, 0), items: ribbonItems))
        let bandHeightPT = Double(try firstSolidMagentaRow(image)) / Double(Self.scale)

        // 页头应该由内容决定高度（标题 + 日带 + 上下留白，约 150pt）。
        // 贪心的刻度区在这里会把它撑到几百 pt，把正文推出窗口。
        XCTAssertLessThanOrEqual(
            bandHeightPT, 220,
            String(format: "钉住的页头占了 %.0fpt：日带在无界提案里抢高度，正文被推出窗口", bandHeightPT)
        )
    }

    /// 刻度标签要真的画出来：一条看不见的刻度轴等于没有刻度。
    func testHourLabelsAreDrawnUnderTheTrack() throws {
        let image = try render(RibbonHost(date: day(9, 0), items: ribbonItems))
        // 刻度区在轨道（42pt）之下、品红之上：在这个带状区域里找 tertiaryInk 的深色字。
        let top = Int((RiverDayRibbon.trackHeight + 2) * Self.scale)
        let bottom = Int((RiverDayRibbon.trackHeight + RiverDayRibbon.axisHeight + 4) * Self.scale)
        var dark = 0
        for y in top..<min(bottom, image.height) {
            for x in stride(from: 40, to: image.width - 40, by: 2) {
                let i = (y * image.width + x) * 4
                let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
                if (299 * r + 587 * g + 114 * b) / 1000 < 190 { dark += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(dark, 20, "轨道下面没有刻度数字")
    }
}
