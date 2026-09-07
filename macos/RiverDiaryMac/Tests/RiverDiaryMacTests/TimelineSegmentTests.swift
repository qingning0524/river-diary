import XCTest
@testable import RiverDiaryMac

final class TimelineSegmentTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testSegmentsGroupSessionsIntoPeriods() {
        let day = date(2026, 9, 5, 0)
        let morning = ActivitySession(
            appName: "Xcode",
            bundleID: "",
            windowTitle: nil,
            category: "工作",
            start: date(2026, 9, 5, 10),
            end: date(2026, 9, 5, 11)
        )
        let evening = ActivitySession(
            appName: "Notes",
            bundleID: "",
            windowTitle: nil,
            category: "创作",
            start: date(2026, 9, 5, 20),
            end: date(2026, 9, 5, 21)
        )

        let segments = TimelineSegmentEngine.segments(for: day, sessions: [morning, evening])
        XCTAssertEqual(segments.count, TimelinePeriod.allCases.count)

        let morningSegment = segments.first { $0.period == .morning }
        let eveningSegment = segments.first { $0.period == .evening }
        XCTAssertEqual(morningSegment?.primaryApp, "Xcode")
        XCTAssertEqual(morningSegment?.sessions.count, 1)
        XCTAssertEqual(eveningSegment?.primaryApp, "Notes")
        XCTAssertEqual(eveningSegment?.sessions.count, 1)
    }

    func testFocusRatioAndSwitchCount() {
        let day = date(2026, 9, 5, 0)
        let first = ActivitySession(
            appName: "Xcode",
            bundleID: "",
            windowTitle: nil,
            category: "工作",
            start: date(2026, 9, 5, 10),
            end: date(2026, 9, 5, 11)
        )
        let second = ActivitySession(
            appName: "Safari",
            bundleID: "",
            windowTitle: nil,
            category: "浏览",
            start: date(2026, 9, 5, 11, 15),
            end: date(2026, 9, 5, 11, 45)
        )

        let segment = TimelineSegmentEngine.segments(for: day, sessions: [first, second]).first { $0.period == .morning }
        XCTAssertEqual(segment?.switchCount, 1)
        XCTAssertEqual(segment?.focusRatio ?? 0, 0.666, accuracy: 0.01)
        XCTAssertEqual(segment?.primaryApp, "Xcode")
    }

    func testEmptyPeriodsStillHaveOrderedBounds() {
        let day = date(2026, 9, 5, 0)
        let segments = TimelineSegmentEngine.segments(for: day, sessions: [])
        XCTAssertTrue(segments.allSatisfy { $0.isEmpty && $0.end > $0.start })
        XCTAssertTrue(segments.allSatisfy { !$0.period.title.isEmpty })
    }

    func testLateNightCombinesEarlyAndLateHours() {
        let day = date(2026, 9, 5, 0)
        let beforeMidnight = ActivitySession(
            appName: "Zed",
            bundleID: "",
            windowTitle: nil,
            category: "工作",
            start: date(2026, 9, 5, 23),
            end: date(2026, 9, 5, 23, 30)
        )

        let segment = TimelineSegmentEngine.segments(for: day, sessions: [beforeMidnight]).first { $0.period == .lateNight }
        XCTAssertEqual(segment?.sessions.count, 1)
        XCTAssertEqual(segment?.primaryApp, "Zed")
    }
}

final class TimelineSegmentNameStoreTests: XCTestCase {
    func testCustomSegmentNamePersistsAndClears() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 10))!

        TimelineSegmentNameStore.save("深度开发", for: date, period: .morning)
        XCTAssertEqual(TimelineSegmentNameStore.name(for: date, period: .morning), "深度开发")

        TimelineSegmentNameStore.save("", for: date, period: .morning)
        XCTAssertEqual(TimelineSegmentNameStore.name(for: date, period: .morning), "")
    }
}


final class TimelineSegmentCaptureTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testQuickCaptureAttachesToSegmentWithoutSessions() {
        let day = date(2026, 9, 6, 0)
        let createdAt = date(2026, 9, 6, 14, 20)
        let capture = QuickCapture(text: "下午想先散步", createdAt: createdAt, tag: "身体")

        let segments = TimelineSegmentEngine.segments(for: day, sessions: [], quickCaptures: [capture])
        let afternoon = segments.first { $0.period == .afternoon }

        XCTAssertEqual(afternoon?.captures.count, 1)
        XCTAssertEqual(afternoon?.captures.first?.text, "下午想先散步")
        XCTAssertEqual(afternoon?.isEmpty, false)
    }

    func testQuickCaptureOutsideSegmentIsNotAttached() {
        let day = date(2026, 9, 6, 0)
        let capture = QuickCapture(text: "上午的记录", createdAt: date(2026, 9, 6, 10), tag: "想法")

        let segments = TimelineSegmentEngine.segments(for: day, sessions: [], quickCaptures: [capture])
        let afternoon = segments.first { $0.period == .afternoon }

        XCTAssertEqual(afternoon?.captures.isEmpty, true)
    }
}
