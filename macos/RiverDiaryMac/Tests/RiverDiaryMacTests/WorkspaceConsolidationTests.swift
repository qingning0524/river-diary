import XCTest
@testable import RiverDiaryMac

final class WorkspaceConsolidationTests: XCTestCase {
    private func entry() throws -> DiaryEntry {
        try JSONDecoder().decode(DiaryEntry.self, from: Data(#"{"page_id":"diary-test","date":"2026-10-15","overview":"简短概览","daily":"正文独有词：海边散步与 Café","memos":["一条快记"],"tags":["旅行"]}"#.utf8))
    }

    func testCommandSearchFindsBodyOnlyTermAndAllPersistedWritingFields() throws {
        let item = try entry()
        for query in ["海边散步", "简短概览", "一条快记", "旅行", "2026-10-15", "  海边散步  ", "cafe"] {
            XCTAssertEqual(CommandPaletteArchiveSearch.matches(entries: [item], query: query).map(\.id), [item.id], query)
        }
        XCTAssertTrue(CommandPaletteArchiveSearch.matches(entries: [item], query: "不存在").isEmpty)
        XCTAssertTrue(CommandPaletteArchiveSearch.matches(entries: [item], query: "   ").isEmpty)
    }

    private func timeline() -> ActivityTimeline {
        let day = DiaryEntry.dateFormatter.date(from: "2026-10-15")!
        let session = ActivitySession(appName: "Unknown", bundleID: "test.unknown", windowTitle: nil,
                                      category: "其他", start: day.addingTimeInterval(36000), end: day.addingTimeInterval(39600))
        return ActivityTimelineEngine.build(for: day, sessions: [session], grouped: false)
    }

    func testDayQueueExcludesTheSameTargetAlreadyInTheSharedCentre() throws {
        let model = timeline()
        let target = try XCTUnwrap(model.foldedItems.first { $0.kind == .activity })
        XCTAssertTrue(target.needsReview)
        XCTAssertEqual(DayReviewQueue.items(in: model, clarificationIDs: [], excluding: []).map(\.id), [target.id])
        XCTAssertTrue(DayReviewQueue.items(in: model, clarificationIDs: [], excluding: [target.id]).isEmpty)
        if let key = target.annotationKey {
            XCTAssertTrue(DayReviewQueue.items(in: model, clarificationIDs: [], excluding: [key]).isEmpty)
        }
    }

    func testDayQueueNeverPromotesGapsOrEmptyDayToReviewWork() {
        let day = Date()
        let model = ActivityTimelineEngine.build(for: day, sessions: [])
        XCTAssertTrue(DayReviewQueue.items(in: model, clarificationIDs: [], excluding: []).isEmpty)
        XCTAssertTrue(DayReviewQueue.items(in: timeline(), clarificationIDs: [], excluding: [], limit: 0).isEmpty)
    }
}
