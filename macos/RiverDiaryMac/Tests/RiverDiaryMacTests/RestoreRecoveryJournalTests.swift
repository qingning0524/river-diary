import Foundation
import SQLCipher
import XCTest
@testable import RiverDiaryMac

final class RestoreRecoveryJournalTests: XCTestCase {
    @MainActor
    func testStartupRecoveryRestoresAllLocalComponentsFromDurableJournal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-restore-journal-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        let activity = support.appendingPathComponent("Activity", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: activity)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "river-restore-journal-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let day = DiaryEntry.dateFormatter.date(from: "2026-09-20")!
        let oldSession = ActivitySession(
            appName: "BEFORE-RESTORE",
            bundleID: "com.example.before",
            windowTitle: nil,
            category: "other",
            start: day.addingTimeInterval(60),
            end: day.addingTimeInterval(120)
        )
        let stateURL = support.appendingPathComponent("journal.state")
        let restoredDataURL = support.appendingPathComponent("RestoredBackup.json")
        let oldState = try StateEncryption.encrypt(Data("old encrypted state".utf8))
        let oldRestoredData = Data("old imported data".utf8)
        try Data("new state written before interruption".utf8).write(to: stateURL)
        try Data("partial import".utf8).write(to: restoredDataURL)
        try Data("partial activity".utf8).write(to: activity.appendingPathComponent("partial.activity"))
        defaults.set("new-source.json", forKey: "externalSnapshotPath")
        defaults.set(false, forKey: "activity.enabled")

        let payload = RestoreRecoveryPayload(
            activitySessions: [oldSession],
            trackingEnabled: true,
            externalSourcePath: "old-source.json",
            journalState: RestoreRecoveryFile(existed: true, contents: oldState),
            restoredData: RestoreRecoveryFile(existed: true, contents: oldRestoredData)
        )
        try RestoreRecoveryJournal.write(payload, in: support)

        XCTAssertTrue(try RestoreRecoveryJournal.recoverIfNeeded(
            supportDirectory: support,
            activityDirectory: activity,
            userDefaults: defaults
        ))

        XCTAssertEqual(try Data(contentsOf: stateURL), oldState)
        XCTAssertEqual(try Data(contentsOf: restoredDataURL), oldRestoredData)
        XCTAssertEqual(defaults.string(forKey: "externalSnapshotPath"), "old-source.json")
        XCTAssertTrue(defaults.bool(forKey: "activity.enabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activity.appendingPathComponent("partial.activity").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activity.appendingPathComponent("\(oldSession.dayKey).activity").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RestoreRecoveryJournal.journalURL(in: support).path))
    }

    @MainActor
    func testFailedStartupRecoveryKeepsJournalAndDoesNotPartiallyRestoreLocalFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-restore-journal-retry-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        let activity = support.appendingPathComponent("Activity", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: activity)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = support.appendingPathComponent("journal.state")
        let currentState = Data("current state must remain".utf8)
        try currentState.write(to: stateURL)
        let payload = RestoreRecoveryPayload(
            legacyDatabaseSnapshot: Data("invalid encrypted database".utf8),
            journalState: RestoreRecoveryFile(existed: false, contents: nil),
            restoredData: RestoreRecoveryFile(existed: false, contents: nil)
        )
        try RestoreRecoveryJournal.write(payload, in: support)

        XCTAssertThrowsError(try RestoreRecoveryJournal.recoverIfNeeded(
            supportDirectory: support,
            activityDirectory: activity
        ))
        XCTAssertEqual(try Data(contentsOf: stateURL), currentState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RestoreRecoveryJournal.journalURL(in: support).path))
    }

    @MainActor
    func testRecoveryBootstrapKeepsDataGateClosedAndJournalAvailableForRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-restore-gate-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: support)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "river-restore-gate-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stateURL = support.appendingPathComponent("journal.state")
        let currentState = Data("current data stays closed".utf8)
        try currentState.write(to: stateURL)
        try RestoreRecoveryJournal.write(
            RestoreRecoveryPayload(
                legacyDatabaseSnapshot: Data("invalid snapshot".utf8),
                journalState: RestoreRecoveryFile(existed: false, contents: nil),
                restoredData: RestoreRecoveryFile(existed: false, contents: nil)
            ),
            in: support
        )

        let bootstrap = RestoreRecoveryBootstrap(supportDirectory: support, userDefaults: defaults)
        let initialError = try XCTUnwrap(bootstrap.error)
        XCTAssertFalse(initialError.isEmpty)
        bootstrap.retry()

        XCTAssertEqual(bootstrap.error, initialError)
        XCTAssertEqual(try Data(contentsOf: stateURL), currentState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RestoreRecoveryJournal.journalURL(in: support).path))
    }

    @MainActor
    func testStartupRecoveryRestoresLegacyAndV2CiphertextSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-restore-journal-databases-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        let databaseDirectory = root.appendingPathComponent("Database", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: support)
        try LocalStorageProtection.ensurePrivateDirectory(at: databaseDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "river-restore-journal-db-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let oldLegacyURL = root.appendingPathComponent("old-legacy.db")
        let oldV2URL = root.appendingPathComponent("old-v2.db")
        let oldLegacyMarker = "OLD-LEGACY-RECOVERY"
        let oldV2Marker = "OLD-V2-RECOVERY"
        let oldLegacySnapshot: Data
        let oldV2Snapshot: Data
        do {
            let legacy = AppDatabase(databaseURL: oldLegacyURL)
            XCTAssertTrue(insertLegacyNote(oldLegacyMarker, into: legacy))
            let facts = V2Store(databaseURL: oldV2URL)
            let event = RawEvent(
                timestamp: Date(timeIntervalSince1970: 42_000),
                source: .location,
                kind: .locationUpdate,
                payload: RawEventPayload(locationName: oldV2Marker)
            )
            XCTAssertTrue(facts.insertRawEvent(event))
            oldLegacySnapshot = try legacy.encryptedSnapshot()
            oldV2Snapshot = try facts.encryptedSnapshot()
            legacy.close()
            facts.close()
        }

        let legacyURL = databaseDirectory.appendingPathComponent("river-diary.db")
        let v2URL = databaseDirectory.appendingPathComponent("river-v2.db")
        do {
            let legacy = AppDatabase(databaseURL: legacyURL)
            XCTAssertTrue(insertLegacyNote("NEW-LEGACY-PARTIAL-RESTORE", into: legacy))
            let facts = V2Store(databaseURL: v2URL)
            let event = RawEvent(
                timestamp: Date(timeIntervalSince1970: 43_000),
                source: .location,
                kind: .locationUpdate,
                payload: RawEventPayload(locationName: "NEW-V2-PARTIAL-RESTORE")
            )
            XCTAssertTrue(facts.insertRawEvent(event))
            legacy.close()
            facts.close()
        }

        try RestoreRecoveryJournal.write(
            RestoreRecoveryPayload(
                legacyDatabaseSnapshot: oldLegacySnapshot,
                v2DatabaseSnapshot: oldV2Snapshot,
                journalState: RestoreRecoveryFile(existed: false, contents: nil),
                restoredData: RestoreRecoveryFile(existed: false, contents: nil)
            ),
            in: support
        )

        XCTAssertTrue(try RestoreRecoveryJournal.recoverIfNeeded(
            supportDirectory: support,
            legacyDatabaseURL: legacyURL,
            v2DatabaseURL: v2URL,
            userDefaults: defaults
        ))

        let restoredLegacy = AppDatabase(databaseURL: legacyURL)
        let restoredFacts = V2Store(databaseURL: v2URL)
        XCTAssertEqual(try legacyNote(for: "2026-09-20", in: XCTUnwrap(restoredLegacy.db)), oldLegacyMarker)
        let events = restoredFacts.rawEvents(
            between: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 50_000)
        ).map(\.payload.locationName)
        XCTAssertTrue(events.contains(oldV2Marker))
        XCTAssertFalse(events.contains("NEW-V2-PARTIAL-RESTORE"))
        restoredLegacy.close()
        restoredFacts.close()
    }

    private func insertLegacyNote(_ title: String, into database: AppDatabase) -> Bool {
        database.transaction { handle in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "INSERT INTO daily_notes (date, title, modified_at) VALUES ('2026-09-20', '\(title)', NULL)"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    private func legacyNote(for date: String, in database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT title FROM daily_notes WHERE date = '\(date)'"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseCipherError.invalidDatabase("测试查询无法准备")
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}
