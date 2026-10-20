import XCTest
@testable import RiverDiaryMac

final class RiverNavigationTests: XCTestCase {
    func testCatalogueExposesOnlyFivePrimaryWorkspaces() {
        let routes = RiverNavigationGroup.allCases.flatMap(\.destinations)
        XCTAssertEqual(routes, [.today, .timeline, .memory, .ask, .dailyReview])
        XCTAssertEqual(Set(routes).count, 5)
        XCTAssertTrue(routes.allSatisfy(\.isPrimaryWorkspace))
        for group in RiverNavigationGroup.allCases {
            XCTAssertFalse(group.destinations.isEmpty)
            XCTAssertTrue(group.destinations.allSatisfy { $0.group == group })
        }
    }

    func testLegacySectionsResolveToTheirContainingWorkspace() {
        XCTAssertEqual(RiverDestination.footprints.workspaceRoot, .timeline)
        XCTAssertEqual(RiverDestination.health.workspaceRoot, .timeline)
        XCTAssertEqual(RiverDestination.workLearn.workspaceRoot, .timeline)
        for route in [RiverDestination.confirmations, .habitReview, .progress] {
            XCTAssertEqual(route.workspaceRoot, .dailyReview)
            XCTAssertTrue(route.sections.contains(route))
        }
        XCTAssertEqual(RiverDestination.timeline.sections, [.timeline, .footprints, .health])
        XCTAssertFalse(RiverDestination.sources.isPrimaryWorkspace)
        XCTAssertFalse(RiverDestination.database.isPrimaryWorkspace)
    }

    func testHistoryStopsAtBothEndsAndIgnoresRepeatedSelection() {
        var history = RiverNavigationHistory()
        XCTAssertNil(history.back())
        XCTAssertNil(history.forward())
        history.visit(.today)
        history.visit(.memory)
        history.visit(.memory)
        XCTAssertEqual(history.entries, [.today, .memory])
        XCTAssertEqual(history.back(), .today)
        XCTAssertNil(history.back())
        XCTAssertEqual(history.forward(), .memory)
        XCTAssertNil(history.forward())
    }

    func testNewDestinationAfterGoingBackDiscardsForwardBranch() {
        var history = RiverNavigationHistory()
        history.visit(.timeline)
        history.visit(.ask)
        XCTAssertEqual(history.back(), .timeline)
        history.visit(.health)
        XCTAssertEqual(history.entries, [.today, .timeline, .health])
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(), .timeline)
        // The view reports the destination change after a history traversal.
        // Recording that same current page must preserve the forward branch.
        history.visit(.timeline)
        XCTAssertEqual(history.forward(), .health)
    }

    func testLongSessionKeepsBoundedHistoryAndCanTraverseAllRetainedPages() {
        var history = RiverNavigationHistory()
        for index in 0..<220 { history.visit(index.isMultiple(of: 2) ? .ask : .memory) }
        XCTAssertEqual(history.entries.count, 100)
        XCTAssertEqual(history.current, .memory)
        var traversed = 0
        while history.back() != nil { traversed += 1 }
        XCTAssertEqual(traversed, 99)
        XCTAssertTrue(history.canGoForward)
    }
}
