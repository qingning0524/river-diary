import XCTest
@testable import RiverDiaryMac

/// T05：保存失败时保留旧值与文字，恢复后重试不产生重复记录。
@MainActor
final class SaveFailureTests: XCTestCase {
    private func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-save-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeState(_ data: Data) throws -> UserState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserState.self, from: try StateEncryption.decrypt(data))
    }

    func testFailedSaveKeepsPreviousTextAndRetryDoesNotDuplicate() throws {
        let directory = try makeSupportDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = DiaryStore(supportDirectory: directory)
        let entry = DiaryEntry(pageID: "local-2026-10-20", date: "2026-10-20")
        try store.saveWriting(entry: entry, text: "第一版", mood: nil)

        let stateURL = directory.appendingPathComponent("journal.state")
        let before = try Data(contentsOf: stateURL)
        XCTAssertEqual(try decodeState(before).entries["local-2026-10-20"]?.overview, "第一版")

        // 目录不可写：原子写在同目录建临时文件会失败，等同于磁盘写不进去。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try store.saveWriting(entry: entry, text: "第二版", mood: nil))

        // 失败不能覆盖旧值，也不能在内存里先改成新值再假装保存。
        let afterFailure = try Data(contentsOf: stateURL)
        XCTAssertEqual(afterFailure, before, "a failed save must not rewrite the state file")
        XCTAssertEqual(try decodeState(afterFailure).entries["local-2026-10-20"]?.overview, "第一版")

        // 恢复写入后重试：只产生一条记录，内容为新版本。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try store.saveWriting(entry: entry, text: "第二版", mood: nil)

        let afterRetry = try decodeState(try Data(contentsOf: stateURL))
        XCTAssertEqual(afterRetry.entries.count, 1, "retrying a failed save must not duplicate the entry")
        XCTAssertEqual(afterRetry.entries["local-2026-10-20"]?.overview, "第二版")
    }
}
