import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

/// 可移植备份的基础：本机加密快照 <-> 明文 SQLite，再回到目标机加密快照。
@MainActor
final class PortableSnapshotTests: XCTestCase {
    func testPlaintextSnapshotRoundTripsIntoAnotherEncryptedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-portable-snapshot-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = V2Store(databaseURL: directory.appendingPathComponent("source.db"))
        defer { source.close() }
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 42_000),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: "portable-snapshot")
        )
        XCTAssertTrue(source.insertRawEvent(event))

        let plaintext = try source.plaintextSnapshot()
        XCTAssertFalse(plaintext.isEmpty)
        try source.validatePlaintextSnapshot(plaintext)
        XCTAssertTrue(plaintext.starts(with: Data("SQLite format 3\0".utf8)))

        let target = V2Store(databaseURL: directory.appendingPathComponent("target.db"))
        defer { target.close() }
        let encrypted = try target.encryptedSnapshot(fromPlaintext: plaintext)
        try target.restoreEncryptedSnapshot(encrypted)
        XCTAssertEqual(target.rawEvents(ids: [event.id]).first?.payload.locationName, "portable-snapshot")
    }

    func testLegacyPlaintextRoundTripsThroughFreshEncryptedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-portable-legacy-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = AppDatabase(databaseURL: directory.appendingPathComponent("legacy.db"))
        defer { database.close() }
        XCTAssertTrue(database.saveAIResult(
            resultKey: "portable-legacy",
            startDate: "2026-10-21",
            endDate: "2026-10-21",
            task: "query",
            model: "test",
            answer: "跨机恢复的旧库内容",
            sourceSummary: "portable"
        ))

        let plaintext = try database.plaintextSnapshot()
        try database.validatePlaintextSnapshot(plaintext)
        let encrypted = try database.encryptedSnapshot(fromPlaintext: plaintext)
        try database.restoreEncryptedSnapshot(encrypted)
        XCTAssertEqual(database.queryAIResults(startDate: "2026-10-21", endDate: "2026-10-21").first?.answer, "跨机恢复的旧库内容")
    }

    func testCorruptPlaintextIsRejectedBeforeRestore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-portable-corrupt-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V2Store(databaseURL: directory.appendingPathComponent("store.db"))
        defer { store.close() }
        XCTAssertThrowsError(try store.validatePlaintextSnapshot(Data("not-a-sqlite-db".utf8)))
    }
}
