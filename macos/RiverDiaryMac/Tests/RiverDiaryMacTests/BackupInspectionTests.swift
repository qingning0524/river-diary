import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

/// D07 恢复闭环：先只读检查备份，再决定是否恢复。
/// 检查必须报告内容、验证数据库快照，且绝不修改本机 journal.state。
@MainActor
final class BackupInspectionTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-backup-inspection-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        return directory
    }

    func testInspectionReportsContentWithoutChangingLocalState() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let store = DiaryStore(supportDirectory: stateDirectory)
        let day = try XCTUnwrap(DiaryEntry.dateFormatter.date(from: "2026-10-21"))
        XCTAssertTrue(store.addQuickCapture("检查这份备份是否完整。", for: day))

        let v2 = V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
        defer { v2.close() }
        let event = RawEvent(
            timestamp: day,
            source: .ingestion,
            kind: .ingestionSnapshot,
            payload: RawEventPayload(text: "backup-inspection")
        )
        XCTAssertTrue(v2.insertRawEvent(event))

        let backupURL = directory.appendingPathComponent("inspect.riverbackup")
        try store.exportFullBackup(to: backupURL, v2DatabaseSnapshot: try v2.encryptedSnapshot())

        let stateFile = stateDirectory.appendingPathComponent("journal.state")
        let stateBefore = try Data(contentsOf: stateFile)

        let inspection = try store.validateFullBackup(at: backupURL) { _, v2Snapshot in
            try v2.validateEncryptedSnapshot(try XCTUnwrap(v2Snapshot))
        }

        XCTAssertEqual(inspection.quickCaptureCount, 1)
        XCTAssertTrue(inspection.includesV2Database)
        XCTAssertFalse(inspection.includesLegacyDatabase)
        XCTAssertEqual(inspection.entryCount, 0)
        XCTAssertEqual(try Data(contentsOf: stateFile), stateBefore,
                       "只读检查不得改写当前 journal.state")
    }

    func testInspectionRejectsCorruptBackupAndLeavesStateUntouched() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stateDirectory = directory.appendingPathComponent("state", isDirectory: true)
        let store = DiaryStore(supportDirectory: stateDirectory)
        XCTAssertTrue(store.addQuickCapture("检查失败也不能丢数据。", for: Date()))
        let stateFile = stateDirectory.appendingPathComponent("journal.state")
        let stateBefore = try Data(contentsOf: stateFile)

        let badURL = directory.appendingPathComponent("bad.riverbackup")
        try Data("this is not an encrypted River Diary backup".utf8).write(to: badURL)

        XCTAssertThrowsError(try store.validateFullBackup(at: badURL))
        XCTAssertEqual(try Data(contentsOf: stateFile), stateBefore)
    }
}
