import XCTest
@testable import RiverDiaryMac

final class ModelTests: XCTestCase {
    func testLegacyEntryOverrideDecodeKeepsExistingJournalUsable() throws {
        let json = """
        {"overview":"复杂而清醒","mood":75,"energy":65,"focus":80,"output":70,"updatedAt":"2026-09-04T00:00:00Z"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let override = try decoder.decode(EntryOverride.self, from: json)

        XCTAssertEqual(override.overview, "复杂而清醒")
        XCTAssertNil(override.category)
        XCTAssertNil(override.tags)
    }

    func testMoodAnalyzerExtractsRepeatedSignals() {
        let reading = MoodAnalyzer.reading(for: "白天很清醒，专注读文档。晚上回忆又出现了，但心情平静。")
        XCTAssertTrue(reading.signals.contains { $0.word == "清醒" })
        XCTAssertTrue(reading.signals.contains { $0.word == "平静" })
        XCTAssertFalse(reading.summary.isEmpty)
    }

    func testEntryDateFormattingStaysStable() {
        let entry = DiaryEntry(
            pageID: "test",
            date: "2026-09-04",
            score: 75,
            daily: nil,
            overview: nil,
            thoughts: nil,
            memos: nil,
            tags: ["平静"],
            category: "随想",
            metrics: nil,
            stage: nil
        )

        XCTAssertEqual(entry.shortDate, "9月4日")
        XCTAssertEqual(entry.mood, 75)
    }
}
