import SwiftUI
import XCTest

@testable import RiverDiaryMac

/// Renders the timeline offscreen and asserts on the resulting pixels.
///
/// The rows share one continuous spine, and that continuity depends on layout
/// behaviour (a background adopting the row's measured height, rows abutting with
/// no vertical padding) that is easy to break without noticing. A pure
/// view-hierarchy assertion cannot catch it, so this renders the view and inspects
/// the bitmap.
@MainActor
final class TimelineRenderingTests: XCTestCase {

    // MARK: Harness

    private struct Harness: View {
        let items: [ActivityTimelineItem]
        var density: RiverDensity = .standard
        @FocusState private var focus: String?

        var body: some View {
            RiverTimelineView(
                items: items,
                nowSession: nil,
                selectedItemID: nil,
                onSelect: { _, _ in },
                onWriteNote: {},
                inspectorSourceFocusID: $focus,
                isScrollable: false
            )
            .environment(\.riverDensity, density)
            .frame(width: 600)
            .background(Color.white)
        }
    }

    private static let canvasWidth: CGFloat = 600
    private static let scale: CGFloat = 2
    private func makeItems() -> [ActivityTimelineItem] {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        func session(_ start: Date, _ minutes: Int, app: String, category: String) -> ActivitySession {
            ActivitySession(
                appName: app,
                bundleID: "test.\(app)",
                windowTitle: "\(app) window",
                category: category,
                start: start,
                end: start.addingTimeInterval(TimeInterval(minutes * 60))
            )
        }
        return [
            ActivityTimelineItem(
                id: "a",
                kind: .activity,
                start: at(9, 15),
                end: at(9, 55),
                sessions: [session(at(9, 15), 40, app: "Xcode", category: "工作")]
            ),
            ActivityTimelineItem(
                id: "b",
                kind: .activity,
                start: at(10, 5),
                end: at(11, 30),
                sessions: [session(at(10, 5), 85, app: "Safari", category: "浏览")]
            ),
            ActivityTimelineItem(
                id: "c",
                kind: .activity,
                start: at(13, 0),
                end: at(14, 20),
                sessions: [session(at(13, 0), 80, app: "Xcode", category: "工作")]
            )
        ]
    }

    private func render(_ view: some View) throws -> (pixels: [UInt8], width: Int, height: Int) {
        PaletteStore.currentID = RiverPalette.seafoam.rawValue
        let renderer = ImageRenderer(content: view)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image")
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }

    private func isBackground(_ p: (UInt8, UInt8, UInt8)) -> Bool {
        p.0 > 250 && p.1 > 250 && p.2 > 250
    }

    /// The accent is the only *saturated* blue in the app, so "decidedly blue"
    /// separates it from the cool surfaces *and* from the grey text: `secondaryInk`
    /// and `tertiaryInk` lead red by only ~26 at full strength, a 12%-tint
    /// category chip leads by ~19, while the accent leads by 158 and even a
    /// 30%-opacity connector leads by 47. The bar sits between chip tint and
    /// connector so "solid accent evidence" still means node or connector.
    private func isAccent(_ p: (UInt8, UInt8, UInt8)) -> Bool {
        Int(p.2) >= Int(p.0) + 30
    }

    private func pixel(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    // MARK: Pixel helpers

    /// Locates the first node from the bitmap instead of from the layout constants.
    /// A test that assumed the same numbers as the view would happily confirm a
    /// spine that misses every dot.
    ///
    /// A node is the only thing that fills a column of accent for most of the row's
    /// first text line: the connector is 1.5pt wide, and the category chip is thin
    /// glyph strokes. Widest contiguous block of solid columns wins.
    private func firstNodeCentreX(_ image: (pixels: [UInt8], width: Int, height: Int)) throws -> Int {
        let maxY = min(60, image.height)
        // Search only the leading time-and-node columns. Title glyphs can be
        // blue enough to pass the accent threshold, but they are not timeline nodes.
        let maxX = min(200, image.width)
        var counts = [Int](repeating: 0, count: maxX)
        for x in 0..<maxX {
            var count = 0
            for y in 0..<maxY where isAccent(pixel(image.pixels, image.width, x, y)) { count += 1 }
            counts[x] = count
        }

        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        for x in 0...maxX {
            if x < maxX, counts[x] >= 10 {
                if runStart < 0 { runStart = x }
            } else if runStart >= 0 {
                let length = x - runStart
                if length > bestLength {
                    bestLength = length
                    bestStart = runStart
                }
                runStart = -1
            }
        }
        XCTAssertGreaterThanOrEqual(
            bestLength, 6,
            "could not find a solid accent node in the first row (widest block \(bestLength)px)"
        )
        // Fail soft: a missing node must not send callers into out-of-range pixels.
        guard bestStart >= 0, bestLength >= 6 else { return 0 }
        return bestStart + bestLength / 2
    }

    /// Rows of the spine column, in image space, that carry the connector.
    private func spineRows(_ image: (pixels: [UInt8], width: Int, height: Int), around centreX: Int) -> [Bool] {
        (0..<image.height).map { y in
            ((centreX - 2)...(centreX + 2)).contains { x in
                !isBackground(pixel(image.pixels, image.width, x, y))
            }
        }
    }

    // MARK: Tests

    func testSpineRunsThroughTheNodeCentre() throws {
        let image = try render(Harness(items: makeItems()))
        let centreX = try firstNodeCentreX(image)
        let drawn = spineRows(image, around: centreX)

        guard let first = drawn.firstIndex(of: true), let last = drawn.lastIndex(of: true) else {
            return XCTFail("no spine pixels at the node centre x=\(centreX)")
        }
        XCTAssertGreaterThan(last - first, 100, "the spine is far too short to span three rows")

        var longestGap = 0
        var longestGapStart = 0
        var gap = 0
        var gapStart = 0
        for y in first...last {
            if drawn[y] {
                if gap > longestGap {
                    longestGap = gap
                    longestGapStart = gapStart
                }
                gap = 0
            } else {
                if gap == 0 { gapStart = y }
                gap += 1
            }
        }
        // A 1pt line can miss a scanline, but rows failing to meet shows up as a
        // hole the size of the padding between them (~8pt = 16px).
        XCTAssertLessThan(
            longestGap, 6,
            "the spine has a \(longestGap)px hole starting at y=\(longestGapStart) at the node centre; the rows are not connected"
        )
    }

    /// The line must pass through the dots, not beside them.
    func testSpineIsCentredOnTheNodes() throws {
        let image = try render(Harness(items: makeItems()))
        let centreX = try firstNodeCentreX(image)
        let drawn = spineRows(image, around: centreX)

        // Count the rows where the connector is present at the node centre, and
        // compare with a band 4pt to the side: the offset band must be far emptier.
        let onCentre = drawn.filter { $0 }.count
        // 8pt to the side is outside the 9pt node, so the connector must not be there.
        let beside = spineRows(image, around: centreX + 22).filter { $0 }.count
        XCTAssertGreaterThan(onCentre, 0, "nothing is drawn on the node axis at all")
        XCTAssertGreaterThan(
            onCentre, beside * 3,
            "the spine is not centred on the nodes (centre=\(onCentre)px, beside=\(beside)px)"
        )
    }

    /// Compact mode scales the spacing, so a connector measured from scaled numbers
    /// while the columns render unscaled (or the reverse) drifts off the nodes here
    /// and nowhere else. This is the configuration the shipping app actually uses.
    func testSpineStaysCentredOnTheNodesInCompactDensity() throws {
        let image = try render(Harness(items: makeItems(), density: .compact))
        let centreX = try firstNodeCentreX(image)
        let onCentre = spineRows(image, around: centreX).filter { $0 }.count
        let beside = spineRows(image, around: centreX + 22).filter { $0 }.count
        XCTAssertGreaterThan(onCentre, 0, "nothing is drawn on the node axis in compact density")
        XCTAssertGreaterThan(
            onCentre, beside * 3,
            "compact density pulled the connector off the nodes (centre=\(onCentre)px, beside=\(beside)px)"
        )
    }

    func testSpineStopsAtTheLastNode() throws {
        let image = try render(Harness(items: makeItems()))
        let centreX = try firstNodeCentreX(image)
        let drawn = spineRows(image, around: centreX)
        guard let last = drawn.lastIndex(of: true) else { return XCTFail("no spine pixels") }
        // Below the final node the connector must stop, leaving clear canvas.
        // 断言区间必须先保证 lowerBound <= upperBound：旧的 `(last + 8)..<min(...)`
        // 在脊柱一直画到画布底部时会构造失败并触发
        // `Fatal error: Range requires lowerBound <= upperBound`，直接打崩测试进程，
        // 导致后面的用例一个都跑不到（症状是只跑了 141 项就 signal 5 退出）。
        let trailingStart = min(last + 8, image.height)
        let trailingEnd = min(last + 40, image.height)
        guard trailingStart < trailingEnd else { return }
        XCTAssertFalse((trailingStart..<trailingEnd).contains { drawn[$0] }, "the spine runs on past the last node")
    }
}

// MARK: - Node semantics

/// Meaning may not rest on colour alone. A recorded activity is a solid round
/// node in the accent, an unrecorded gap is a hollow neutral ring, and a written
/// note is a square — three shapes, so the three kinds stay tellable apart.
@MainActor
final class TimelineNodeTests: XCTestCase {

    private struct One: View {
        let item: ActivityTimelineItem
        @FocusState private var focus: String?
        var body: some View {
            RiverTimelineView(
                items: [item],
                nowSession: nil,
                selectedItemID: nil,
                onSelect: { _, _ in },
                onWriteNote: {},
                inspectorSourceFocusID: $focus,
                isScrollable: false
            )
            .frame(width: 600)
            .background(Color.white)
        }
    }

    private static let scale: CGFloat = 2
    /// Centre of the node column, and the node's own centre inside the first row.
    private static var nodeCentre: (x: Int, y: Int) {
        let x = AppSpacing.sm + TimelineRowMetrics.timeColumn + TimelineRowMetrics.spineColumn / 2
        let y = TimelineRowMetrics.topInset - 1 + 9.5
        return (Int(x * scale), Int(y * scale))
    }
    /// Just inside a square's corner and outside the matching circular marker.
    private static var nodeCorner: (x: Int, y: Int) {
        let centre = nodeCentre
        // 19pt marker: inside a square's corner, outside a circle's radius.
        return (centre.x - Int(8.5 * scale), centre.y - Int(8.5 * scale))
    }

    private func render(_ item: ActivityTimelineItem) throws -> (pixels: [UInt8], width: Int, height: Int) {
        PaletteStore.currentID = RiverPalette.seafoam.rawValue
        let renderer = ImageRenderer(content: One(item: item))
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage)
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

    private func at(_ image: (pixels: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, luma: Int) {
        let i = (y * image.width + x) * 4
        let r = Int(image.pixels[i]), g = Int(image.pixels[i + 1]), b = Int(image.pixels[i + 2])
        return (r, g, b, (299 * r + 587 * g + 114 * b) / 1000)
    }

    /// The darkest pixel inside the 19pt node: accent for an activity, neutral
    /// ring for a gap, and the warm square stamp for a note.
    private func darkestInNode(_ image: (pixels: [UInt8], width: Int, height: Int)) -> (r: Int, g: Int, b: Int, luma: Int) {
        let centre = Self.nodeCentre
        var best = at(image, centre.x, centre.y)
        for x in (centre.x - 19)...(centre.x + 19) {
            for y in (centre.y - 19)...(centre.y + 19) {
                let value = at(image, x, y)
                if value.luma < best.luma { best = value }
            }
        }
        return best
    }

    private func day(_ hour: Int, _ minute: Int) -> Date {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private func activity() -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: "a", kind: .activity, start: day(9, 15), end: day(10, 0),
            sessions: [ActivitySession(
                appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                windowTitle: "RiverDiaryMac — TimelineView.swift",
                category: "工作", start: day(9, 15), end: day(10, 0)
            )]
        )
    }

    private func gap() -> ActivityTimelineItem {
        ActivityTimelineItem(id: "g", kind: .gap, start: day(11, 0), end: day(12, 30))
    }

    private func capture() -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: "c", kind: .capture, start: day(15, 30), end: day(15, 30),
            capture: QuickCapture(text: "和设计对齐了面板节奏", createdAt: day(15, 30), tag: "决定")
        )
    }

    func testActivityNodeIsSolidAccent() throws {
        let image = try render(activity())
        let node = darkestInNode(image)
        XCTAssertGreaterThan(node.b, node.r + 6, "an activity node should carry the accent")
        // Solid: the centre is the accent, not the surface behind it.
        let centre = at(image, Self.nodeCentre.x, Self.nodeCentre.y)
        XCTAssertLessThan(centre.luma, 200, "the activity node is not filled")
    }

    func testGapNodeIsHollowAndNeutral() throws {
        let image = try render(gap())
        let centre = at(image, Self.nodeCentre.x, Self.nodeCentre.y)
        XCTAssertGreaterThan(centre.luma, 230, "a gap should be a hollow marker, not a filled dot")
        let ring = darkestInNode(image)
        // 中性灰 is slightly cool (blue leads red by ~16 at 60% over white), but it
        // must never read as the accent, which leads by ~95 at the same opacity.
        XCTAssertLessThanOrEqual(ring.b, ring.r + 30, "a gap must not read as recorded activity")
        XCTAssertLessThan(ring.luma, 235, "the gap ring disappeared entirely")
    }

    func testCaptureNodeIsSquareWhileActivityIsRound() throws {
        // The sample sits inside a 19pt square's corner but outside a 19pt circle, so it
        // reads as filled for a note (~135) and as the rim or background for an
        // activity (~228). The thresholds bracket that gap.
        let corner = Self.nodeCorner
        let captureCorner = at(try render(capture()), corner.x, corner.y)
        XCTAssertLessThan(captureCorner.luma, 200, "a note's square marker should reach the node's corner")

        let activityCorner = at(try render(activity()), corner.x, corner.y)
        XCTAssertGreaterThan(
            activityCorner.luma, 215,
            "an activity node is round, so its corner must stay empty — it now looks like a note"
        )
    }
}

// MARK: - Day overview panel

/// The day overview is the part of the page that must work "in one glance", so it
/// is rendered at the real content width and inspected rather than assumed.
@MainActor
final class TimelineDayOverviewTests: XCTestCase {

    private func timeline() -> ActivityTimeline {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        func at(_ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day)! }
        func session(_ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, _ app: String, _ category: String) -> ActivitySession {
            ActivitySession(
                appName: app, bundleID: "test.\(app)", windowTitle: "\(app) 窗口",
                category: category, start: at(h1, m1), end: at(h2, m2)
            )
        }
        let sessions = [
            session(9, 15, 11, 30, "Xcode", "工作"),
            session(13, 0, 14, 20, "Xcode", "工作"),
            session(14, 30, 16, 0, "Safari", "浏览"),
            session(20, 10, 21, 5, "网易云音乐", "娱乐")
        ]
        return ActivityTimelineEngine.build(for: day, sessions: sessions, captures: [], annotations: [:])
    }

    private struct Harness: View {
        let timeline: ActivityTimeline
        var body: some View {
            TimelineDayOverview(date: timeline.date, isToday: false, timeline: timeline, hasWriting: true)
                .frame(width: 920)
                .background(Color.workspace)
        }
    }

    func testDayOverviewComposesWithinTheContentWidth() throws {
        let model = timeline()
        PaletteStore.currentID = RiverPalette.seafoam.rawValue
        let renderer = ImageRenderer(content: Harness(timeline: model))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "the day overview produced no image")

        XCTAssertEqual(image.width, 1840, "the panel did not take the page's content width")
        XCTAssertGreaterThan(image.height, 250, "the day overview collapsed to almost nothing")
        // Four stats, a rule, a band and a footnote should not run away vertically.
        XCTAssertLessThan(image.height, 700, "the day overview grew taller than the viewport it lives in")

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

        func isAccent(_ x: Int, _ y: Int) -> Bool {
            let i = (y * image.width + x) * 4
            return Int(pixels[i + 2]) >= Int(pixels[i]) + 15
        }

        // The ribbon's segments: recorded time must be visible in the band, and the
        // band must still leave hours empty.
        let accentPerRow = (0..<image.height).map { y in
            (0..<image.width).reduce(0) { $0 + (isAccent($1, y) ? 1 : 0) }
        }
        let bandRow = try XCTUnwrap(
            accentPerRow.firstIndex { $0 > 200 },
            "no row in the day overview carries a substantial accent band, so the ribbon did not draw"
        )
        XCTAssertLessThan(
            accentPerRow[bandRow], image.width - 200,
            "the ribbon looks completely filled, so unrecorded hours are not visible"
        )
    }
}
