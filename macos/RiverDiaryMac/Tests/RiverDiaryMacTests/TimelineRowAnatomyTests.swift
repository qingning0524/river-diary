import SwiftUI
import XCTest

@testable import RiverDiaryMac

/// 行本身的两条回归线：**脊柱看得见**，**选中和悬停不是一回事**。
///
/// 这两件事都只在像素里成立。2026-09 之前，脊柱用 `accent@0.30`（浅色 1.37:1）、
/// 选中用 `ink@0.055`、悬停用 `ink@0.025`，设计文档写着"连续脊柱""选中态"，
/// 屏幕上是三条几乎看不见的灰。所以这里量的是对比度，不是"有没有画"。
@MainActor
final class TimelineRowAnatomyTests: XCTestCase {

    // MARK: Harness

    private struct Harness: View {
        let items: [ActivityTimelineItem]
        var selectedItemID: String?
        var expandedRunIDs: Set<String> = []
        @FocusState private var focus: String?

        var body: some View {
            RiverTimelineView(
                items: items,
                nowSession: nil,
                selectedItemID: selectedItemID,
                onSelect: { _, _ in },
                onWriteNote: {},
                inspectorSourceFocusID: $focus,
                isScrollable: false,
                expandedRunIDs: expandedRunIDs
            )
            .frame(width: 600)
            .background(Color.white)
        }
    }

    private static let scale: CGFloat = 2
    private static let width: CGFloat = 600

    /// 节点轴：列宽是固定的（时间列 54 + 脊柱列一半 13），加上行内左内边距。
    /// `TimelineRenderingTests.testSpineIsCentredOnTheNodes` 负责保证它真的落在节点上。
    private static var nodeAxisX: Int {
        Int((AppSpacing.sm + TimelineRowMetrics.timeColumn + TimelineRowMetrics.spineColumn / 2) * scale)
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

    private func pixel(_ image: (pixels: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, luma: Int) {
        let i = (y * image.width + x) * 4
        let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
        return (r, g, b, (299 * r + 587 * g + 114 * b) / 1000)
    }

    private func isNearWhite(_ p: (r: Int, g: Int, b: Int, luma: Int)) -> Bool {
        p.r > 250 && p.g > 250 && p.b > 250
    }

    /// WCAG 相对亮度对比度。
    private static func contrast(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Double {
        func linear(_ channel: Int) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func luminance(_ p: (r: Int, g: Int, b: Int)) -> Double {
            0.2126 * linear(p.r) + 0.7152 * linear(p.g) + 0.0722 * linear(p.b)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func day(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    private func activity(_ id: String, _ hour: Int, _ minute: Int, _ minutes: Int, app: String = "Xcode") -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: id, kind: .activity,
            start: day(hour, minute), end: day(hour, minute).addingTimeInterval(TimeInterval(minutes * 60)),
            sessions: [ActivitySession(
                appName: app, bundleID: "test.\(app)", windowTitle: "\(app) window",
                category: "工作", start: day(hour, minute),
                end: day(hour, minute).addingTimeInterval(TimeInterval(minutes * 60))
            )]
        )
    }

    private func makeItems() -> [ActivityTimelineItem] {
        [activity("a", 9, 15, 40), activity("b", 10, 5, 85, app: "Safari"), activity("c", 13, 0, 80)]
    }

    /// 六段一分钟的切屏，隔四分钟一次：会被折叠成一条碎片带。
    private func fragmentRun() -> ActivityTimelineItem {
        let members = (0..<6).map { index in
            activity("fragment-\(index)", 9, index * 4, 1, app: index % 2 == 0 ? "Xcode" : "Chrome")
        }
        let items = members
        let folded = ActivityTimelineEngine.foldFragments(items)
        XCTAssertEqual(folded.count, 1, "六段一分钟的切屏应该折成一条碎片带")
        XCTAssertTrue(folded[0].isFragmentRun)
        return folded[0]
    }

    // MARK: 脊柱

    func testSpineIsDrawnStronglyEnoughToRead() throws {
        let image = try render(Harness(items: makeItems()))
        let axis = Self.nodeAxisX

        // 节点轴上出现最多的颜色就是脊柱本身：节点（18px 高）和它的描边都只是少数行。
        var counts: [Int: Int] = [:]
        for y in 0..<image.height {
            let p = pixel(image, axis, y)
            guard !isNearWhite(p) else { continue }
            counts[p.r << 16 | p.g << 8 | p.b, default: 0] += 1
        }
        let dominant = try XCTUnwrap(counts.max(by: { $0.value < $1.value })?.key, "节点轴上什么都没画")
        let spine = (r: (dominant >> 16) & 0xFF, g: (dominant >> 8) & 0xFF, b: dominant & 0xFF)

        XCTAssertGreaterThanOrEqual(
            spine.b, spine.r + 30,
            "脊柱不是 accent 系：rgb(\(spine.r),\(spine.g),\(spine.b))"
        )
        let ratio = Self.contrast(spine, (255, 255, 255))
        XCTAssertGreaterThanOrEqual(
            ratio, 2.2,
            String(format: "脊柱只有 %.2f:1（rgb(%d,%d,%d)），旧值 accent@0.30 是 1.37:1——看不见的线不算线", ratio, spine.r, spine.g, spine.b)
        )
        XCTAssertLessThan(
            ratio, Self.contrast((62, 116, 220), (255, 255, 255)),
            "脊柱不能和实心节点一样重，否则节点不再是节点"
        )
    }

    /// 碎片带的节点是"环 + 芯"：正中有实心 accent，往外一圈是空的。
    /// 这样它既不是活动（全实心），也不是空档（全空心的中性环）。
    func testFragmentRunNodeIsARingWithACore() throws {
        let run = fragmentRun()
        let image = try render(Harness(items: [run]))
        let centre = (x: Self.nodeAxisX, y: Int((TimelineRowMetrics.topInset - 1 + 4.5) * Self.scale))

        // 节点：9pt 的圆，`strokeBorder` 1.4pt 描边（画在圆内侧），中间一枚 3.5pt 的实心点。
        // 换算到 scale 2 的像素半径：芯 3.5px，环带 6.2–9.0px，中间 3.5–6.2px 是空的。
        let core = pixel(image, centre.x, centre.y)
        XCTAssertGreaterThanOrEqual(core.b, core.r + 30, "碎片带节点的芯应该是 accent")

        let between = pixel(image, centre.x + 5, centre.y)
        XCTAssertTrue(
            isNearWhite(between),
            "环与芯之间是满的（rgb(\(between.r),\(between.g),\(between.b))）——碎片带看起来和一个实心活动节点一样"
        )

        let ring = pixel(image, centre.x + 7, centre.y)
        XCTAssertFalse(isNearWhite(ring), "碎片带节点没有描边环")
        XCTAssertGreaterThan(ring.b - ring.r, 10, "环应该是 accent 系，而不是中性灰")
    }

    // MARK: 选中 vs 悬停

    func testSelectedRowCarriesItsOwnSurface() throws {
        let items = makeItems()
        let idle = try render(Harness(items: items))
        let selected = try render(Harness(items: items, selectedItemID: items[0].id))
        // 行内空白处：x=300pt（标题与时长列之间），y=30pt（第一行的下半部分）。
        let probe = (x: 600, y: 60)

        let idlePixel = pixel(idle, probe.x, probe.y)
        XCTAssertTrue(isNearWhite(idlePixel), "没选中也没悬停的行应该是干净的面板底色")

        let selectedPixel = pixel(selected, probe.x, probe.y)
        let delta = max(
            abs(selectedPixel.r - idlePixel.r),
            max(abs(selectedPixel.g - idlePixel.g), abs(selectedPixel.b - idlePixel.b))
        )
        XCTAssertGreaterThanOrEqual(
            delta, 8,
            "选中和未选中只差 \(delta) 个色阶：鼠标扫过和点下去长得一样"
        )
        XCTAssertGreaterThan(
            selectedPixel.b - selectedPixel.r, 0,
            "选中底应该偏蓝（accentSoft），而不是一格中性灰"
        )
    }

    /// 详情箭头只在悬停或选中时出现：每一行常亮一个箭头是纯噪音，行本身已经可以点。
    /// 碎片带是例外——它是个容器，折叠状态必须看得见。
    func testDetailChevronOnlyAppearsOnTheSelectedRow() throws {
        let items = makeItems()
        let band = controlBand(rowTop: 0, rowBottom: 100)
        let idle = try render(Harness(items: items))
        let selected = try render(Harness(items: items, selectedItemID: items[0].id))

        XCTAssertEqual(
            darkPixels(idle, band), 0,
            "没选中也没悬停的行画了箭头：行列表右侧会出现一列常亮的箭头"
        )
        XCTAssertGreaterThanOrEqual(
            darkPixels(selected, band), 6,
            "选中的行应该出现详情箭头"
        )
    }

    func testFragmentRunShowsItsDisclosureWithoutHover() throws {
        let run = fragmentRun()
        let image = try render(Harness(items: [run]))
        XCTAssertGreaterThanOrEqual(
            darkPixels(image, controlBand(rowTop: 0, rowBottom: 100)), 6,
            "碎片带必须常显展开箭头：它是个容器，折叠状态不能靠鼠标扫过才知道"
        )
    }

    /// 尾列 x 范围 + 某一行的高度范围。尾列宽度固定，所以时长列在所有行上右端对齐。
    private func controlBand(rowTop: Int, rowBottom: Int) -> (x: Range<Int>, y: Range<Int>) {
        let width = Int(Self.width * Self.scale)
        let column = Int(TimelineRowMetrics.controlColumn * Self.scale)
        return ((width - column)..<width, rowTop..<rowBottom)
    }

    private func darkPixels(
        _ image: (pixels: [UInt8], width: Int, height: Int),
        _ band: (x: Range<Int>, y: Range<Int>)
    ) -> Int {
        var count = 0
        for x in band.x {
            for y in band.y where y < image.height {
                if pixel(image, x, y).luma < 190 { count += 1 }
            }
        }
        return count
    }
}

// MARK: - 可整理的证据

/// 检查器上的"编辑"只对真实的活动块有意义：只有它带标注键。空档、快记和
/// 碎片带都给不出键，写进去的标注永远读不回来——按钮按下去既不保存也不报错，
/// 是那种要用户自己发现"我刚才写的字去哪了"的死路。
final class TimelineAnnotatableTests: XCTestCase {

    private func day(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    private func session(hour: Int, minute: Int, minutes: Int) -> ActivitySession {
        let start = day(hour, minute)
        return ActivitySession(
            appName: "Xcode", bundleID: "test.Xcode", windowTitle: nil,
            category: "工作", start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    func testOnlyRealActivityBlocksCanBeAnnotated() {
        let capture = QuickCapture(text: "写下的一句话", createdAt: day(12, 0))
        let timeline = ActivityTimelineEngine.build(
            for: day(9, 0),
            sessions: [
                session(hour: 9, minute: 0, minutes: 30),
                // 一分钟一段，间隔四分钟：拆得开（前一段结束到下一段开始 > 120s），
                // 而且每一段都够短（跨度 <3 分钟）。
                session(hour: 9, minute: 40, minutes: 1),
                session(hour: 9, minute: 44, minutes: 1),
                session(hour: 9, minute: 48, minutes: 1),
                session(hour: 9, minute: 52, minutes: 1)
            ],
            captures: [capture]
        )

        guard let block = timeline.items.first(where: { $0.kind == .activity && !$0.isFragmentRun && $0.span >= 180 }) else {
            return XCTFail("没有一条够长的活动块：\(timeline.items.map(\.kind))")
        }
        XCTAssertTrue(block.isAnnotatable, "真实的活动块必须可以整理")

        let gap = timeline.items.first { $0.kind == .gap }
        XCTAssertNotNil(gap, "隔着十分钟的两段工作之间应该有空档")
        XCTAssertFalse(gap?.isAnnotatable ?? true, "空档没有原始记录，标注无处可存")

        let note = timeline.items.first { $0.kind == .capture }
        XCTAssertNotNil(note)
        XCTAssertFalse(note?.isAnnotatable ?? true, "快记是用户自己写的字，不需要再整理一次")

        guard let run = timeline.foldedItems.first(where: \.isFragmentRun) else {
            return XCTFail("四段一分钟的切屏应该被折成一条碎片带")
        }
        XCTAssertFalse(run.isAnnotatable, "碎片带是展示层的聚合，只有它的成员各自带键")
        XCTAssertTrue(run.fragments.allSatisfy(\.isAnnotatable), "展开后的每一段都应该能单独整理")
    }
}

// MARK: - 展示列表

/// 折叠/展开与"时间带拖到哪里"都落在 `TimelineDisplayList` 上：它是页面和
/// 列表共用的那一份。这两条规则出错的话，症状是"展开处脊柱断了"和
/// "拖到 14:20 却跳到别的时间"。
final class TimelineDisplayListTests: XCTestCase {

    private func day(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date)!
    }

    private func activity(_ id: String, _ hour: Int, _ minute: Int, _ minutes: Int) -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: id, kind: .activity,
            start: day(hour, minute), end: day(hour, minute).addingTimeInterval(TimeInterval(minutes * 60)),
            sessions: [ActivitySession(
                appName: "Xcode", bundleID: "test.Xcode", windowTitle: "Xcode window",
                category: "工作", start: day(hour, minute),
                end: day(hour, minute).addingTimeInterval(TimeInterval(minutes * 60))
            )]
        )
    }

    private func gap(_ id: String, _ from: (Int, Int), _ to: (Int, Int)) -> ActivityTimelineItem {
        ActivityTimelineItem(id: id, kind: .gap, start: day(from.0, from.1), end: day(to.0, to.1))
    }

    /// 一条碎片带 + 后面一条普通行。
    private func runAndTail() -> (run: ActivityTimelineItem, tail: ActivityTimelineItem) {
        let members = (0..<5).map { index in activity("f\(index)", 12, index * 3, 1) }
        let tail = activity("tail", 13, 30, 40)
        let folded = ActivityTimelineEngine.foldFragments(members + [tail])
        XCTAssertEqual(folded.count, 2)
        XCTAssertTrue(folded[0].isFragmentRun)
        return (folded[0], folded[1])
    }

    func testCollapsedRunIsOneRowAndTheLastOneIsTrimmedAtTheEnd() {
        let (run, tail) = runAndTail()
        let rows = TimelineDisplayList.rows(items: [run, tail], expandedRunIDs: [], hasNowRow: false)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].isFirst)
        XCTAssertFalse(rows[0].isLast, "后面还有一条证据")
        XCTAssertTrue(rows[1].isLast)
    }

    func testExpandedRunInsertsItsMembersAndKeepsTheSpineGoing() {
        let (run, tail) = runAndTail()
        let rows = TimelineDisplayList.rows(items: [run, tail], expandedRunIDs: [run.id], hasNowRow: false)

        XCTAssertEqual(rows.count, 2 + run.fragments.count)
        XCTAssertFalse(rows[0].isLast, "展开之后碎片带的下半截脊柱必须继续画，否则展开处是个洞")
        XCTAssertEqual(
            Array(rows[1...run.fragments.count]).map(\.item.id),
            run.fragments.map(\.id),
            "展开出来的顺序必须和折叠进去的顺序一致"
        )
        for child in rows[1...run.fragments.count] {
            XCTAssertTrue(child.isChild)
            XCTAssertFalse(child.isFirst)
            XCTAssertFalse(child.isLast)
        }
        XCTAssertTrue(rows.last!.isLast)
        XCTAssertFalse(rows.last!.isChild)
    }

    /// 只有一条碎片带、没有别的行时，展开它之后最后一行是它的最后一段成员。
    func testExpandingTheOnlyRunMovesTheSpineEndToItsLastMember() {
        let (run, _) = runAndTail()
        let collapsed = TimelineDisplayList.rows(items: [run], expandedRunIDs: [], hasNowRow: false)
        XCTAssertEqual(collapsed.count, 1)
        XCTAssertTrue(collapsed[0].isLast)

        let expanded = TimelineDisplayList.rows(items: [run], expandedRunIDs: [run.id], hasNowRow: false)
        XCTAssertFalse(expanded[0].isLast)
        XCTAssertTrue(expanded.last!.isLast)
        XCTAssertTrue(expanded.last!.isChild)
    }

    /// 子行的 id 不能和顶层的 id 撞上：撞上会让 `scrollTo` 跳到错误的行。
    func testChildRowIdentifiersCannotCollideWithTopLevelRows() {
        let (run, tail) = runAndTail()
        let rows = TimelineDisplayList.rows(items: [run, tail], expandedRunIDs: [run.id], hasNowRow: false)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "展示行 id 有重复")
        XCTAssertEqual(rows[0].id, run.id, "碎片带自己的 id 就是滚动目标")
    }

    /// "正在记录"那一行也要参与脊柱收尾：它后面不需要再画线。
    func testNowRowTrimsTheSpineAtTheLastEvidenceRow() {
        let (run, tail) = runAndTail()
        let rows = TimelineDisplayList.rows(items: [run, tail], expandedRunIDs: [], hasNowRow: true)
        XCTAssertFalse(rows[1].isLast)
    }

    // MARK: 拖动定位

    func testScrubLandsOnTheRowThatCoversTheMoment() {
        let run = TimelineDisplayList.rows(
            items: [gap("g", (9, 0), (9, 30)), activity("a", 9, 40, 40)],
            expandedRunIDs: [],
            hasNowRow: false
        )
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(9, 10), rows: run)?.rowID, "g")
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(9, 50), rows: run)?.rowID, "a")
    }

    /// 一段折叠的碎片带：拖到它中间，页面要认出"这一刻在这条碎片带里"，并且知道
    /// 应该先把这条带展开。
    func testScrubOnAFoldedRunAsksForItToBeExpanded() {
        let (run, tail) = runAndTail()
        let rows = TimelineDisplayList.rows(items: [run, tail], expandedRunIDs: [], hasNowRow: false)
        let target = TimelineDisplayList.scrubTarget(for: day(12, 4), rows: rows)
        XCTAssertEqual(target?.rowID, run.id)
        XCTAssertEqual(target?.expandsRunID, run.id, "落在碎片带上时必须先展开它")

        let onTail = TimelineDisplayList.scrubTarget(for: day(13, 40), rows: rows)
        XCTAssertEqual(onTail?.rowID, tail.id)
        XCTAssertNil(onTail?.expandsRunID, "普通行不需要展开")
    }

    /// 一天里最早和最晚的空白处：拖着时间带走，总得落在某条证据上，
    /// "这里什么都没有"不是一个可定位的位置。
    func testScrubFallsBackToTheNearestRow() {
        let rows = TimelineDisplayList.rows(
            items: [activity("a", 9, 0, 30), activity("b", 11, 0, 30)],
            expandedRunIDs: [],
            hasNowRow: false
        )
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(0, 30), rows: rows)?.rowID, "a")
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(23, 0), rows: rows)?.rowID, "b")
        // 两行之间的小缝：取更近的那一条。
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(10, 44), rows: rows)?.rowID, "b")
        XCTAssertEqual(TimelineDisplayList.scrubTarget(for: day(9, 46), rows: rows)?.rowID, "a")
    }

    func testScrubOnAnEmptyDayDoesNothing() {
        XCTAssertNil(TimelineDisplayList.scrubTarget(for: day(12, 0), rows: []))
    }
}
