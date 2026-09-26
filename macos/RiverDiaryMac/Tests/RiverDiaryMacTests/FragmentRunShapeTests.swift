import XCTest

@testable import RiverDiaryMac

/// 碎片带的形态判定。
///
/// 前提（用户原则）：**切屏不说明不专心**——很可能是多工具组合工作。所以判定
/// 先默认中性、往"组合工作"认，只有结构指向"没有主基地"才叫散。
/// 阈值来自本机真实数据分布（2026-09-26：主导占比 p50 = 0.74，组合带 40%，
/// 游移带 0）。改阈值之前先重新跑一遍分布，别拍脑袋。
final class FragmentRunShapeTests: XCTestCase {

    private let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))

    private func at(_ minutes: Double) -> Date {
        day.addingTimeInterval(minutes * 60)
    }

    private func session(_ app: String, _ fromMinutes: Double, _ toMinutes: Double, bundle: String? = nil) -> ActivitySession {
        ActivitySession(
            appName: app,
            bundleID: bundle ?? "test.\(app)",
            windowTitle: nil,
            category: "浏览",
            start: at(fromMinutes),
            end: at(toMinutes)
        )
    }

    /// 人造碎片带：`foldFragments` 只折真实的短块，这里直接拼一条带，
    /// 让判定函数吃固定的输入。
    private func run(_ members: [ActivityTimelineItem]) -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: "fragments-test",
            kind: .activity,
            start: members.first?.start ?? day,
            end: members.last?.end ?? day,
            sessions: members.flatMap(\.sessions),
            fragments: members
        )
    }

    private func member(_ app: String, _ fromMinutes: Double, _ toMinutes: Double) -> ActivityTimelineItem {
        ActivityTimelineItem(
            id: "m-\(app)-\(Int(fromMinutes))",
            kind: .activity,
            start: at(fromMinutes),
            end: at(toMinutes),
            sessions: [session(app, fromMinutes, toMinutes)]
        )
    }

    // MARK: 同应用

    /// 换窗口、换标签页：都在一个应用里，不是跨应用切换。
    func testSameAppMembersAreIntraAppSwitching() {
        let shape = FragmentRunShape.classify(run([
            member("Chrome", 0, 1), member("Chrome", 4, 5), member("Chrome", 8, 9)
        ]))
        XCTAssertEqual(shape, .intraApp(app: "Chrome", count: 3))
        XCTAssertEqual(shape.phrase, "Chrome 里的 3 段短切换")
        XCTAssertEqual(shape.rowTitle(fallbackCount: 3), "Chrome 里的 3 段短切换")
    }

    // MARK: 组合工作

    /// 主基地：反复回到主导应用，副工具是短插针。这是组合工作的常态。
    func testRepeatedReturnsToADominantAppReadAsComposedWork() {
        // Xcode 4 段（回到它 3 次），中间插两次终端；Xcode 前台 4 分钟 / 共 6 分钟 = 0.67。
        let shape = FragmentRunShape.classify(run([
            member("Xcode", 0, 1), member("终端", 2, 3), member("Xcode", 4, 5),
            member("终端", 6, 7), member("Xcode", 8, 9)
        ]))
        XCTAssertEqual(shape, .composedWork(dominant: "Xcode", second: "终端", returns: 3))
        XCTAssertEqual(shape.phrase, "在 Xcode 与 终端 之间来回 3 次")
        XCTAssertEqual(shape.rowTitle(fallbackCount: 5), "组合工作 · 5 段")
    }

    /// 恰好压线的形状不该被误判：占比够但只回去一次（A A A B）不是"来回"。
    func testOneBlockOfDominantAppIsNotComposedWork() {
        let shape = FragmentRunShape.classify(run([
            member("Xcode", 0, 1), member("Xcode", 2, 3), member("Xcode", 4, 5), member("终端", 6, 7)
        ]))
        // 全是同一个 bundle → 同应用；这里两个应用，但主导应用只出现一个连续块。
        XCTAssertEqual(shape, .mixed)
    }

    /// 两次成员不到组合工作的下限（本机分布：25% 的带只有两段）。
    func testTwoMemberSwitchesStayNeutral() {
        let shape = FragmentRunShape.classify(run([
            member("Xcode", 0, 1), member("终端", 4, 5)
        ]))
        XCTAssertEqual(shape, .mixed)
        XCTAssertNil(shape.phrase, "没有可说的结构就别硬编一句话")
    }

    // MARK: 游移

    /// 没有主基地：好几个应用、谁都不占多数。这只描述结构，不评判。
    func testNoDominantAppAcrossManyAppsReadsAsWandering() {
        let shape = FragmentRunShape.classify(run([
            member("Chrome", 0, 1), member("微信", 2, 3), member("备忘录", 4, 5),
            member("访达", 6, 7), member("预览", 8, 9)
        ]))
        XCTAssertEqual(shape, .wandering(appCount: 5))
        XCTAssertEqual(shape.phrase, "分散在 5 个应用之间")
        XCTAssertEqual(shape.rowTitle(fallbackCount: 5), "5 段碎片")
    }

    // MARK: 权重与前台口径

    /// 主导应用按**前台时长**计，不按段数：九段 5 秒的插针抵不过一段 4 分钟的主干。
    func testDominanceIsWeightedByForegroundTimeNotSegmentCount() {
        let members = [
            member("终端", 0, 1), member("终端", 2, 3), member("终端", 4, 5),
            member("Xcode", 6, 10)
        ]
        let shape = FragmentRunShape.classify(run(members))
        // Xcode 前台 4 分钟 / 共 7 分钟 = 0.57 < 0.6，且回归只有 1 次 → 还不到组合工作。
        XCTAssertEqual(shape, .mixed)
    }

    /// 全零时长（理论上不该发生）也必须给出判定，按段数计权。
    func testZeroDurationMembersStillClassify() {
        let members = [
            member("Xcode", 0, 0), member("终端", 0, 0), member("Xcode", 0, 0),
            member("终端", 0, 0), member("Xcode", 0, 0)
        ]
        let shape = FragmentRunShape.classify(run(members))
        // 按段数：Xcode 3/5 = 0.6，回归 3 次 → 组合工作。
        XCTAssertEqual(shape, .composedWork(dominant: "Xcode", second: "终端", returns: 3))
    }

    // MARK: 展示层的接缝

    /// 行的第二行：形态短语优先，mixed 退回应用构成（由视图负责，这里只验证短语契约）。
    func testMixedShapeLeavesTheCompositionToTheRow() {
        XCTAssertNil(FragmentRunShape.mixed.phrase)
        XCTAssertNotNil(FragmentRunShape.composedWork(dominant: "A", second: "B", returns: 2).phrase)
    }

    /// 标题跟着形态走：`ActivityTimelineItem.title` 对碎片带改用形态命名，
    /// 人工标题仍然最优先。
    func testRunTitleUsesTheShape() {
        let composed = run([
            member("Xcode", 0, 1), member("终端", 2, 3), member("Xcode", 4, 5),
            member("终端", 6, 7), member("Xcode", 8, 9)
        ])
        XCTAssertEqual(composed.title, "组合工作 · 5 段")

        let wandering = run([
            member("Chrome", 0, 1), member("微信", 2, 3), member("备忘录", 4, 5),
            member("访达", 6, 7), member("预览", 8, 9)
        ])
        XCTAssertEqual(wandering.title, "5 段碎片")
    }
}
