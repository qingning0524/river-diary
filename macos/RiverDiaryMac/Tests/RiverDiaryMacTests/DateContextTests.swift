import XCTest
@testable import RiverDiaryMac

final class DateContextTests: XCTestCase {
    @MainActor
    func testDirectDateSelectionPersistsAcrossStoreReloads() {
        let suiteName = "river-date-context-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let selected = Date(timeIntervalSince1970: 1_758_153_600)
        let store = DateContextStore(defaults: defaults)

        store.setSelectedDate(selected)

        let reloaded = DateContextStore(defaults: defaults)
        XCTAssertEqual(reloaded.selectedDate, selected)
        XCTAssertTrue(reloaded.canMoveForward)
    }

    func testMoveDayChangesOnlySelectedDate() {
        let calendar = Calendar(identifier: .gregorian)
        let base = calendar.date(from: DateComponents(year: 2025, month: 9, day: 1, hour: 12))!
        var context = DateContext(selectedDate: base)

        context.moveDay(1, now: calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!)

        let expected = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: base))!
        XCTAssertEqual(calendar.startOfDay(for: context.selectedDate), expected)
    }

    func testGoTodayResetsDate() {
        var context = DateContext(selectedDate: Date(timeIntervalSince1970: 0))

        context.goToday()

        XCTAssertTrue(context.isToday)
    }

    func testForwardNavigationClampsToTodayInsteadOfOpeningFutureDate() {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        var context = DateContext(selectedDate: yesterday)

        context.moveDay(1, now: now)

        XCTAssertEqual(calendar.startOfDay(for: context.selectedDate), today)
        XCTAssertFalse(context.canMoveForward)
    }

    func testForwardNavigationFromTodayDoesNotMoveIntoFuture() {
        let today = Calendar.current.startOfDay(for: Date())
        var context = DateContext(selectedDate: today)

        context.moveDay(1)

        XCTAssertEqual(Calendar.current.startOfDay(for: context.selectedDate), today)
        XCTAssertFalse(context.canMoveForward)
    }
}
