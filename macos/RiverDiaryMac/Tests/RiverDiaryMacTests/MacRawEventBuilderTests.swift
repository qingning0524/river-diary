import Foundation
import XCTest

@testable import RiverDiaryMac

final class MacRawEventBuilderTests: XCTestCase {
    func testNoteEventsCarryTitleBodyAndStableID() {
        let note = DailyNoteEntry(
            title: "窗边",
            body: "去河边走走。",
            source: "备忘录",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let first = MacRawEventBuilder.noteEvents([note], source: .notes, namespace: "mac.notes")
        let second = MacRawEventBuilder.noteEvents([note], source: .notes, namespace: "mac.notes")

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertEqual(first[0].source, .notes)
        XCTAssertEqual(first[0].kind, .noteModified)
        XCTAssertEqual(first[0].payload.title, "窗边")
        XCTAssertEqual(first[0].payload.text, "去河边走走。")
        XCTAssertEqual(first[0].timestamp, note.modifiedAt)
    }

    func testBrowserEventsAreCapped() {
        let visits = (0..<8).map { index in
            ChromeVisit(
                url: "https://example.com/\(index)",
                title: "页面 \(index)",
                visitedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)),
                visitCount: 1,
                domain: "example.com",
                browser: "Safari"
            )
        }
        let events = MacRawEventBuilder.browserEvents(visits, limit: 3)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].source, .chrome)
        XCTAssertEqual(events[0].kind, .urlVisit)
        XCTAssertEqual(events[0].payload.url, "https://example.com/0")
        XCTAssertEqual(events[0].payload.title, "页面 0")
    }
}
