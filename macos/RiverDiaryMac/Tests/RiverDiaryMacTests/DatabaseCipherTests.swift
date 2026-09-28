import Foundation
import SQLCipher
import XCTest
@testable import RiverDiaryMac

final class DatabaseCipherTests: XCTestCase {
    func testPlaintextDatabaseMigratesToEncryptedAndRemainsReadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sqlcipher-migration-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("legacy.db")
        let marker = "PLAINTEXT-MIGRATION-SENTINEL-913B"
        try makePlaintextDatabase(at: databaseURL, marker: marker)
        XCTAssertTrue(try Data(contentsOf: databaseURL).starts(with: Data("SQLite format 3\0".utf8)))

        try DatabaseCipher.migratePlaintextDatabaseIfNeeded(at: databaseURL, key: "migration-key")

        let encrypted = try Data(contentsOf: databaseURL)
        XCTAssertFalse(encrypted.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(encrypted.range(of: Data(marker.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.appendingPathExtension("plaintext-migration").path))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        try DatabaseCipher.apply("migration-key", to: handle)
        try DatabaseCipher.validate(handle)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
    }

    func testInterruptedMigrationRestoresOriginalThenRetries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sqlcipher-recovery-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("legacy.db")
        let backupURL = databaseURL.appendingPathExtension("plaintext-migration")
        let marker = "RECOVERY-SENTINEL-A67D"
        try makePlaintextDatabase(at: databaseURL, marker: marker)
        try FileManager.default.moveItem(at: databaseURL, to: backupURL)
        try Data("partial encrypted replacement".utf8).write(to: databaseURL)

        try DatabaseCipher.migratePlaintextDatabaseIfNeeded(at: databaseURL, key: "recovery-key")

        let encrypted = try Data(contentsOf: databaseURL)
        XCTAssertFalse(encrypted.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(encrypted.range(of: Data(marker.utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        try DatabaseCipher.apply("recovery-key", to: handle)
        try DatabaseCipher.validate(handle)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
    }

    func testWrongMigrationKeyLeavesEncryptedDatabaseUntouched() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sqlcipher-wrong-key-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("facts.db")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        try DatabaseCipher.apply("right-key", to: handle)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE facts (value TEXT)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
        let originalBytes = try Data(contentsOf: databaseURL)

        XCTAssertThrowsError(try DatabaseCipher.migratePlaintextDatabaseIfNeeded(at: databaseURL, key: "wrong-key"))
        XCTAssertEqual(try Data(contentsOf: databaseURL), originalBytes)
    }

    func testLegacyAppDatabaseEncryptsPlaintextDuringStartupAndReopens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-legacy-database-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("legacy.db")
        let marker = "LEGACY-RECORD-CONFIDENTIAL-81C2"
        try makePlaintextDatabase(at: databaseURL, marker: marker)

        let legacy = AppDatabase(databaseURL: databaseURL)
        let inserted = legacy.transaction { database in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                database,
                "INSERT INTO daily_notes (date, title, modified_at) VALUES ('2026-09-22', '\(marker)', NULL)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK else { return false }
            return sqlite3_step(statement) == SQLITE_DONE
        }
        XCTAssertTrue(inserted)
        legacy.close()

        let ciphertext = try Data(contentsOf: databaseURL)
        XCTAssertFalse(ciphertext.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(ciphertext.range(of: Data(marker.utf8)))
        XCTAssertNil(ciphertext.range(of: Data("PLAINTEXT-MIGRATION-SENTINEL-913B".utf8)))

        let reopened = AppDatabase(databaseURL: databaseURL)
        let database = try XCTUnwrap(reopened.db)
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
            reopened.close()
        }
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "SELECT title FROM daily_notes WHERE date = '2026-09-22'", -1, &statement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(statement, 0).map { String(cString: $0) }, marker)
        sqlite3_finalize(statement)
        statement = nil
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "SELECT value FROM facts", -1, &statement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(statement, 0).map { String(cString: $0) }, marker)
    }

    @MainActor
    func testV2StoreEncryptsExistingPlaintextDatabaseAndPreservesRows() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-cipher-migration-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("river-v2.db")
        let marker = "V2-LEGACY-EVIDENCE-3D91"
        try makePlaintextDatabase(at: databaseURL, marker: marker)

        let store = V2Store(databaseURL: databaseURL)
        let database = try XCTUnwrap(store.db)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT value FROM facts", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_text(statement, 0).map { String(cString: $0) }, marker)

        let ciphertext = try Data(contentsOf: databaseURL)
        XCTAssertFalse(ciphertext.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(ciphertext.range(of: Data(marker.utf8)))
        XCTAssertEqual(try LocalStorageProtection.permissions(at: databaseURL), 0o600)
    }

    @MainActor
    func testEncryptedV2SnapshotRestoresAllFactTables() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-snapshot-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.db")
        let restoredURL = directory.appendingPathComponent("restored.db")
        let marker = "SNAPSHOT-PRIVATE-EVIDENCE-228A"
        let source = V2Store(databaseURL: sourceURL)
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 8_000),
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(appName: marker)
        )
        XCTAssertTrue(source.insertRawEvent(event))

        let snapshot = try source.encryptedSnapshot()
        XCTAssertFalse(snapshot.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(snapshot.range(of: Data(marker.utf8)))

        let restored = V2Store(databaseURL: restoredURL)
        XCTAssertTrue(restored.insertRawEvent(RawEvent(source: .manual, kind: .quickCapture)))
        try restored.restoreEncryptedSnapshot(snapshot)

        XCTAssertEqual(restored.countRows(in: .rawEvents), 1)
        XCTAssertEqual(restored.rawEvents(ids: [event.id]).first?.payload.appName, marker)
        let restoredBytes = try Data(contentsOf: restoredURL)
        XCTAssertNil(restoredBytes.range(of: Data(marker.utf8)))
    }

    func testLegacyEncryptedSnapshotRestoresFullDatabase() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-legacy-snapshot-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.db")
        let restoredURL = directory.appendingPathComponent("restored.db")
        let sourceMarker = "LEGACY-SNAPSHOT-SOURCE-7E31"
        let replacedMarker = "LEGACY-SNAPSHOT-REPLACED-4D22"

        let source = AppDatabase(databaseURL: sourceURL)
        XCTAssertTrue(insertLegacyNote(sourceMarker, date: "2026-09-21", into: source))
        let snapshot = try source.encryptedSnapshot()
        XCTAssertFalse(snapshot.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(snapshot.range(of: Data(sourceMarker.utf8)))

        let restored = AppDatabase(databaseURL: restoredURL)
        XCTAssertTrue(insertLegacyNote(replacedMarker, date: "2026-09-22", into: restored))
        try restored.restoreEncryptedSnapshot(snapshot)

        let database = try XCTUnwrap(restored.db)
        XCTAssertEqual(try legacyNote(for: "2026-09-21", in: database), sourceMarker)
        XCTAssertNil(try legacyNote(for: "2026-09-22", in: database))
        XCTAssertNil(try Data(contentsOf: restoredURL).range(of: Data(sourceMarker.utf8)))
    }

    @MainActor
    func testFullEncryptedBackupRestoresLegacyAndV2DatabasesTogether() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-full-database-backup-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceLegacyURL = directory.appendingPathComponent("source-legacy.db")
        let sourceV2URL = directory.appendingPathComponent("source-v2.db")
        let sourceLegacy = AppDatabase(databaseURL: sourceLegacyURL)
        let sourceV2 = V2Store(databaseURL: sourceV2URL)
        let legacyMarker = "FULL-BACKUP-LEGACY-EVIDENCE"
        let v2Marker = "FULL-BACKUP-V2-EVIDENCE"
        XCTAssertTrue(insertLegacyNote(legacyMarker, date: "2026-09-20", into: sourceLegacy))
        let rawEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 12_000),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: v2Marker)
        )
        XCTAssertTrue(sourceV2.insertRawEvent(rawEvent))

        let sourceDiary = DiaryStore(supportDirectory: directory.appendingPathComponent("source-state", isDirectory: true))
        try sourceDiary.saveDailyGoal(
            DailyGoal(title: "生成本地全库备份", isCompleted: true),
            for: DiaryEntry.dateFormatter.date(from: "2026-09-20")!
        )
        sourceDiary.saveLetterDraft("仍未正式保存的河流信草稿。", for: "2026-09")
        let backupURL = directory.appendingPathComponent("RiverDiary.riverbackup")
        try sourceDiary.exportFullBackup(
            to: backupURL,
            legacyDatabaseSnapshot: try sourceLegacy.encryptedSnapshot(),
            v2DatabaseSnapshot: try sourceV2.encryptedSnapshot()
        )

        let targetLegacy = AppDatabase(databaseURL: directory.appendingPathComponent("target-legacy.db"))
        let targetV2 = V2Store(databaseURL: directory.appendingPathComponent("target-v2.db"))
        let targetDiary = DiaryStore(supportDirectory: directory.appendingPathComponent("target-state", isDirectory: true))
        let targetLegacyBefore = try targetLegacy.encryptedSnapshot()
        let targetV2Before = try targetV2.encryptedSnapshot()
        try targetDiary.restoreFullBackup(
            from: backupURL,
            validateDatabaseSnapshots: { legacy, v2 in
                XCTAssertNotNil(legacy)
                XCTAssertNotNil(v2)
                try targetLegacy.validateEncryptedSnapshot(legacy!)
                try targetV2.validateEncryptedSnapshot(v2!)
            },
            restoreDatabaseSnapshots: { legacy, v2 in
                try targetLegacy.restoreEncryptedSnapshot(try XCTUnwrap(legacy))
                try targetV2.restoreEncryptedSnapshot(try XCTUnwrap(v2))
            },
            rollbackExternalData: {
                try targetLegacy.restoreEncryptedSnapshot(targetLegacyBefore)
                try targetV2.restoreEncryptedSnapshot(targetV2Before)
            },
            recoverySnapshot: RestoreRecoverySnapshot(
                legacyDatabaseSnapshot: targetLegacyBefore,
                v2DatabaseSnapshot: targetV2Before
            )
        )

        XCTAssertEqual(try legacyNote(for: "2026-09-20", in: try XCTUnwrap(targetLegacy.db)), legacyMarker)
        XCTAssertEqual(targetV2.rawEvents(ids: [rawEvent.id]).first?.payload.locationName, v2Marker)
        XCTAssertEqual(targetDiary.dailyGoals["2026-09-20"]?.title, "生成本地全库备份")
        XCTAssertEqual(targetDiary.letterDraft(for: "2026-09"), "仍未正式保存的河流信草稿。")
    }

    @MainActor
    func testFailedFullBackupRestoreRollsBackLegacyV2AndJournalState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-full-backup-rollback-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = "2026-09-20"
        let oldLegacyMarker = "ROLLBACK-LEGACY-OLD"
        let newLegacyMarker = "ROLLBACK-LEGACY-NEW"
        let oldV2Marker = "ROLLBACK-V2-OLD"
        let newV2Marker = "ROLLBACK-V2-NEW"

        let targetLegacy = AppDatabase(databaseURL: directory.appendingPathComponent("target-legacy.db"))
        let targetV2 = V2Store(databaseURL: directory.appendingPathComponent("target-v2.db"))
        XCTAssertTrue(insertLegacyNote(oldLegacyMarker, date: date, into: targetLegacy))
        let oldEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 20_000),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: oldV2Marker)
        )
        XCTAssertTrue(targetV2.insertRawEvent(oldEvent))
        let oldLegacySnapshot = try targetLegacy.encryptedSnapshot()
        let oldV2Snapshot = try targetV2.encryptedSnapshot()

        let sourceLegacy = AppDatabase(databaseURL: directory.appendingPathComponent("source-legacy.db"))
        let sourceV2 = V2Store(databaseURL: directory.appendingPathComponent("source-v2.db"))
        XCTAssertTrue(insertLegacyNote(newLegacyMarker, date: date, into: sourceLegacy))
        let newEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 21_000),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: newV2Marker)
        )
        XCTAssertTrue(sourceV2.insertRawEvent(newEvent))

        let sourceDiary = DiaryStore(supportDirectory: directory.appendingPathComponent("source-state", isDirectory: true))
        try sourceDiary.saveDailyGoal(DailyGoal(title: "备份目标", isCompleted: true), for: DiaryEntry.dateFormatter.date(from: date)!)
        let backupURL = directory.appendingPathComponent("rollback.riverbackup")
        try sourceDiary.exportFullBackup(
            to: backupURL,
            legacyDatabaseSnapshot: try sourceLegacy.encryptedSnapshot(),
            v2DatabaseSnapshot: try sourceV2.encryptedSnapshot()
        )

        let targetStateDirectory = directory.appendingPathComponent("target-state", isDirectory: true)
        let targetDiary = DiaryStore(supportDirectory: targetStateDirectory)
        let originalGoal = DailyGoal(title: "本地目标", isCompleted: false)
        try targetDiary.saveDailyGoal(originalGoal, for: DiaryEntry.dateFormatter.date(from: date)!)
        let originalStoredGoal = targetDiary.dailyGoals[date]
        let originalStateBytes = try Data(contentsOf: targetStateDirectory.appendingPathComponent("journal.state"))

        XCTAssertThrowsError(
            try targetDiary.restoreFullBackup(
                from: backupURL,
                validateDatabaseSnapshots: { legacy, v2 in
                    try targetLegacy.validateEncryptedSnapshot(XCTUnwrap(legacy))
                    try targetV2.validateEncryptedSnapshot(XCTUnwrap(v2))
                },
                restoreDatabaseSnapshots: { legacy, _ in
                    try targetLegacy.restoreEncryptedSnapshot(XCTUnwrap(legacy))
                    throw NSError(domain: "BackupRestoreTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "故意构造的 V2 恢复失败"])
                },
                rollbackExternalData: {
                    try targetLegacy.restoreEncryptedSnapshot(oldLegacySnapshot)
                    try targetV2.restoreEncryptedSnapshot(oldV2Snapshot)
                },
                recoverySnapshot: RestoreRecoverySnapshot(
                    legacyDatabaseSnapshot: oldLegacySnapshot,
                    v2DatabaseSnapshot: oldV2Snapshot
                )
            )
        )

        let restoredLegacy = try XCTUnwrap(targetLegacy.db)
        XCTAssertEqual(try legacyNote(for: date, in: restoredLegacy), oldLegacyMarker)
        XCTAssertNotEqual(try legacyNote(for: date, in: restoredLegacy), newLegacyMarker)
        XCTAssertEqual(targetV2.rawEvents(ids: [oldEvent.id]).first?.payload.locationName, oldV2Marker)
        XCTAssertNil(targetV2.rawEvents(ids: [newEvent.id]).first)
        XCTAssertEqual(targetDiary.dailyGoals[date], originalStoredGoal)
        XCTAssertEqual(try Data(contentsOf: targetStateDirectory.appendingPathComponent("journal.state")), originalStateBytes)
    }

    @MainActor
    func testActivityBackupRestoreStagesEncryptedFilesAndResumesTracking() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-activity-backup-restore-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "river-activity-restore-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        preferences.set(false, forKey: "activity.enabled")
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let supportDirectory = directory.appendingPathComponent("support", isDirectory: true)
        let activityDirectory = supportDirectory.appendingPathComponent("Activity", isDirectory: true)
        let factsStore = V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
        let store = ActivityStore(
            activityDirectory: activityDirectory,
            userDefaults: preferences,
            v2Store: factsStore
        )
        defer {
            if store.isTracking { store.stopTracking() }
        }

        let oldDay = DiaryEntry.dateFormatter.date(from: "2026-09-20")!
        let newDay = DiaryEntry.dateFormatter.date(from: "2026-09-21")!
        let oldSession = ActivitySession(
            appName: "旧记录",
            bundleID: "com.example.old",
            windowTitle: nil,
            category: "other",
            start: oldDay.addingTimeInterval(60),
            end: oldDay.addingTimeInterval(120)
        )
        let newSession = ActivitySession(
            appName: "RESTORE-SENTINEL-NEW",
            bundleID: "com.example.new",
            windowTitle: nil,
            category: "other",
            start: newDay.addingTimeInterval(60),
            end: newDay.addingTimeInterval(120)
        )

        try store.restoreBackup([oldSession])
        let oldFile = activityDirectory.appendingPathComponent("\(oldSession.dayKey).activity")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))

        store.startTracking(showPermissionPrompt: false)
        XCTAssertTrue(store.isTracking)
        try store.restoreBackup([newSession])

        XCTAssertTrue(store.isTracking)
        XCTAssertTrue(preferences.bool(forKey: "activity.enabled"))
        XCTAssertEqual(store.sessions.map(\.id), [newSession.id])
        let activityFiles = try FileManager.default.contentsOfDirectory(at: activityDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "activity" }
        XCTAssertEqual(activityFiles.map(\.lastPathComponent), ["\(newSession.dayKey).activity"])
        let encryptedSession = try Data(contentsOf: try XCTUnwrap(activityFiles.first))
        XCTAssertNil(encryptedSession.range(of: Data("RESTORE-SENTINEL-NEW".utf8)))

        let supportItems = try FileManager.default.contentsOfDirectory(at: supportDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(supportItems.map(\.lastPathComponent), ["Activity"])
    }

    @MainActor
    func testActivityStoreRecoversPreviousDirectoryAfterInterruptedSwap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-activity-restore-recovery-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "river-activity-recovery-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        preferences.set(false, forKey: "activity.enabled")
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let supportDirectory = directory.appendingPathComponent("support", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: supportDirectory)
        let activityDirectory = supportDirectory.appendingPathComponent("Activity", isDirectory: true)
        let interruptedPreviousDirectory = supportDirectory.appendingPathComponent("Activity-previous-interrupted", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: interruptedPreviousDirectory)

        let day = DiaryEntry.dateFormatter.date(from: "2026-09-20")!
        let session = ActivitySession(
            appName: "RECOVERY-SENTINEL",
            bundleID: "com.example.recovery",
            windowTitle: nil,
            category: "other",
            start: day.addingTimeInterval(60),
            end: day.addingTimeInterval(120)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try StateEncryption.encrypt(try encoder.encode([session]))
        let previousFile = interruptedPreviousDirectory.appendingPathComponent("\(session.dayKey).activity")
        try encrypted.write(to: previousFile, options: .atomic)
        try LocalStorageProtection.protectFile(at: previousFile)

        let factsStore = V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
        let store = ActivityStore(activityDirectory: activityDirectory, userDefaults: preferences, v2Store: factsStore)

        XCTAssertEqual(store.sessions.map(\.id), [session.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: activityDirectory.appendingPathComponent("\(session.dayKey).activity").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: interruptedPreviousDirectory.path))
    }

    func testEncryptedDatabaseRejectsWrongKeyAndContainsNoPlaintext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sqlcipher-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("facts.db")
        let key = "unit-test-key-material-not-for-user-data"
        let marker = "SQLCIPHER-PLAINTEXT-SENTINEL-4F7A1C"

        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let createdDatabase = try XCTUnwrap(database)
        try DatabaseCipher.apply(key, to: createdDatabase)
        XCTAssertEqual(
            sqlite3_exec(createdDatabase, "CREATE TABLE facts (value TEXT NOT NULL)", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(
            sqlite3_exec(createdDatabase, "INSERT INTO facts VALUES ('\(marker)')", nil, nil, nil),
            SQLITE_OK
        )
        try DatabaseCipher.validate(createdDatabase)
        XCTAssertEqual(sqlite3_close(createdDatabase), SQLITE_OK)

        let ciphertext = try Data(contentsOf: databaseURL)
        XCTAssertFalse(ciphertext.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertNil(ciphertext.range(of: Data(marker.utf8)))

        var reopened: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &reopened, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let reopenedDatabase = try XCTUnwrap(reopened)
        try DatabaseCipher.apply(key, to: reopenedDatabase)
        try DatabaseCipher.validate(reopenedDatabase)
        XCTAssertEqual(sqlite3_close(reopenedDatabase), SQLITE_OK)

        var wrongKeyDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &wrongKeyDatabase, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let wrongKeyHandle = try XCTUnwrap(wrongKeyDatabase)
        try DatabaseCipher.apply("incorrect-key", to: wrongKeyHandle)
        XCTAssertThrowsError(try DatabaseCipher.validate(wrongKeyHandle))
        XCTAssertEqual(sqlite3_close(wrongKeyHandle), SQLITE_OK)
    }

    func testWriteAheadLogDoesNotExposePlaintext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sqlcipher-wal-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("facts.db")
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let key = "wal-test-key-material"
        let marker = "WAL-PLAINTEXT-SENTINEL-65AE"

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        try DatabaseCipher.apply(key, to: handle)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE facts (value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "INSERT INTO facts VALUES ('\(marker)')", nil, nil, nil), SQLITE_OK)

        let databaseBytes = try Data(contentsOf: databaseURL)
        let walBytes = try Data(contentsOf: walURL)
        XCTAssertNil(databaseBytes.range(of: Data(marker.utf8)))
        XCTAssertNil(walBytes.range(of: Data(marker.utf8)))
        XCTAssertFalse(walBytes.starts(with: Data("SQLite format 3\0".utf8)))
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
    }

    private func makePlaintextDatabase(at url: URL, marker: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(database)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE facts (value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "INSERT INTO facts VALUES ('\(marker)')", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(handle), SQLITE_OK)
    }

    private func insertLegacyNote(_ title: String, date: String, into database: AppDatabase) -> Bool {
        database.transaction { handle in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "INSERT INTO daily_notes (date, title, modified_at) VALUES ('\(date)', '\(title)', NULL)"
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
