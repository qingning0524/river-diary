import XCTest
@testable import RiverDiaryMac

final class FeatureLogicTests: XCTestCase {
    func testLegacyQuickCaptureDecodeKeepsTagEmpty() throws {
        let json = """
        {"id":"6D6B5CE7-2D95-4445-8F3C-6DDB4A88D25A","text":"旧快记","createdAt":"2026-09-04T12:00:00Z","source":"iOS 快记"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let capture = try decoder.decode(QuickCapture.self, from: json)
        XCTAssertEqual(capture.text, "旧快记")
        XCTAssertNil(capture.tag)
        XCTAssertFalse(capture.pinned)
    }

    func testQuickCaptureTagSurvivesRoundTrip() throws {
        let capture = QuickCapture(text: "记得喝水", createdAt: Date(), tag: "身体")
        let encoded = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(QuickCapture.self, from: encoded)
        XCTAssertEqual(decoded.tag, "身体")
    }

    func testQuickCapturePinnedOrderingSurvivesRoundTrip() throws {
        let base = Date(timeIntervalSince1970: 1_788_000_000)
        let captures = [
            QuickCapture(text: "早上的想法", createdAt: base),
            QuickCapture(text: "重要待办", createdAt: base.addingTimeInterval(60), isPinned: true),
            QuickCapture(text: "稍后的想法", createdAt: base.addingTimeInterval(120))
        ]
        let ordered = QuickCapture.sortedForDisplay(captures)
        XCTAssertEqual(ordered.map(\.text), ["重要待办", "早上的想法", "稍后的想法"])

        let encoded = try JSONEncoder().encode(captures[1])
        let decoded = try JSONDecoder().decode(QuickCapture.self, from: encoded)
        XCTAssertTrue(decoded.pinned)
    }

    func testPearsonDetectsPositiveAndNegativeCorrelation() {
        let positive = Pearson.compute([(10, 12), (20, 23), (30, 28), (40, 41)])
        let negative = Pearson.compute([(10, 40), (20, 30), (30, 20), (40, 10)])
        XCTAssertEqual(positive, 0.98, accuracy: 0.05)
        XCTAssertEqual(negative, -1.0, accuracy: 0.001)
        XCTAssertEqual(Pearson.compute([(1, 2)]), 0)
    }

    func testLifeSegmentGroupsSessionsWithoutEmptySegments() {
        let morning = DateComponents(year: 2026, month: 9, day: 4, hour: 9)
        let evening = DateComponents(year: 2026, month: 9, day: 4, hour: 20)
        let calendar = Calendar.current
        let startA = calendar.date(from: morning)!
        let startB = calendar.date(from: evening)!
        let sessions = [
            ActivitySession(appName: "Xcode", bundleID: "", windowTitle: nil, category: "工作", start: startA, end: startA.addingTimeInterval(3600)),
            ActivitySession(appName: "Notes", bundleID: "", windowTitle: nil, category: "创作", start: startB, end: startB.addingTimeInterval(1800))
        ]
        let segments = LifeSegment.make(from: sessions)
        XCTAssertEqual(segments.map(\.title), ["清晨", "夜晚"])
        XCTAssertEqual(segments.first?.appSummary, "Xcode")
    }

    func testRiverLetterRequiresThirtyDays() {
        let entry = DiaryEntry(
            pageID: "test",
            date: "2026-09-04",
            score: 72,
            daily: nil,
            overview: nil,
            thoughts: nil,
            memos: nil,
            tags: nil,
            category: nil,
            metrics: nil,
            stage: nil
        )
        XCTAssertNil(RiverLetter.make(entries: [entry], captures: [], sessions: [], days: 7))
        let letter = RiverLetter.make(entries: Array(repeating: entry, count: 30), captures: [], sessions: [], days: 30)
        XCTAssertNotNil(letter)
        XCTAssertTrue(letter?.body.hasPrefix("我注意到") ?? false)
        XCTAssertTrue(letter?.body.hasSuffix("沉下来。") ?? false)
    }
}
