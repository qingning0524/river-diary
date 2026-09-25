import XCTest
@testable import RiverDiaryMac

/// 碎片带与第二行文案：一天怎么读，取决于"什么占一行"。
///
/// 折叠只发生在 `foldedItems`，`items` 始终逐条——这一组测试同时钉住两件事：
/// 列表变短了，以及没有任何一条证据因此消失。
final class TimelineFragmentTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))! }
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    private func session(_ start: Double, _ end: Double, app: String = "Xcode", category: String = "工作", title: String? = nil) -> ActivitySession {
        ActivitySession(appName: app, bundleID: "test.\(app)", windowTitle: title, category: category, start: at(start), end: at(end))
    }
    private func build(
        _ sessions: [ActivitySession], captures: [QuickCapture] = [],
        annotations: [String: TimelineAnnotation] = [:]
    ) -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: day, sessions: sessions, captures: captures, calendar: calendar, annotations: annotations
        )
    }
    /// 一条人造节点，用来直接检验折叠函数自身的边界，而不必让 `build` 的合并规则配合。
    private func node(_ id: String, _ start: Double, spanMinutes: Double = 1) -> ActivityTimelineItem {
        ActivityTimelineItem(id: id, kind: .activity, start: at(start), end: at(start + spanMinutes), sessions: [session(start, start + spanMinutes)])
    }

    // MARK: - 折叠

    func testConsecutiveShortBlocksFoldIntoOneRun() {
        let model = build([
            session(600, 601), session(604, 605), session(608, 609),
            session(700, 730),
            session(800, 801), session(804, 805)
        ])
        XCTAssertEqual(model.items.filter { $0.kind == .activity }.count, 6)
        XCTAssertTrue(model.items.allSatisfy { !$0.isFragmentRun })

        let runs = model.foldedItems.filter(\.isFragmentRun)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[0].fragments.count, 3)
        XCTAssertEqual(runs[0].title, "3 段碎片")
        XCTAssertEqual(runs[0].start, at(600))
        XCTAssertEqual(runs[0].end, at(609))
        XCTAssertEqual(runs[0].sessions.count, 3)
        XCTAssertEqual(runs[0].duration, 3 * 60)
        XCTAssertTrue(runs[0].id.hasPrefix("fragments-"))
        XCTAssertNil(runs[0].evidenceRef, "碎片带是聚合视图，展开后每个成员各自有引用")
        XCTAssertEqual(runs[1].fragments.count, 2)

        XCTAssertEqual(model.foldedItems.filter { !$0.isFragmentRun && $0.kind == .activity }.count, 1)
        XCTAssertEqual(model.foldedItems.count, 5, "两条空档保留在列表里")
        XCTAssertEqual(model.totalDuration, 35 * 60, "折叠不改变统计")
        XCTAssertEqual(model.recordedNodeCount, 6)
        XCTAssertEqual(model.fragmentNodeCount, 5)
    }

    func testFlatteningFoldedListReturnsEveryEvidenceNode() {
        let model = build([
            session(600, 601), session(604, 605), session(608, 609),
            session(700, 730),
            session(800, 801), session(804, 805)
        ])
        XCTAssertEqual(ActivityTimelineEngine.flattenFragments(model.foldedItems), model.items)
        XCTAssertTrue(ActivityTimelineExport.markdown(model).contains("Xcode"))
    }

    func testCapturesAndFavoritesBreakRuns() {
        let note = QuickCapture(text: "喝水", createdAt: at(612))
        let favorite = session(700, 701)
        let annotations = [TimelineAnnotation.key(for: favorite): TimelineAnnotation(isFavorite: true)]
        let model = build(
            [
                session(600, 601), session(604, 605), session(608, 609),
                favorite,
                session(800, 801), session(804, 805), session(808, 809)
            ],
            captures: [note], annotations: annotations
        )

        let runs = model.foldedItems.filter(\.isFragmentRun)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.map { $0.fragments.count }, [3, 3])

        let kept = model.foldedItems.first { !$0.isFragmentRun && $0.kind == .activity }
        XCTAssertEqual(kept?.isFavorite, true)
        XCTAssertEqual(kept?.start, at(700))
        XCTAssertEqual(
            model.foldedItems.map(\.kind),
            [.activity, .gap, .capture, .activity, .gap, .activity]
        )
    }

    func testLoneShortBlockStaysARowAndRunsSplitAtSpanCap() {
        XCTAssertEqual(ActivityTimelineEngine.foldFragments([node("solo", 600)]).count, 1)
        XCTAssertFalse(ActivityTimelineEngine.foldFragments([node("solo", 600)])[0].isFragmentRun)

        // 每分钟一个、各占 10 秒：跨度 60 分钟的上限先到，第二条只剩一个成员。
        let spaced = (0..<13).map { node("b-\($0)", 600 + Double($0) * 5) }
        let folded = ActivityTimelineEngine.foldFragments(spaced)
        XCTAssertEqual(folded.filter(\.isFragmentRun).map { $0.fragments.count }, [12])
        XCTAssertEqual(folded.count, 2)
        XCTAssertFalse(folded[1].isFragmentRun)
    }

    func testRunSplitsAtCountCap() {
        let dense = (0..<30).map { node("a-\($0)", 600 + Double($0), spanMinutes: 1.0 / 6) }
        let runs = ActivityTimelineEngine.foldFragments(dense).filter(\.isFragmentRun)
        XCTAssertEqual(runs.map { $0.fragments.count }, [24, 6])
    }

    // MARK: - 第二行文案

    func testEvidenceLinePrefersTitleThenCompositionThenCoverage() {
        XCTAssertEqual(build([session(600, 660, title: "河流界面")]).items[0].evidenceLine, "河流界面")
        XCTAssertEqual(build([session(600, 660)]).items[0].evidenceLine, "", "只有一个应用时标题已经说了，不必复述")

        let mixed = build([session(600, 620, app: "Chrome"), session(621, 640, app: "ZCode")]).items[0]
        XCTAssertEqual(mixed.apps.count, 2)
        XCTAssertEqual(mixed.evidenceLine, "Chrome 20 分钟 · ZCode 19 分钟")

        // 3 分钟一段、中间空 2 分钟：跨度 38 分钟里只有 24 分钟真的在前台。
        let sparse = build([
            session(600, 603), session(605, 608), session(610, 613), session(615, 618),
            session(620, 623), session(625, 628), session(630, 633), session(635, 638)
        ]).items[0]
        XCTAssertEqual(sparse.span, 38 * 60)
        XCTAssertEqual(sparse.duration, 24 * 60)
        XCTAssertEqual(sparse.evidenceLine, "跨度 38 分钟 · 实际前台 24 分钟")
    }

    func testEvidenceLineUsesNotesTagsRunsAndGaps() {
        let note = TimelineAnnotation(note: "在改时间线")
        let key = TimelineAnnotation.key(for: session(600, 640))
        XCTAssertEqual(build([session(600, 640)], annotations: [key: note]).items[0].evidenceLine, "在改时间线")

        let tagged = build([], captures: [QuickCapture(text: "记录一下", createdAt: at(650), tag: "灵感")])
        XCTAssertEqual(tagged.items.first { $0.kind == .capture }?.evidenceLine, "灵感")
        let untagged = build([], captures: [QuickCapture(text: "记录一下", createdAt: at(650))])
        XCTAssertEqual(untagged.items.first { $0.kind == .capture }?.evidenceLine, "手动记录")

        let model = build([session(600, 601), session(604, 605), session(608, 609), session(700, 730)])
        let run = model.foldedItems.first { $0.isFragmentRun }
        XCTAssertEqual(run?.evidenceLine, "跨度 9 分钟", "碎片带说跨度，不说片段计数")
        XCTAssertEqual(model.items.first { $0.kind == .gap }?.evidenceLine, "这段时间没有实时足迹")
    }

    func testSamplingCountNeverReachesTheRowCopy() {
        let model = build([session(600, 610), session(611, 630, app: "Terminal")])
        let item = model.items[0]
        XCTAssertEqual(item.sessions.count, 2)
        XCTAssertTrue(item.summary.contains("2 个原始片段"), "旧文案仍在，供导出与兼容读取")
        XCTAssertEqual(item.evidenceLine, "Terminal 19 分钟 · Xcode 10 分钟")
        XCTAssertFalse(item.evidenceLine.contains("原始片段"))
    }
}

/// 什么才值得请你确认：产品决策的回归防线（2026-09-26 修订）。
final class TimelineReviewCriteriaTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var day: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))! }
    private func at(_ minutes: Double) -> Date { day.addingTimeInterval(minutes * 60) }
    private func session(_ start: Double, _ end: Double, app: String = "Xcode", category: String = "工作", title: String? = nil) -> ActivitySession {
        ActivitySession(appName: app, bundleID: "test.\(app)", windowTitle: title, category: category, start: at(start), end: at(end))
    }
    private func build(
        _ sessions: [ActivitySession], captures: [QuickCapture] = [],
        annotations: [String: TimelineAnnotation] = [:]
    ) -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: day, sessions: sessions, captures: captures, calendar: calendar, annotations: annotations
        )
    }

    func testLongUnexplainedStretchIsTheOnlyThingInTheQueue() {
        let long = build([session(600, 640)]).items[0]
        XCTAssertTrue(long.needsReview)
        XCTAssertEqual(long.needsReviewReason, "20 分钟没有可说明的证据")
    }

    func testTitleAnnotationAndReviewedStateAllClearTheQueue() {
        XCTAssertFalse(build([session(600, 640, title: "河流界面")]).items[0].needsReview)
        let key = TimelineAnnotation.key(for: session(600, 640))
        XCTAssertFalse(build([session(600, 640)], annotations: [key: TimelineAnnotation(note: "在改时间线")]).items[0].needsReview)
        XCTAssertFalse(build([session(600, 640)], annotations: [key: TimelineAnnotation(title: "写日记")]).items[0].needsReview)
        XCTAssertFalse(build([session(600, 640)], annotations: [key: TimelineAnnotation(isReviewed: true)]).items[0].needsReview)
    }

    func testShortBlocksGapsAndFragmentRunsAreNeverInTheQueue() {
        XCTAssertFalse(build([session(600, 610)]).items[0].needsReview)
        let withGap = build([session(600, 640), session(700, 720)])
        XCTAssertEqual(withGap.items.map(\.kind), [.activity, .gap, .activity])
        XCTAssertFalse(withGap.items[1].needsReview, "睡眠与离开电脑是常态，不是待办")
        XCTAssertTrue(withGap.items[0].needsReview)

        // 一条横跨 41 分钟的碎片带没有窗口标题、也没有标注，但它的每个成员都不到 3 分钟：
        // 若不显式排除，它会被当成"41 分钟没有可说明的证据"塞进队列。
        let fragmented = build((0..<11).map { session(600 + Double($0) * 4, 601 + Double($0) * 4) })
        let run = fragmented.foldedItems.first { $0.isFragmentRun }
        XCTAssertNotNil(run)
        XCTAssertEqual(run?.span, 41 * 60)
        XCTAssertFalse(run?.hasDescribingEvidence ?? true)
        XCTAssertFalse(run?.needsReview ?? true)
    }

    func testQueueIsEmptyOnAnOrdinaryDay() {
        // 一个普通的上午：短块 + 一条手工标注，队列应当是空的。
        let key = TimelineAnnotation.key(for: session(700, 730))
        let model = build(
            [session(600, 610), session(615, 625), session(700, 730)],
            annotations: [key: TimelineAnnotation(note: "评审会")]
        )
        XCTAssertEqual(model.items.filter(\.needsReview).count, 0)
    }
}

/// 证据工具不记录自己：改名或换构建配置的旧版本也必须被挡住。
final class ActivityClassifierSelfExclusionTests: XCTestCase {
    func testRenamedBuildsOfTheRecorderAreNeverRecorded() {
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "Legacy River Diary", bundleID: "studio.riverdiary.legacy"))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "River Timeline Preview", bundleID: "studio.riverdiary.timeline-preview"))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "河流日记", bundleID: "studio.riverdiary.mac"))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "RiverDiary", bundleID: ""))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "River Diary", bundleID: ""))
    }

    func testOrdinaryAppsAndSystemSurfacesAreUnaffected() {
        XCTAssertTrue(ActivityClassifier.isRecordable(appName: "Xcode", bundleID: "com.apple.dt.Xcode"))
        XCTAssertTrue(ActivityClassifier.isRecordable(appName: "Chrome", bundleID: "com.google.Chrome"))
        XCTAssertTrue(ActivityClassifier.isRecordable(appName: "河流笔记", bundleID: "com.example.rivers"))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "loginwindow", bundleID: "com.apple.loginwindow"))
        XCTAssertFalse(ActivityClassifier.isRecordable(appName: "ScreenSaverEngine", bundleID: "com.apple.ScreenSaver.Engine"))
    }

    func testSelfSessionsAreDroppedBeforeTheyBecomeDiaryRows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        let selfSession = ActivitySession(
            appName: "Legacy River Diary", bundleID: "studio.riverdiary.legacy",
            category: "工作", start: day.addingTimeInterval(600), end: day.addingTimeInterval(640)
        )
        let model = ActivityTimelineEngine.build(for: day, sessions: [selfSession], calendar: calendar)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.totalDuration, 0)
    }
}
