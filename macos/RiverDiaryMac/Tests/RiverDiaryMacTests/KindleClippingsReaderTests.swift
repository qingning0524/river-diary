import Foundation
import XCTest

@testable import RiverDiaryMac

final class KindleClippingsReaderTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-kindle-\(UUID().uuidString).txt")
    }

    override func tearDown() {
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        super.tearDown()
    }

    func testParsesTodayHighlightAndBookTitle() throws {
        let now = try makeDate(year: 2026, month: 10, day: 20, hour: 12)
        let text = """
        深入理解计算机系统 (Randal E. Bryant)
        - Your Highlight on page 42 | Location 123-124 | Added on Tuesday, October 20, 2026 10:15:30 PM

        程序的执行就是状态的变化。
        ==========
        """
        try Data(text.utf8).write(to: fileURL)

        let result = KindleClippingsReader.readToday(fileURL: fileURL, now: now)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.title, "深入理解计算机系统")
        XCTAssertEqual(result.entries.first?.body, "程序的执行就是状态的变化。")
        XCTAssertEqual(result.entries.first?.source, "Kindle")
    }

    func testIgnoresYesterdayAndUndatedEntries() throws {
        let now = try makeDate(year: 2026, month: 10, day: 20, hour: 12)
        let text = """
        旧书 (作者)
        - Your Highlight on page 1 | Added on Monday, October 19, 2026 9:00:00 AM

        昨天的划线。
        ==========
        没有日期 (作者)
        - Your Highlight on page 2

        无法归属的划线。
        ==========
        """
        try Data(text.utf8).write(to: fileURL)

        let result = KindleClippingsReader.readToday(fileURL: fileURL, now: now)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.issue)
    }

    func testMissingFileReportsIssue() {
        let result = KindleClippingsReader.readToday(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).txt")
        )
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.issue)
    }

    func testBookTitleKeepsParenthesesInsideTitle() {
        XCTAssertEqual(KindleClippingsReader.bookTitle(from: "C (A) Programming (K&R)"), "C (A) Programming")
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone.current
        return try XCTUnwrap(Calendar.current.date(from: components))
    }
}
