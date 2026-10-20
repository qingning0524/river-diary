import XCTest
@testable import RiverDiaryMac

@MainActor
final class AccountCollectionLifecycleTests: XCTestCase {
    func testSignedOutStartupAndPausePreserveCollectionPreference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "account-collection-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        preferences.set(true, forKey: "activity.enabled")
        let facts = V2Store(databaseURL: root.appendingPathComponent("facts.sqlite"))
        let store = ActivityStore(activityDirectory: root.appendingPathComponent("activity"), userDefaults: preferences,
                                  v2Store: facts, startsAutomatically: false)
        XCTAssertFalse(store.isTracking)
        XCTAssertTrue(preferences.bool(forKey: "activity.enabled"))
        store.startTracking(showPermissionPrompt: false)
        XCTAssertFalse(store.isTracking, "A queued start action cannot collect after sign out")
        store.setAccountServicesActive(true)
        XCTAssertTrue(store.isTracking)
        store.setAccountServicesActive(false)
        XCTAssertFalse(store.isTracking)
        XCTAssertTrue(preferences.bool(forKey: "activity.enabled"))
        store.setAccountServicesActive(true)
        XCTAssertTrue(store.isTracking)
        store.setAccountServicesActive(false)
    }
}
