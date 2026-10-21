import CryptoKit
import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

/// 模拟“另一台 Mac”：源与目标使用不同的本机 state key，只共享恢复码。
/// 这是跨机恢复的核心证据；真实第二台机器仍要按 QA 清单再走一次。
@MainActor
final class PortableCrossKeyTests: XCTestCase {
    func testPortableBackupRestoresAcrossDifferentLocalKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-cross-key-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: root)
        defer {
            StateEncryption.clearTestKeyForDrill()
            try? FileManager.default.removeItem(at: root)
        }

        let sourceKey = SymmetricKey(size: .bits256)
        let targetKey = SymmetricKey(size: .bits256)
        let day = try XCTUnwrap(DiaryEntry.dateFormatter.date(from: "2026-10-21"))
        let syncKey = SyncEncryptionKey()

        // 源 Mac：用 key A 写日记、旧库和 V2 事实库。
        StateEncryption.installTestKeyForDrill(sourceKey)
        let sourceDir = root.appendingPathComponent("source", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: sourceDir)
        let sourceDiary = DiaryStore(supportDirectory: sourceDir.appendingPathComponent("state", isDirectory: true))
        try sourceDiary.saveWriting(entry: sourceDiary.entry(for: day), text: "跨 key 恢复的日记", mood: 6)
        let sourceLegacy = AppDatabase(databaseURL: sourceDir.appendingPathComponent("legacy.db"))
        let sourceV2 = V2Store(databaseURL: sourceDir.appendingPathComponent("v2.db"))
        defer { sourceLegacy.close(); sourceV2.close() }
        XCTAssertTrue(sourceLegacy.saveAIResult(
            resultKey: "cross-key",
            startDate: "2026-10-21",
            endDate: "2026-10-21",
            task: "query",
            model: "test",
            answer: "跨 key 旧库",
            sourceSummary: "portable"
        ))
        let event = RawEvent(
            timestamp: day,
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: "cross-key-place")
        )
        XCTAssertTrue(sourceV2.insertRawEvent(event))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let portable = try PortableBackupArchive.seal(
            journal: try encoder.encode(try sourceDiary.makeBackupPayload()),
            legacyDatabasePlaintext: try sourceLegacy.plaintextSnapshot(),
            v2DatabasePlaintext: try sourceV2.plaintextSnapshot(),
            using: syncKey
        )

        // 目标 Mac：换成本机 key B，只拿恢复码和可移植文件。
        StateEncryption.installTestKeyForDrill(targetKey)
        let targetDir = root.appendingPathComponent("target", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: targetDir)
        let targetDiary = DiaryStore(supportDirectory: targetDir.appendingPathComponent("state", isDirectory: true))
        let targetLegacy = AppDatabase(databaseURL: targetDir.appendingPathComponent("legacy.db"))
        let targetV2 = V2Store(databaseURL: targetDir.appendingPathComponent("v2.db"))
        defer { targetLegacy.close(); targetV2.close() }
        let legacyBefore = try targetLegacy.encryptedSnapshot()
        let v2Before = try targetV2.encryptedSnapshot()

        let payload = try PortableBackupArchive.open(portable, using: syncKey)
        try targetLegacy.validatePlaintextSnapshot(try XCTUnwrap(payload.legacyDatabasePlaintext))
        try targetV2.validatePlaintextSnapshot(try XCTUnwrap(payload.v2DatabasePlaintext))
        let legacySnapshot = try targetLegacy.encryptedSnapshot(fromPlaintext: try XCTUnwrap(payload.legacyDatabasePlaintext))
        let v2Snapshot = try targetV2.encryptedSnapshot(fromPlaintext: try XCTUnwrap(payload.v2DatabasePlaintext))
        let localBackup = try PortableBackupArchive.localBackupData(
            from: payload,
            legacyDatabaseSnapshot: legacySnapshot,
            v2DatabaseSnapshot: v2Snapshot
        )
        let localURL = targetDir.appendingPathComponent("local.riverbackup")
        try localBackup.write(to: localURL, options: .atomic)

        try targetDiary.restoreFullBackup(
            from: localURL,
            validateDatabaseSnapshots: { legacy, v2 in
                try targetLegacy.validateEncryptedSnapshot(try XCTUnwrap(legacy))
                try targetV2.validateEncryptedSnapshot(try XCTUnwrap(v2))
            },
            restoreDatabaseSnapshots: { legacy, v2 in
                try targetLegacy.restoreEncryptedSnapshot(try XCTUnwrap(legacy))
                try targetV2.restoreEncryptedSnapshot(try XCTUnwrap(v2))
            },
            rollbackExternalData: {
                try targetLegacy.restoreEncryptedSnapshot(legacyBefore)
                try targetV2.restoreEncryptedSnapshot(v2Before)
            },
            recoverySnapshot: RestoreRecoverySnapshot(
                legacyDatabaseSnapshot: legacyBefore,
                v2DatabaseSnapshot: v2Before
            )
        )

        XCTAssertEqual(targetDiary.overview(for: targetDiary.entry(for: day)), "跨 key 恢复的日记")
        XCTAssertEqual(targetLegacy.queryAIResults(startDate: "2026-10-21", endDate: "2026-10-21").first?.answer, "跨 key 旧库")
        XCTAssertEqual(targetV2.rawEvents(ids: [event.id]).first?.payload.locationName, "cross-key-place")

        // 重新用 key B 打开目标库，证明数据库确实被重新加密到目标本机密钥。
        StateEncryption.installTestKeyForDrill(targetKey)
        let reopenedV2 = V2Store(databaseURL: targetDir.appendingPathComponent("v2.db"))
        defer { reopenedV2.close() }
        XCTAssertEqual(reopenedV2.rawEvents(ids: [event.id]).first?.payload.locationName, "cross-key-place")
    }
}
