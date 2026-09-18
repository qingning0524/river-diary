import XCTest
@testable import RiverDiaryMac

final class MonthlyLetterTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
    private func entry(_ day: String, _ score: Double?) -> DiaryEntry {
        DiaryEntry(pageID: day, date: day, score: score)
    }

    func testFiltersMonthDeduplicatesDaysAndExcludesFutureRecords() throws {
        let letter = try XCTUnwrap(MonthlyLetter.make(
            for: date(9, 1),
            entries: [entry("2026-08-31", 100), entry("2026-09-01", 80),
                      entry("2026-09-01", 80), entry("2026-09-02", nil), entry("2026-09-30", 0)],
            captures: [:], sessions: [], now: date(9, 12), calendar: calendar
        ))
        XCTAssertEqual(letter.month, "2026-09")
        XCTAssertTrue(letter.evidence.contains("2 天日记 · 1 天评分"))
        XCTAssertTrue(letter.body.contains("平均为 80"))
        XCTAssertNil(MonthlyLetter.make(for: date(10, 1), entries: [entry("2026-10-01", 80)],
                                       captures: [:], sessions: [], now: date(9, 12), calendar: calendar))
    }

    func testBackdatedNoteUsesAssignedMonthAndNoScoreIsInvented() throws {
        let letter = try XCTUnwrap(MonthlyLetter.make(
            for: date(8, 1), entries: [],
            captures: ["2026-08-31": [QuickCapture(text: "补记", createdAt: date(9, 1))]],
            sessions: [], now: date(9, 12), calendar: calendar
        ))
        XCTAssertTrue(letter.evidence.contains("1 条快记"))
        XCTAssertTrue(letter.body.contains("还没有可用的状态评分"))
        XCTAssertFalse(letter.body.contains("平均为 0"))
    }

    func testSessionCrossingMonthIsClipped() throws {
        let session = ActivitySession(appName: "Xcode", bundleID: "test", category: "工作",
                                      start: date(8, 31, 23), end: date(9, 1, 1))
        let letter = try XCTUnwrap(MonthlyLetter.make(for: date(9, 1), entries: [], captures: [:],
                                                     sessions: [session], now: date(9, 12), calendar: calendar))
        XCTAssertTrue(letter.body.contains("约 60 分钟"))
    }

    func testEditedFavoriteSurvivesStateAndBackupRoundTrip() throws {
        var letter = try XCTUnwrap(MonthlyLetter.make(for: date(9, 1), entries: [entry("2026-09-01", 80)],
                                                     captures: [:], sessions: [], now: date(9, 12), calendar: calendar))
        letter.title = "我想留下的九月"
        letter.body = "保留我写下的原文。"
        letter.isFavorite = true
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = UserState(monthlyLetters: [letter.month: letter])
        let restored = try decoder.decode(UserState.self, from: encoder.encode(state))
        XCTAssertEqual(restored.monthlyLetters?[letter.month], letter)
        let backup = LocalBackupPayload(exportedAt: date(9, 12), overrides: [:], quickCaptures: [:],
                                        dismissedDrafts: [:], careAcknowledgments: [:], monthlyLetters: [letter.month: letter])
        XCTAssertEqual(try decoder.decode(LocalBackupPayload.self, from: encoder.encode(backup)).monthlyLetters?[letter.month], letter)
        XCTAssertTrue(letter.markdown.contains(letter.body))
        XCTAssertTrue(letter.markdown.contains(letter.evidence))
    }

    func testOldStateWithoutLettersStillLoads() throws {
        let oldState = Data(#"{"version":3,"entries":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UserState.self, from: oldState).monthlyLetters)
        XCTAssertNil(MonthlyLetter.make(for: date(9, 1), entries: [], captures: [:], sessions: [],
                                       now: date(9, 12), calendar: calendar))
    }
}
