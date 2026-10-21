import Foundation
import RiverDiaryCore
import XCTest
@testable import RiverDiary

@MainActor
final class IPhoneDayContextBuilderTests: XCTestCase {
    func testBuildsSectionsFromIPhoneEvents() throws {
        let database = try makeDatabase()
        let now = Date()
        _ = try database.append(
            source: "healthkit", kind: "health.sleep.snapshot",
            payload: RiverEventPayload(metrics: RiverEventMetrics(sleepHours: 7.2)),
            observedAt: now
        )
        _ = try database.append(
            source: "healthkit", kind: "health.workout",
            payload: RiverEventPayload(text: "跑步", metrics: RiverEventMetrics(durationMinutes: 30)),
            observedAt: now
        )
        _ = try database.append(
            source: "healthkit", kind: "health.stateOfMind",
            payload: RiverEventPayload(text: "今日心情", metrics: RiverEventMetrics(valence: 0.4)),
            observedAt: now
        )
        _ = try database.append(
            source: "shortcuts", kind: "screenTime.daily",
            payload: RiverEventPayload(metrics: RiverEventMetrics(screenMinutes: 120)),
            observedAt: now
        )
        _ = try database.append(
            source: "shortcuts", kind: "manual.voiceMemo",
            payload: RiverEventPayload(text: "今天去了河边。"),
            observedAt: now
        )
        _ = try database.append(
            source: "shortcuts", kind: "app.opened",
            payload: RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode"),
            observedAt: now
        )
        _ = try database.append(
            source: "manual", kind: "manual.note",
            payload: RiverEventPayload(text: "记得买咖啡豆。"),
            observedAt: now
        )

        let snapshot = try XCTUnwrap(IPhoneDayContextBuilder.build(
            database: database,
            deviceID: "iphone-test",
            deviceName: "测试 iPhone",
            day: now
        ))
        let kinds = Set(snapshot.sections.map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: ["health", "workout", "stateOfMind", "screenTime", "voice", "apps", "notes"]))
        XCTAssertEqual(snapshot.deviceName, "测试 iPhone")
        XCTAssertTrue(snapshot.summaryLine.contains("睡眠"))
    }

    func testPublishWritesStableContextEvent() throws {
        let database = try makeDatabase()
        _ = try database.append(
            source: "healthkit", kind: "health.sleep.snapshot",
            payload: RiverEventPayload(metrics: RiverEventMetrics(sleepHours: 6.5)),
            observedAt: Date()
        )

        IPhoneDayContextBuilder.publish(database: database, deviceName: "测试 iPhone")
        IPhoneDayContextBuilder.publish(database: database, deviceName: "测试 iPhone")

        let contexts = try database.allEvents().filter { $0.kind == "dayContextSnapshot" }
        XCTAssertEqual(contexts.count, 1)
        let payload = try JSONDecoder().decode(RiverEventPayload.self, from: contexts[0].payload)
        let json = try XCTUnwrap(payload.contextJSON)
        let snapshot = try XCTUnwrap(DayContextSnapshot.decodeJSON(json))
        XCTAssertEqual(snapshot.deviceName, "测试 iPhone")
        XCTAssertEqual(snapshot.deviceID, "iphone-test")
    }

    private func makeDatabase() throws -> RiverLocalDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-iphone-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RiverLocalDatabase(
            databaseURL: directory.appendingPathComponent("river-node.sqlite"),
            testDeviceID: RiverDeviceID(rawValue: "iphone-test")
        )
    }
}
