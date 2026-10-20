import XCTest
@testable import RiverDiaryMac

/// T04：退出登录后同步请求必须被同一门禁忽略，不能继续读写复制目录。
@MainActor
final class SyncExitGateTests: XCTestCase {
    private func makeDatabase() throws -> (V2Store, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-sync-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (V2Store(databaseURL: directory.appendingPathComponent("river-v2.db")), directory)
    }

    func testInactiveSessionIgnoresSynchronizeRequests() throws {
        let (database, directory) = try makeDatabase()
        defer {
            database.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SyncSettingsStore(database: database, sessionActive: false)
        let statusBefore = store.status
        let lastRunBefore = store.lastRunAt

        store.synchronize()

        XCTAssertFalse(store.isSyncing, "signed-out sync must not start a run")
        XCTAssertEqual(store.status, statusBefore)
        XCTAssertEqual(store.lastRunAt, lastRunBefore)
    }

    func testActiveSessionWithoutFolderOnlyReportsMissingFolder() throws {
        let (database, directory) = try makeDatabase()
        defer {
            database.close()
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SyncSettingsStore(database: database, sessionActive: true)
        XCTAssertFalse(store.isSyncing)
        store.synchronize()
        XCTAssertEqual(store.status, "请先选择 iCloud Drive 文件夹")
    }
}
