import AppKit
import XCTest
@testable import RiverDiaryMac

final class ActivityLifecycleTests: XCTestCase {
    @MainActor func testLastActivityIsClosedBeforeTerminationNotificationReturns() async {
        let center = NotificationCenter()
        var closed = false
        let token = ActivityLifecycle.observeTermination(center: center) { closed = true }
        defer { center.removeObserver(token) }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(closed, "An asynchronous Task can run too late to persist before process exit")
    }

    @MainActor func testRemovedObserverDoesNotAccumulateAfterRestartingTracking() async {
        let center = NotificationCenter()
        var calls = 0
        let first = ActivityLifecycle.observeTermination(center: center) { calls += 1 }
        center.removeObserver(first)
        let second = ActivityLifecycle.observeTermination(center: center) { calls += 1 }
        defer { center.removeObserver(second) }
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertEqual(calls, 1)
    }
}
