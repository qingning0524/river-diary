import CoreLocation
import RiverDiaryCore
import XCTest
@testable import RiverDiary

@MainActor
final class RiverLocationLifecycleTests: XCTestCase {
    func testDisabledAndSignedOutCallbacksCannotWriteLocationEvents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "location-lifecycle-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let db = try RiverLocalDatabase(databaseURL: folder.appendingPathComponent("node.sqlite"),
                                        testDeviceID: RiverDeviceID(rawValue: "location-lifecycle-test"))
        let collector = IPhoneLocationCollector(database: db, mapProvider: EmptyPlaceProvider(), preferences: preferences)
        let sample = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: Date())
        collector.handleLocationUpdates([sample])
        XCTAssertEqual(try db.allEvents().count, 0)
        // Enabling the stored preference must not override the signed-out state.
        collector.setSessionActive(false)
        collector.setEnabled(true)
        collector.handleLocationUpdates([sample])
        XCTAssertEqual(try db.allEvents().count, 0)
        XCTAssertTrue(preferences.bool(forKey: "river.location.enabled"))
        collector.setSessionActive(false)
    }
}

@MainActor
private struct EmptyPlaceProvider: MapPlaceProvider {
    func candidates(for location: CLLocation) async throws -> [RiverPlaceCandidate] { [] }
}
