import XCTest
@testable import RiverDiaryMac

final class DailyGoalTests: XCTestCase {
    func testDailyGoalsRoundTripInUserStateAndBackup() throws {
        let date = "2026-09-22"
        let goal = DailyGoal(title: "推进河流日记", isCompleted: true, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let journalDraft = JournalDraftRecord(
            text: "一段尚未正式保存的日记",
            mood: 72,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let legacyDatabaseSnapshot = Data([0x52, 0x44, 0x4c, 0x31])
        let v2DatabaseSnapshot = Data([0x52, 0x44, 0x56, 0x32])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let state = UserState(dailyGoals: [date: goal], journalDrafts: [date: journalDraft])
        let restoredState = try decoder.decode(UserState.self, from: encoder.encode(state))
        XCTAssertEqual(restoredState.dailyGoals?[date], goal)
        XCTAssertEqual(restoredState.journalDrafts?[date], journalDraft)

        let backup = LocalBackupPayload(
            exportedAt: Date(),
            overrides: [:],
            quickCaptures: [:],
            dismissedDrafts: [:],
            careAcknowledgments: [:],
            dailyGoals: [date: goal],
            journalDrafts: [date: journalDraft],
            legacyDatabaseSnapshot: legacyDatabaseSnapshot,
            v2DatabaseSnapshot: v2DatabaseSnapshot
        )
        let restoredBackup = try decoder.decode(LocalBackupPayload.self, from: encoder.encode(backup))
        XCTAssertEqual(restoredBackup.dailyGoals?[date], goal)
        XCTAssertEqual(restoredBackup.journalDrafts?[date], journalDraft)
        XCTAssertEqual(restoredBackup.legacyDatabaseSnapshot, legacyDatabaseSnapshot)
        XCTAssertEqual(restoredBackup.v2DatabaseSnapshot, v2DatabaseSnapshot)
    }

    func testLegacyStateAndBackupWithoutGoalsRemainReadable() throws {
        let decoder = JSONDecoder()
        let oldState = try decoder.decode(UserState.self, from: Data(#"{"version":3,"entries":{}}"#.utf8))
        XCTAssertNil(oldState.dailyGoals)

        let legacy = LocalBackupPayload(
            exportedAt: Date(),
            overrides: [:],
            quickCaptures: [:],
            dismissedDrafts: [:],
            careAcknowledgments: [:]
        )
        XCTAssertNil(try decoder.decode(LocalBackupPayload.self, from: JSONEncoder().encode(legacy)).dailyGoals)
        XCTAssertNil(try decoder.decode(LocalBackupPayload.self, from: JSONEncoder().encode(legacy)).journalDrafts)
    }

    @MainActor
    func testEncryptedBackupRoundTripsBothDatabaseSnapshots() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-full-backup-snapshots-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backupURL = directory.appendingPathComponent("RiverDiary.riverbackup")
        let store = DiaryStore(supportDirectory: directory.appendingPathComponent("state", isDirectory: true))
        try store.saveDailyGoal(DailyGoal(title: "备份快照往返测试"), for: DiaryEntry.dateFormatter.date(from: "2026-09-22")!)
        let legacySnapshot = Data("encrypted-legacy-database-snapshot".utf8)
        let v2Snapshot = Data("encrypted-v2-database-snapshot".utf8)

        try store.exportFullBackup(
            to: backupURL,
            legacyDatabaseSnapshot: legacySnapshot,
            v2DatabaseSnapshot: v2Snapshot
        )
        let exportedBytes = try Data(contentsOf: backupURL)
        XCTAssertTrue(exportedBytes.starts(with: Data("RDMACv1\n".utf8)))
        XCTAssertNil(exportedBytes.range(of: legacySnapshot))
        XCTAssertNil(exportedBytes.range(of: v2Snapshot))

        var restoredLegacy: Data?
        var restoredV2: Data?
        try store.restoreFullBackup(
            from: backupURL,
            validateDatabaseSnapshots: { legacy, v2 in
                XCTAssertEqual(legacy, legacySnapshot)
                XCTAssertEqual(v2, v2Snapshot)
            },
            restoreDatabaseSnapshots: { legacy, v2 in
                restoredLegacy = legacy
                restoredV2 = v2
            },
            rollbackExternalData: {},
            recoverySnapshot: RestoreRecoverySnapshot(
                legacyDatabaseSnapshot: Data("previous-legacy".utf8),
                v2DatabaseSnapshot: Data("previous-v2".utf8)
            )
        )
        XCTAssertEqual(restoredLegacy, legacySnapshot)
        XCTAssertEqual(restoredV2, v2Snapshot)
    }

    @MainActor
    func testFailedActivityRestoreDoesNotCommitDiaryState() throws {
        let defaults = UserDefaults.standard
        let previousExternalSource = defaults.string(forKey: "externalSnapshotPath")
        defaults.removeObject(forKey: "externalSnapshotPath")
        defer {
            if let previousExternalSource {
                defaults.set(previousExternalSource, forKey: "externalSnapshotPath")
            } else {
                defaults.removeObject(forKey: "externalSnapshotPath")
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-backup-activity-failure-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let backupURL = directory.appendingPathComponent("activity-failure.riverbackup")
        let stateURL = stateDirectory.appendingPathComponent("journal.state")
        let date = "2026-09-22"
        let originalGoal = DailyGoal(title: "保留当前目标", isCompleted: false)
        let store = DiaryStore(supportDirectory: stateDirectory)
        try store.saveDailyGoal(originalGoal, for: DiaryEntry.dateFormatter.date(from: date)!)
        let originalStoredGoal = store.dailyGoals[date]
        let originalStateBytes = try Data(contentsOf: stateURL)

        let payload = LocalBackupPayload(
            exportedAt: Date(),
            overrides: [:],
            quickCaptures: [:],
            dismissedDrafts: [:],
            careAcknowledgments: [:],
            dailyGoals: [date: DailyGoal(title: "不应覆盖当前目标", isCompleted: true)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try StateEncryption.encrypt(try encoder.encode(payload)).write(to: backupURL, options: .atomic)

        var externalActivityState = "current activity"
        XCTAssertThrowsError(
            try store.restoreFullBackup(
                from: backupURL,
                restoreActivity: { _ in
                    externalActivityState = "partially restored activity"
                    throw NSError(domain: "BackupRestoreTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "故意构造的活动恢复失败"])
                },
                rollbackExternalData: { externalActivityState = "current activity" },
                recoverySnapshot: RestoreRecoverySnapshot(activitySessions: [])
            )
        )
        XCTAssertEqual(externalActivityState, "current activity")
        XCTAssertEqual(store.dailyGoals[date], originalStoredGoal)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalStateBytes)
    }

    @MainActor
    func testFailedDatabaseRestoreRollsBackActivityAndDiaryState() throws {
        let defaults = UserDefaults.standard
        let previousExternalSource = defaults.string(forKey: "externalSnapshotPath")
        defaults.removeObject(forKey: "externalSnapshotPath")
        defer {
            if let previousExternalSource {
                defaults.set(previousExternalSource, forKey: "externalSnapshotPath")
            } else {
                defaults.removeObject(forKey: "externalSnapshotPath")
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-backup-database-failure-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let backupURL = directory.appendingPathComponent("database-failure.riverbackup")
        let stateURL = stateDirectory.appendingPathComponent("journal.state")
        let date = "2026-09-22"
        let originalGoal = DailyGoal(title: "恢复前目标", isCompleted: false)
        let store = DiaryStore(supportDirectory: stateDirectory)
        try store.saveDailyGoal(originalGoal, for: DiaryEntry.dateFormatter.date(from: date)!)
        let originalStoredGoal = store.dailyGoals[date]
        let originalStateBytes = try Data(contentsOf: stateURL)

        let payload = LocalBackupPayload(
            exportedAt: Date(),
            overrides: [:],
            quickCaptures: [:],
            dismissedDrafts: [:],
            careAcknowledgments: [:],
            dailyGoals: [date: DailyGoal(title: "恢复中途失败", isCompleted: true)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try StateEncryption.encrypt(try encoder.encode(payload)).write(to: backupURL, options: .atomic)

        var externalActivityState = "current activity"
        var externalDatabaseState = "current databases"
        XCTAssertThrowsError(
            try store.restoreFullBackup(
                from: backupURL,
                restoreActivity: { _ in externalActivityState = "restored activity" },
                restoreDatabaseSnapshots: { _, _ in
                    externalDatabaseState = "partially restored databases"
                    throw NSError(domain: "BackupRestoreTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "故意构造的数据库恢复失败"])
                },
                rollbackExternalData: {
                    externalActivityState = "current activity"
                    externalDatabaseState = "current databases"
                },
                recoverySnapshot: RestoreRecoverySnapshot(
                    activitySessions: [],
                    legacyDatabaseSnapshot: Data("previous-legacy".utf8),
                    v2DatabaseSnapshot: Data("previous-v2".utf8)
                )
            )
        )

        XCTAssertEqual(externalActivityState, "current activity")
        XCTAssertEqual(externalDatabaseState, "current databases")
        XCTAssertEqual(store.dailyGoals[date], originalStoredGoal)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalStateBytes)
    }

    @MainActor
    func testInvalidDatabaseSnapshotDoesNotMutateCurrentBackupState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-backup-reject-invalid-db-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let backupURL = directory.appendingPathComponent("invalid.riverbackup")
        let date = "2026-09-22"
        let originalGoal = DailyGoal(title: "保留当前目标", isCompleted: false)
        let store = DiaryStore(supportDirectory: stateDirectory)
        try store.saveDailyGoal(originalGoal, for: DiaryEntry.dateFormatter.date(from: date)!)
        let originalStoredGoal = store.dailyGoals[date]
        let stateURL = stateDirectory.appendingPathComponent("journal.state")
        let originalStateBytes = try Data(contentsOf: stateURL)

        let payload = LocalBackupPayload(
            exportedAt: Date(),
            overrides: [:],
            quickCaptures: [:],
            dismissedDrafts: [:],
            careAcknowledgments: [:],
            dailyGoals: [date: DailyGoal(title: "不应覆盖当前目标", isCompleted: true)],
            legacyDatabaseSnapshot: Data("corrupt-legacy-snapshot".utf8),
            v2DatabaseSnapshot: Data("corrupt-v2-snapshot".utf8)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try StateEncryption.encrypt(try encoder.encode(payload)).write(to: backupURL, options: .atomic)

        var didAttemptRestoreSnapshots = false
        XCTAssertThrowsError(
            try store.restoreFullBackup(
                from: backupURL,
                validateDatabaseSnapshots: { _, _ in
                    throw DatabaseCipherError.invalidDatabase("故意构造的无效快照")
                },
                restoreDatabaseSnapshots: { _, _ in
                    didAttemptRestoreSnapshots = true
                }
            )
        )
        XCTAssertFalse(didAttemptRestoreSnapshots)
        XCTAssertEqual(store.dailyGoals[date], originalStoredGoal)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalStateBytes)
    }

    @MainActor
    func testDailyGoalPersistsAndReloadsFromEncryptedLocalState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-daily-goal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = DiaryEntry.dateFormatter.date(from: "2026-09-22")!
        let store = DiaryStore(supportDirectory: directory)
        let goal = DailyGoal(title: "推进一个可演示流程", isCompleted: false)

        try store.saveDailyGoal(goal, for: date)

        XCTAssertEqual(store.dailyGoal(for: date)?.title, goal.title)
        XCTAssertTrue(store.isEncrypted)
        let restored = DiaryStore(supportDirectory: directory)
        XCTAssertEqual(restored.dailyGoal(for: date)?.title, goal.title)
        XCTAssertFalse(restored.dailyGoal(for: date)?.isCompleted ?? true)
    }

    @MainActor
    func testJournalDraftIsEncryptedAndRestoredAcrossEditorRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-journal-draft-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = "2026-09-22"
        let entry = DiaryEntry(pageID: "local-\(date)", date: date)
        let originalText = "跨重启草稿恢复回归测试"
        let store = DiaryStore(supportDirectory: directory)
        let editor = JournalEditorStore()
        editor.attach(to: store)

        editor.edit(entry, text: originalText, mood: 72)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(store.journalDrafts[date]?.text, originalText)
        XCTAssertEqual(store.journalDrafts[date]?.mood, 72)
        XCTAssertEqual(editor.persistenceStatus[date], "草稿已加密保存在本机")
        let encryptedState = try Data(contentsOf: directory.appendingPathComponent("journal.state"))
        XCTAssertFalse(String(data: encryptedState, encoding: .utf8)?.contains(originalText) ?? false)

        let restartedStore = DiaryStore(supportDirectory: directory)
        let restartedEditor = JournalEditorStore()
        restartedEditor.attach(to: restartedStore)
        XCTAssertEqual(restartedEditor.buffer(for: entry).text, originalText)
        XCTAssertEqual(restartedEditor.buffer(for: entry).mood, 72)
        XCTAssertTrue(restartedEditor.buffer(for: entry).isDirty)

        try restartedStore.saveWriting(entry: entry, text: originalText, mood: 72)
        restartedEditor.saved(date)
        XCTAssertNil(restartedStore.journalDrafts[date])
        XCTAssertFalse(restartedEditor.hasUnsavedChanges)

        try restartedStore.saveJournalDraft(
            JournalDraftRecord(text: "待丢弃草稿", mood: nil, updatedAt: Date()),
            for: date
        )
        XCTAssertEqual(restartedEditor.buffer(for: entry).text, "待丢弃草稿")
        restartedEditor.discarded(date)
        XCTAssertNil(restartedStore.journalDrafts[date])
        XCTAssertFalse(restartedEditor.hasUnsavedChanges)
        XCTAssertNil(DiaryStore(supportDirectory: directory).journalDrafts[date])
    }

    @MainActor
    func testJournalDraftPersistenceFailureKeepsTextEditable() async throws {
        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-journal-draft-failure-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: invalidDirectory)
        defer { try? FileManager.default.removeItem(at: invalidDirectory) }

        let date = "2026-09-22"
        let entry = DiaryEntry(pageID: "local-\(date)", date: date)
        let store = DiaryStore(supportDirectory: invalidDirectory)
        let editor = JournalEditorStore()
        editor.attach(to: store)
        let draftText = "磁盘写入失败时仍保留在编辑器中的内容"

        editor.edit(entry, text: draftText)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(editor.buffer(for: entry).text, draftText)
        XCTAssertTrue(editor.buffer(for: entry).isDirty)
        XCTAssertTrue(editor.persistenceStatus[date]?.contains("失败") == true)
        XCTAssertNil(store.journalDrafts[date])
    }
}
