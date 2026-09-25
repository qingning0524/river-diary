import XCTest

@testable import RiverDiaryMac

/// "发送内容预览"回归：用户在按下生成之前看到的数字，必须与实际会发送的内容
/// 一致——隐私提示一旦对不上真实发送量，就是更糟的误导。
final class AIPayloadPreviewTests: XCTestCase {

    private let calendar = Calendar.current

    private func day(_ value: String) -> Date {
        DiaryEntry.dateFormatter.date(from: value)!
    }

    private func entry(_ date: String, text: String) -> DiaryEntry {
        var entry = DiaryEntry(pageID: "test-\(date)", date: date)
        entry.overview = text
        entry.thoughts = [text]
        return entry
    }

    private func session(_ date: String, hour: Int, title: String?) -> ActivitySession {
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day(date))!
        return ActivitySession(
            appName: "Xcode",
            bundleID: "com.apple.dt.Xcode",
            windowTitle: title,
            category: "工作",
            start: start,
            end: start.addingTimeInterval(1800)
        )
    }

    func testPreviewOnlyCountsRecordsInsideTheRange() {
        let preview = AIAssistantStore.preview(
            entries: [
                entry("2026-09-20", text: "范围外"),
                entry("2026-09-23", text: "范围内一天"),
                entry("2026-09-24", text: "范围内两天")
            ],
            captures: [],
            sessions: [],
            startDate: "2026-09-23",
            endDate: "2026-09-24",
            includesTitles: false
        )
        XCTAssertEqual(preview.entryCount, 2, "范围外的日记不得计入发送量")
    }

    func testTitlesAreOnlyCountedWhenTheyWillBeSent() {
        let sessions = [
            session("2026-09-23", hour: 10, title: "RiverDiary — AIAssistantStore.swift"),
            session("2026-09-23", hour: 11, title: nil)
        ]
        let without = AIAssistantStore.preview(
            entries: [], captures: [], sessions: sessions,
            startDate: "2026-09-23", endDate: "2026-09-23", includesTitles: false
        )
        let with = AIAssistantStore.preview(
            entries: [], captures: [], sessions: sessions,
            startDate: "2026-09-23", endDate: "2026-09-23", includesTitles: true
        )
        XCTAssertEqual(without.titleCount, 0)
        XCTAssertEqual(with.titleCount, 1, "只有真的带标题的片段才计数")
        XCTAssertGreaterThan(with.characterCount, without.characterCount)
        XCTAssertTrue(with.summary.contains("窗口标题 1 条"))
        XCTAssertFalse(without.summary.contains("窗口标题"))
    }

    func testNilRangeKeepsLegacyBehaviour() {
        // 不传范围时不做裁剪，避免影响没有范围概念的调用点。
        let preview = AIAssistantStore.preview(
            entries: [entry("2020-01-01", text: "很久以前")],
            captures: [], sessions: [],
            startDate: nil, endDate: nil, includesTitles: false
        )
        XCTAssertEqual(preview.entryCount, 1)
    }
}
