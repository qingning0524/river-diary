import Foundation
import XCTest

@testable import RiverDiaryMac

final class CalendarContextEventsTests: XCTestCase {
    func testEventSnapshotBecomesCalendarRawEvent() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3_600)
        let snapshot = CalendarContextSnapshot(
            events: [
                CalendarEventSnapshot(
                    id: "event-1",
                    title: "写方案",
                    calendarName: "工作",
                    start: start,
                    end: end,
                    isAllDay: false,
                    attendeeCount: 3
                )
            ],
            reminders: [],
            issue: nil
        )

        let events = CalendarContextEvents.makeEvents(from: snapshot)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.source, .calendar)
        XCTAssertEqual(event.kind, .calendarEvent)
        XCTAssertEqual(event.timestamp, start)
        XCTAssertEqual(event.payload.text, "写方案")
        XCTAssertEqual(event.payload.sessionEnd, end)
        XCTAssertEqual(event.payload.calendarName, "工作")
        XCTAssertEqual(event.payload.isAllDay, false)
        XCTAssertEqual(event.payload.attendeeCount, 3)
    }

    func testReminderBecomesCompletedRawEvent() throws {
        let completedAt = Date(timeIntervalSince1970: 1_800_003_600)
        let snapshot = CalendarContextSnapshot(
            events: [],
            reminders: [
                ReminderSnapshot(id: "reminder-1", title: "交周报", listName: "工作", completedAt: completedAt)
            ],
            issue: nil
        )

        let events = CalendarContextEvents.makeEvents(from: snapshot)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.source, .reminders)
        XCTAssertEqual(event.kind, .reminderCompleted)
        XCTAssertEqual(event.timestamp, completedAt)
        XCTAssertEqual(event.payload.text, "交周报")
        XCTAssertEqual(event.payload.calendarName, "工作")
    }

    func testSameSnapshotProducesStableIDs() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = CalendarContextSnapshot(
            events: [
                CalendarEventSnapshot(
                    id: "event-1",
                    title: "站会",
                    calendarName: "工作",
                    start: start,
                    end: start.addingTimeInterval(900),
                    isAllDay: false,
                    attendeeCount: 4
                )
            ],
            reminders: [],
            issue: nil
        )

        let first = CalendarContextEvents.makeEvents(from: snapshot).map(\.id)
        let second = CalendarContextEvents.makeEvents(from: snapshot).map(\.id)
        XCTAssertEqual(first, second)
    }

    func testEmptySnapshotProducesNoEvents() {
        let snapshot = CalendarContextSnapshot(events: [], reminders: [], issue: "日历未授权")
        XCTAssertTrue(CalendarContextEvents.makeEvents(from: snapshot).isEmpty)
    }
}
