import XCTest
@testable import RiverDiary

final class RiverFootprintPresentationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)
    private func row(_ id: String, kind: IOSActivityRow.Kind, events: [UUID], source: String = "自动记录", label: String? = nil) -> IOSActivityRow {
        IOSActivityRow(id: id, date: date, title: id, detail: "生活片段", sourceLabel: source, kind: kind, eventIDs: events, placeID: nil, duration: nil, isInferred: false, timeLabel: label)
    }
    func testCurrentStoryReplacesItsRawCallbacksButKeepsOtherActivities() {
        let note = UUID(), opened = UUID(), closed = UUID()
        let rows = [row("note", kind: .note, events: [note]), row("app", kind: .app, events: [opened, closed]), row("story", kind: .riverInsight, events: [note])]
        XCTAssertEqual(Set(RiverFootprintPresentation.chronology(rows).map(\.id)), ["app", "story"])
        XCTAssertEqual(RiverFootprintPresentation.chronology(rows, filter: .note).map(\.id), ["note"])
    }
    func testPartialInterpretationCannotHideAnObservedSession() {
        let opened = UUID(), closed = UUID()
        let rows = [row("app", kind: .app, events: [opened, closed]), row("partial", kind: .riverInsight, events: [opened])]
        XCTAssertTrue(RiverFootprintPresentation.chronology(rows).contains { $0.id == "app" })
    }
    func testStaleInterpretationsAndUntimedSummariesDoNotEnterTheRail() {
        let evidence = UUID()
        let rows = [row("fact", kind: .place, events: [evidence]), row("stale", kind: .riverInsight, events: [evidence], source: "River 暂定理解 · 依据有更新"), row("health", kind: .health, events: [], label: "全天"), row("journal", kind: .note, events: [], label: "当天手记")]
        XCTAssertEqual(RiverFootprintPresentation.chronology(rows).map(\.id), ["fact"])
    }
}
