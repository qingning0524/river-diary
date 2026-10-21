import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

/// D07 跨 Mac 恢复演练：用恢复码封装的 journal + 明文数据库，
/// 在目标 Mac 上重新加密后走现有恢复流程。
@MainActor
final class PortableBackupTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-portable-backup-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        return directory
    }

    func testPortableArchiveRestoresIntoCleanMacState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try XCTUnwrap(DiaryEntry.dateFormatter.date(from: "2026-10-21"))

        let sourceDiary = DiaryStore(supportDirectory: directory.appendingPathComponent("source-state", isDirectory: true))
        let sourceEntry = sourceDiary.entry(for: day)
        try sourceDiary.saveWriting(entry: sourceEntry, text: "从另一台 Mac 恢复的文字。", mood: 7)
        XCTAssertTrue(sourceDiary.addQuickCapture("可移植快记", for: day))

        let sourceV2 = V2Store(databaseURL: directory.appendingPathComponent("source-v2.db"))
        defer { sourceV2.close() }
        let event = RawEvent(
            timestamp: day,
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: "portable-place")
        )
        XCTAssertTrue(sourceV2.insertRawEvent(event))

        let key = SyncEncryptionKey()
        let journalPayload = try sourceDiary.makeBackupPayload()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let portable = try PortableBackupArchive.seal(
            journal: try encoder.encode(journalPayload),
            legacyDatabasePlaintext: nil,
            v2DatabasePlaintext: try sourceV2.plaintextSnapshot(),
            using: key
        )

        XCTAssertThrowsError(try PortableBackupArchive.open(portable, using: SyncEncryptionKey()),
                             "错误的恢复码必须拒绝打开")

        let payload = try PortableBackupArchive.open(portable, using: key)
        let targetV2 = V2Store(databaseURL: directory.appendingPathComponent("target-v2.db"))
        defer { targetV2.close() }
        let targetV2Before = try targetV2.encryptedSnapshot()
        let targetLegacy = AppDatabase(databaseURL: directory.appendingPathComponent("target-legacy.db"))
        defer { targetLegacy.close() }
        let targetLegacyBefore = try targetLegacy.encryptedSnapshot()
        let targetDiary = DiaryStore(supportDirectory: directory.appendingPathComponent("target-state", isDirectory: true))

        let targetV2Restored = try XCTUnwrap(payload.v2DatabasePlaintext).flatMap { plaintext in
            try? targetV2.encryptedSnapshot(fromPlaintext: plaintext)
        }
        XCTAssertNotNil(targetV2Restored)
        let localBackupURL = directory.appendingPathComponent("portable-local.riverbackup")
        let localBackup = try PortableBackupArchive.localBackupData(
            from: payload,
            legacyDatabaseSnapshot: nil,
            v2DatabaseSnapshot: targetV2Restored
        )
        try localBackup.write(to: localBackupURL, options: .atomic)

        try targetDiary.restoreFullBackup(
            from: localBackupURL,
            validateDatabaseSnapshots: { legacy, v2 in
                if let legacy { try targetLegacy.validateEncryptedSnapshot(legacy) }
                try targetV2.validateEncryptedSnapshot(try XCTUnwrap(v2))
            },
            restoreDatabaseSnapshots: { legacy, v2 in
                if let legacy { try targetLegacy.restoreEncryptedSnapshot(legacy) }
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

        XCTAssertEqual(targetDiary.overview(for: targetDiary.entry(for: day)), "从另一台 Mac 恢复的文字。")
        XCTAssertEqual(targetDiary.captures(for: targetDiary.entry(for: day)).first?.text, "可移植快记")
        XCTAssertEqual(targetV2.rawEvents(ids: [event.id]).first?.payload.locationName, "portable-place")
    }
}
