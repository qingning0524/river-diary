import SQLCipher
import XCTest
@testable import RiverDiaryMac

/// T05：提交阶段失败时不能半提交，旧数据和文件内容都要保持可恢复。
@MainActor
final class SQLFailureTests: XCTestCase {
    func testCommitFailureDoesNotHalfCommitAndKeepsPreviousState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-commit-failure-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("river-v2.db")

        let store = V2Store(databaseURL: url)
        let payload = Data("first".utf8)
        XCTAssertNotNil(store.appendStateOperation(
            targetID: "day-1", fieldKey: "note", operationType: "test.set", payload: payload
        ))
        XCTAssertEqual(store.allStateOperations().count, 1)

        // 数据库已打开，但同目录不可写：SQLite 无法写回滚日志，提交必然失败。
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let failed = store.appendStateOperation(
            targetID: "day-2", fieldKey: "note", operationType: "test.set", payload: Data("second".utf8)
        )
        XCTAssertNil(failed, "a commit that cannot reach disk must not report success")
        XCTAssertNotNil(store.lastError)

        // 恢复目录后重新打开：只有第一条操作存在，没有半提交。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.close()
        let reopened = V2Store(databaseURL: url)
        XCTAssertEqual(reopened.allStateOperations().count, 1)
        XCTAssertEqual(reopened.allStateOperations().first?.targetID, "day-1")
        reopened.close()
    }
}

/// T05：prepare 阶段失败（表被外部破坏）必须被报告，不能静默成功或崩溃。
@MainActor
final class SQLPrepareFailureTests: XCTestCase {
    func testPrepareFailureIsReportedAndKeepsStoreAlive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-prepare-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("river-v2.db")

        let store = V2Store(databaseURL: url)
        XCTAssertNotNil(store.appendStateOperation(
            targetID: "day-1", fieldKey: "note", operationType: "test.set", payload: Data("first".utf8)
        ))

        // 用第二个连接破坏 schema，模拟磁盘文件被外部写坏/降级。
        let saboteur = try DatabaseCipher.open(at: url, purpose: "v2-facts-v1")
        XCTAssertEqual(sqlite3_exec(saboteur, "DROP TABLE state_operations;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(saboteur)

        XCTAssertNil(store.appendStateOperation(
            targetID: "day-2", fieldKey: "note", operationType: "test.set", payload: Data("second".utf8)
        ))
        XCTAssertNotNil(store.lastError)
        // 失败后仍可安全关闭/重开，不会因为缺表而崩溃。
        store.close()
        let reopened = V2Store(databaseURL: url)
        XCTAssertTrue(reopened.isOpen)
        reopened.close()
    }
}
