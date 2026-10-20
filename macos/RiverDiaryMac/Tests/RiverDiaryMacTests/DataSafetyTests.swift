import XCTest
@testable import RiverDiaryMac

/// Regression tests for the 2026-09-25 data-safety wave:
/// transient text bindings, corrupt-day-file quarantine, sibling-connection
/// reopen after a V2 snapshot restore, and store rollback on persist failure.
@MainActor
final class DataSafetyTests: XCTestCase {

    private func makeTempDirectory(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: dir)
        return dir
    }

    /// ActivityStore 会保护传入目录的父目录并读取 activity.enabled 偏好；
    /// 测试需要外层 support 目录 + 隔离的 UserDefaults 才不会碰到真实环境。
    private func makeActivityStore(_ prefix: String) throws -> (ActivityStore, URL, V2Store) {
        let outer = try makeTempDirectory(prefix)
        let preferences = UserDefaults(suiteName: "\(prefix)-\(UUID().uuidString)")!
        preferences.set(false, forKey: "activity.enabled")
        let factsStore = V2Store(databaseURL: outer.appendingPathComponent("facts.db"))
        let activityDirectory = outer.appendingPathComponent("Activity")
        return (
            ActivityStore(activityDirectory: activityDirectory, userDefaults: preferences, v2Store: factsStore),
            activityDirectory,
            factsStore
        )
    }

    // MARK: G1 — legacy database text bindings

    /// SQLITE_TRANSIENT round-trip: long, multi-byte text must survive the
    /// bind→step gap. (With the old SQLITE_STATIC binds the buffer could be
    /// freed before SQLite read it.)
    func testLegacyDatabaseRoundTripsLongUnicodeText() throws {
        let dir = try makeTempDirectory("river-g1-db")
        let db = AppDatabase(databaseURL: dir.appendingPathComponent("legacy.db"))
        defer { db.close() }

        let longAnswer = String(repeating: "证据河流🌊—", count: 1_500)
        let saved = db.saveAIResult(
            resultKey: "roundtrip-1",
            startDate: "2026-09-01",
            endDate: "2026-09-30",
            task: "query",
            model: "test-model",
            answer: longAnswer,
            sourceSummary: "混入 emoji 🧪 与 ASCII mixed 総合 test"
        )
        XCTAssertTrue(saved, "saveAIResult 失败：\(db.lastError ?? "未知错误")")

        let results = db.queryAIResults(startDate: "2026-09-01", endDate: "2026-09-30")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.answer, longAnswer)

        // Also exercise the daily-record write path with unicode payloads.
        let capture = DailyCaptureRecord(
            date: "2026-09-25",
            capturedAt: Date(),
            iosDataAvailable: true,
            moodScore: 7,
            sleepHours: nil,
            sleepDeepMinutes: nil,
            sleepREMMinutes: nil,
            exerciseSteps: 4_000,
            exerciseDistanceKM: nil,
            exerciseEnergyKcal: nil,
            quickNotes: [IngestedQuickNote(
                id: "note-1",
                date: "2026-09-25",
                text: "情绪低落的一天，但完成了 📚 学习计划。",
                createdAt: Date(),
                source: "iOS 快记"
            )],
            chromeVisits: [],
            chromeTotalVisits: 0,
            chromeTopDomains: [],
            notesModified: [],
            screenTimeMinutes: 120,
            screenTopApps: [],
            mixedOverview: String(repeating: "概述・①", count: 800)
        )
        XCTAssertTrue(
            db.saveDailyCapture(capture, sessions: []),
            "saveDailyCapture 失败：\(db.lastError ?? "未知错误")"
        )
    }

    // MARK: G2 — corrupt day files are quarantined, never deleted

    func testCorruptActivityDayFileIsQuarantinedNotDeleted() throws {
        let (_, activityDirectory, factsStore) = try makeActivityStore("river-g2-activity")
        let dayKey = ActivitySession.dayKey(for: Date())
        let dayFile = activityDirectory.appendingPathComponent("\(dayKey).activity")
        try FileManager.default.createDirectory(at: activityDirectory, withIntermediateDirectories: true)
        try Data("这 definitely 不是有效的加密数据".utf8).write(to: dayFile)

        let store = ActivityStore(activityDirectory: activityDirectory, v2Store: factsStore)

        XCTAssertTrue(FileManager.default.fileExists(atPath: dayFile.appendingPathExtension("corrupt").path),
                      "损坏文件应被隔离为 .corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dayFile.path),
                       "原文件应已被改名隔离，而不是被静默清空")
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.storageSummary.contains("无法解密"), "状态应向用户解释隔离事件：\(store.storageSummary)")
    }

    func testValidActivityFilesSurviveQuarantineAndLoad() throws {
        let (store, activityDirectory, factsStore) = try makeActivityStore("river-g2b-activity")

        let recent = ActivitySession(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: nil,
            category: "学习",
            start: Date().addingTimeInterval(-3_600), end: Date()
        )
        let ancient = ActivitySession(
            appName: "Safari", bundleID: "com.apple.Safari", windowTitle: nil,
            category: "浏览",
            start: Date().addingTimeInterval(-400 * 24 * 3_600), end: Date().addingTimeInterval(-400 * 24 * 3_600 + 600)
        )
        try store.restoreBackup([recent, ancient])

        let reloader = ActivityStore(activityDirectory: activityDirectory, v2Store: factsStore)
        XCTAssertEqual(reloader.sessions.count, 1, "超过 365 天的片段应被保留期清理，其余保留")
        XCTAssertEqual(reloader.sessions.first?.appName, "Xcode")
    }

    // MARK: G3 — V2 snapshot restore must rebind sibling connections

    func testV2RestoreReopensSiblingConnectionsOntoRestoredFile() throws {
        let dir = try makeTempDirectory("river-g3-v2")
        let url = dir.appendingPathComponent("river-v2.db")
        let writer = V2Store(databaseURL: url)
        let restorer = V2Store(databaseURL: url)
        defer { writer.close(); restorer.close() }

        let event1 = RawEvent(
            timestamp: Date(), source: .ingestion, kind: .ingestionSnapshot,
            payload: RawEventPayload(text: "恢复前"), sourceHash: "h1"
        )
        XCTAssertTrue(writer.insertRawEvent(event1))

        let snapshot = try writer.encryptedSnapshot()
        try restorer.restoreEncryptedSnapshot(snapshot)

        // The sibling connection was pointing at the replaced inode; the
        // registry must have reopened it onto the restored file.
        let event2 = RawEvent(
            timestamp: Date().addingTimeInterval(60), source: .ingestion, kind: .ingestionSnapshot,
            payload: RawEventPayload(text: "恢复后"), sourceHash: "h2"
        )
        XCTAssertTrue(writer.insertRawEvent(event2), "恢复后兄弟连接的写入应成功")

        let verifier = V2Store(databaseURL: url)
        defer { verifier.close() }
        XCTAssertEqual(verifier.countRows(in: .rawEvents), 2,
                       "恢复前的证据与恢复后经兄弟连接写入的事件都必须落在新文件里")
        XCTAssertEqual(writer.rawEvents(between: Date().addingTimeInterval(-3_600), end: Date().addingTimeInterval(3_600)).count, 2)
    }

    // MARK: G4 — store mutations roll back when persist fails

    func testRemoveSavedQueryRollsBackWhenPersistFails() throws {
        let dir = try makeTempDirectory("river-g4-state")
        let store = DiaryStore(supportDirectory: dir)

        let query = SavedQuery(name: "最近的学习", query: "这周学了什么", days: 30)
        try store.saveSavedQuery(query)
        XCTAssertEqual(store.savedQueries.count, 1)

        // 拒绝写入：把状态目录设为只读（去掉写权限）。
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        store.removeSavedQuery(query)

        // 恢复权限，保证清理与后续断言可执行。
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        XCTAssertEqual(store.savedQueries.count, 1, "持久化失败时内存删除必须回滚")
        guard case .failed = store.saveState else {
            return XCTFail("失败必须呈现给用户，实际状态：\(store.saveState)")
        }
    }
}
