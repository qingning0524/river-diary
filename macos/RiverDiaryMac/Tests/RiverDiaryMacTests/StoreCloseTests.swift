import XCTest
@testable import RiverDiaryMac

/// T04：退出登录关闭数据库上下文后，读写必须安全失败；重新登录打开后数据仍在。
@MainActor
final class StoreCloseTests: XCTestCase {
    func testClosedStoreRejectsWritesAndReopensWithData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("river-v2.db")

        let store = V2Store(databaseURL: url)
        let payload = Data("value".utf8)
        XCTAssertNotNil(store.appendStateOperation(
            targetID: "day-2026-10-20", fieldKey: "note", operationType: "test.set", payload: payload
        ))
        XCTAssertEqual(store.allStateOperations().count, 1)

        store.close()
        XCTAssertFalse(store.isOpen)

        // 关闭后读取不能崩溃，写入必须被拒绝并给出原因。
        XCTAssertTrue(store.allStateOperations().isEmpty)
        XCTAssertNil(store.appendStateOperation(
            targetID: "day-2026-10-21", fieldKey: "note", operationType: "test.set", payload: payload
        ))
        XCTAssertNotNil(store.lastError)

        // 重新登录打开同一文件：旧数据还在，状态恢复可用。
        XCTAssertTrue(store.openIfNeeded())
        XCTAssertEqual(store.allStateOperations().count, 1)
        XCTAssertNil(store.lastError)
        store.close()
    }
}

/// T05：数据库打不开时必须如实报错，不能表现为“空库”。
@MainActor
final class StoreOpenFailureTests: XCTestCase {
    func testUnopenableDatabaseReportsFailureAndStaysClosed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-open-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appendingPathComponent("river-v2.db", isDirectory: true)
        try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)

        let store = V2Store(databaseURL: databasePath)
        XCTAssertFalse(store.isOpen, "a directory at the database path must not open as a database")
        XCTAssertNotNil(store.lastError)

        XCTAssertNil(store.appendStateOperation(
            targetID: "day", fieldKey: "note", operationType: "test.set", payload: Data("v".utf8)
        ))
        XCTAssertFalse(store.openIfNeeded())
        XCTAssertFalse(store.isOpen)
    }
}
