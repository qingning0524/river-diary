import XCTest
@testable import RiverDiaryMac

/// T05：读取失败必须被报告，且不能被后续保存静默覆盖成空状态。
@MainActor
final class StorageReadFailureTests: XCTestCase {
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-read-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testCorruptEncryptedStateIsReportedAndNeverOverwritten() throws {
        let directory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stateURL = directory.appendingPathComponent("journal.state")
        let garbage = Data("corrupt-state-not-encrypted".utf8)
        try garbage.write(to: stateURL)

        let store = DiaryStore(supportDirectory: directory)
        XCTAssertNotNil(store.loadError, "a corrupt state file must surface an error")
        XCTAssertTrue(store.entries.isEmpty)

        // 读取失败后保存必须被拒绝：不能把原文件覆盖成一份空状态。
        XCTAssertThrowsError(try store.saveSavedQuery(
            SavedQuery(name: "测试", query: "河", days: 7)
        ))
        XCTAssertEqual(try Data(contentsOf: stateURL), garbage,
                       "the corrupt file must be preserved for rescue/restore")
    }

    func testCorruptLegacyStateIsNotDeletedOrReplaced() throws {
        let directory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("user-state.json")
        let garbage = Data("not-json".utf8)
        try garbage.write(to: legacyURL)

        let store = DiaryStore(supportDirectory: directory)
        XCTAssertNotNil(store.loadError)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "the legacy file is deleted only after a successful migration")
        XCTAssertEqual(try Data(contentsOf: legacyURL), garbage)
    }

    func testReadFailureBlocksEveryUserFacingSavePath() throws {
        let directory = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("journal.state"))

        let store = DiaryStore(supportDirectory: directory)
        XCTAssertNotNil(store.loadError)

        XCTAssertThrowsError(try store.saveSavedQuery(SavedQuery(name: "a", query: "b", days: 3)))
        XCTAssertThrowsError(try store.saveTimelineAnnotation(
            TimelineAnnotation(note: "x"),
            for: "2026-10-20|activity"
        ))
        XCTAssertThrowsError(try store.saveDailyGoal(
            DailyGoal(title: "写一句"), for: Date()
        ))
        XCTAssertThrowsError(try store.saveJournalDraft(
            JournalDraftRecord(text: "draft", mood: nil, updatedAt: Date()),
            for: "2026-10-20"
        ))
    }
}
