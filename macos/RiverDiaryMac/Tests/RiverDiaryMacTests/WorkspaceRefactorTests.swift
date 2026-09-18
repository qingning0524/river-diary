import XCTest
@testable import RiverDiaryMac

final class WorkspaceRefactorTests: XCTestCase {
    private func override(_ text: String, mood: Int? = nil) -> EntryOverride {
        EntryOverride(overview: text, mood: 0, energy: 0, focus: 0, output: 0, updatedAt: Date(timeIntervalSince1970: 1_800_000_000), preservesMetrics: true, writtenMood: mood)
    }
    private func entry(_ date: String, text: String = "", score: Double? = nil) -> DiaryEntry {
        DiaryEntry(pageID: "remote-\(date)", date: date, score: score, overview: text)
    }

    func testWritingWithoutMoodDoesNotInventMetrics() {
        let result = JournalWriting.applying(override("今天只想写一句"), to: entry("2026-09-16"))
        XCTAssertEqual(result.displayOverview, "今天只想写一句")
        XCTAssertNil(result.score)
        XCTAssertNil(result.metrics)
        XCTAssertNil(result.stage)
    }
    func testEmptyWritingDoesNotResurrectOriginalDailyText() {
        var source = entry("2026-09-16")
        source.daily = "外部原文"
        let result = JournalWriting.applying(override(""), to: source)
        XCTAssertTrue(result.displayOverview.isEmpty)
        XCTAssertEqual(source.daily, "外部原文")
    }
    func testExplicitMoodLeavesOtherMetricsUnknownAndCanBeUpdated() {
        let first = JournalWriting.applying(override("感受", mood: 65), to: entry("2026-09-16"))
        let updated = JournalWriting.applying(override("感受", mood: 80), to: first)
        XCTAssertEqual(updated.metrics?.mood, 80)
        XCTAssertEqual(updated.score, 80)
        XCTAssertNil(updated.metrics?.energy)
        XCTAssertNil(updated.metrics?.focus)
        XCTAssertNil(updated.metrics?.output)
    }
    func testTextEditPreservesSourceScoresAndLabels() {
        var source = entry("2026-09-16", text: "旧文字", score: 72)
        source.metrics = DayMetrics(mood: 75, energy: 62, focus: 78, output: 65, overall: 72)
        source.tags = ["散步"]
        source.category = "生活"
        let result = JournalWriting.applying(override("自己的文字"), to: source)
        XCTAssertEqual(result.score, source.score)
        XCTAssertEqual(result.metrics, source.metrics)
        XCTAssertEqual(result.tags, source.tags)
        XCTAssertEqual(result.category, source.category)
    }
    func testSavedWritingReloadUsesSameMergeWithoutInventingScores() throws {
        let value = override("保持原文")
        let state = UserState(entries: ["local-2026-09-16": value])
        let restored = try JSONDecoder().decode(UserState.self, from: JSONEncoder().encode(state))
        let result = JournalWriting.merging(entries: [], overrides: restored.entries)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].displayOverview, "保持原文")
        XCTAssertNil(result[0].score)
        XCTAssertNil(result[0].metrics)
    }
    func testLocalWritingMergesIntoNewExternalSnapshotOnce() {
        let source = entry("2026-09-16", text: "外部文字", score: 70)
        let result = JournalWriting.merging(entries: [source], overrides: ["local-2026-09-16": override("我的原文")])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, source.id)
        XCTAssertEqual(result[0].displayOverview, "我的原文")
        XCTAssertEqual(result[0].score, 70)
    }
    func testLegacyScoredOverrideStillUsesOriginalComposite() {
        var legacy = override("旧版修改")
        legacy.preservesMetrics = nil
        legacy.mood = 80; legacy.energy = 60; legacy.focus = 70; legacy.output = 90
        let result = JournalWriting.applying(legacy, to: entry("2026-09-16"))
        XCTAssertEqual(result.score, 77)
        XCTAssertEqual(result.metrics?.energy, 60)
        XCTAssertEqual(result.displayOverview, "旧版修改")
    }
    @MainActor func testEditorRetainsSeparateUnsavedDaysAndClearsOnlySavedDay() async {
        let editor = JournalEditorStore()
        let first = entry("2026-09-15")
        let second = entry("2026-09-16")
        editor.edit(first, text: "昨天的草稿")
        editor.edit(second, text: "今天的草稿", mood: 80)
        XCTAssertEqual(editor.buffer(for: first).text, "昨天的草稿")
        XCTAssertEqual(editor.buffer(for: second).mood, 80)
        editor.saved(first.date)
        XCTAssertFalse(editor.buffer(for: first).isDirty)
        XCTAssertEqual(editor.buffer(for: second).text, "今天的草稿")
    }
    func testMemoryIncludesCaptureOnlyDayAtAssignedDateAndSearchesIt() {
        let note = QuickCapture(text: "补记旅行", createdAt: Date())
        let days = MemoryArchive.days(entries: [], captures: ["2026-08-31": [note]])
        XCTAssertEqual(days.map(\.id), ["2026-08-31"])
        XCTAssertTrue(days[0].matches("旅行"))
        XCTAssertFalse(days[0].hasWriting)
        XCTAssertNil(days[0].mood)
    }
    func testMemorySearchIncludesTagsAndOriginalNotes() {
        var source = entry("2026-09-16")
        source.tags = ["散步"]
        source.memos = ["河边的风"]
        let day = MemoryArchive.days(entries: [source], captures: [:])[0]
        XCTAssertTrue(day.matches("散步"))
        XCTAssertTrue(day.matches("河边"))
        XCTAssertFalse(day.matches("不存在"))
    }
    func testLocalReviewIgnoresUnscoredDaysAndClipsSessions() throws {
        let start = try XCTUnwrap(DiaryEntry.dateFormatter.date(from: "2026-09-15"))
        let end = try XCTUnwrap(DiaryEntry.dateFormatter.date(from: "2026-09-16"))
        let live = ActivitySession(appName: "Xcode", bundleID: "test", category: "工作", start: start.addingTimeInterval(-1800), end: start.addingTimeInterval(1800))
        let note = QuickCapture(text: "补记", createdAt: end.addingTimeInterval(86400))
        let review = LocalReview.make(start: start, end: end,
                                      entries: [entry("2026-09-15", text: "日记", score: 80), entry("2026-09-16", text: "没评分")],
                                      sessions: [live, live], captures: ["2026-09-15": [note]])
        XCTAssertEqual(review.writingDays, 2)
        XCTAssertEqual(review.averageMood, 80)
        XCTAssertEqual(review.moodSamples, 1)
        XCTAssertEqual(review.days.first?.mood, 80)
        XCTAssertNil(review.days.last?.mood)
        XCTAssertEqual(review.duration, 1800)
        XCTAssertEqual(review.captureCount, 1)
        XCTAssertTrue(review.markdown.contains("平均心情：80"))
    }
    func testEmptyLocalReviewDoesNotDescribeZeroMood() {
        let review = LocalReview.make(start: Date(), end: Date(), entries: [], sessions: [], captures: [:])
        XCTAssertNil(review.averageMood)
        XCTAssertEqual(review.duration, 0)
        XCTAssertTrue(review.markdown.contains("暂无评分"))
    }
    func testCommandDateParsingRejectsInvalidOrPartialDates() {
        XCTAssertNotNil(WorkspaceCommandPalette.parsedDate("2026-09-16"))
        XCTAssertNil(WorkspaceCommandPalette.parsedDate("2026-02-30"))
        XCTAssertNil(WorkspaceCommandPalette.parsedDate("9/16"))
        XCTAssertNil(WorkspaceCommandPalette.parsedDate("日记"))
    }
}
