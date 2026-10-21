import Foundation
import XCTest

@testable import RiverDiaryMac

final class FocusCalculatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        category: String,
        start: TimeInterval,
        duration: TimeInterval,
        app: String = "Xcode"
    ) -> ActivitySession {
        ActivitySession(
            appName: app,
            bundleID: "com.example.\(app)",
            windowTitle: nil,
            category: category,
            start: base.addingTimeInterval(start),
            end: base.addingTimeInterval(start + duration)
        )
    }

    func testThirtyMinuteFocusIsOneBlock() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "工作", start: 0, duration: 30 * 60)
        ])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.minutes, 30)
    }

    func testTwentyMinuteFocusIsIgnored() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "工作", start: 0, duration: 20 * 60)
        ])
        XCTAssertTrue(blocks.isEmpty)
    }

    func testShortDistractionDoesNotBreakBlock() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "工作", start: 0, duration: 15 * 60),
            session(category: "沟通", start: 15 * 60 + 30, duration: 2 * 60, app: "Slack"),
            session(category: "工作", start: 17 * 60 + 30, duration: 15 * 60)
        ])
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.minutes, 30)
    }

    func testLongDistractionSplitsBlocks() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "工作", start: 0, duration: 30 * 60),
            session(category: "娱乐", start: 30 * 60, duration: 8 * 60, app: "YouTube"),
            session(category: "工作", start: 38 * 60, duration: 30 * 60)
        ])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.minutes), [30, 30])
    }

    func testGapOverFiveMinutesStartsNewBlock() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "工作", start: 0, duration: 30 * 60),
            session(category: "工作", start: 40 * 60, duration: 30 * 60)
        ])
        XCTAssertEqual(blocks.count, 2)
    }

    func testNonFocusOnlyIsEmpty() {
        let blocks = FocusCalculator.blocks(from: [
            session(category: "浏览", start: 0, duration: 60 * 60, app: "Safari")
        ])
        XCTAssertTrue(blocks.isEmpty)
    }
}
