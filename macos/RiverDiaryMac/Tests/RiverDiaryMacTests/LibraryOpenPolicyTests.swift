import XCTest
import RiverDiaryCore
@testable import RiverDiaryMac

/// T02：首次未绑定账号时不创建正式库；已有库或旧安装救援资料必须仍可打开。
@MainActor
final class LibraryOpenPolicyTests: XCTestCase {

    func testOnlyFreshUnboundInstallDefersOpening() {
        // 新安装、未登录、没有旧资料：延迟开库。
        XCTAssertFalse(LibraryOpenPolicy.shouldOpenLocalLibrary(
            hasDatabaseFile: false,
            hasLegacyLocalState: false,
            isSignedIn: false
        ))
        // 任何一项成立都必须可读，否则会封死离线用户或旧安装的救援路径。
        XCTAssertTrue(LibraryOpenPolicy.shouldOpenLocalLibrary(
            hasDatabaseFile: true,
            hasLegacyLocalState: false,
            isSignedIn: false
        ))
        XCTAssertTrue(LibraryOpenPolicy.shouldOpenLocalLibrary(
            hasDatabaseFile: false,
            hasLegacyLocalState: true,
            isSignedIn: false
        ))
        XCTAssertTrue(LibraryOpenPolicy.shouldOpenLocalLibrary(
            hasDatabaseFile: false,
            hasLegacyLocalState: false,
            isSignedIn: true
        ))
    }

    func testDeferredStoreCreatesNothingUntilOpened() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-deferred-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("river-v2.db")

        let store = V2Store(databaseURL: url, opensImmediately: false)
        XCTAssertFalse(store.isOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "deferred store must not create the database file")

        XCTAssertTrue(store.openIfNeeded())
        XCTAssertTrue(store.isOpen)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.databaseSchemaVersion, 2)
        XCTAssertTrue(store.tableNames().contains("raw_events"))

        // 重复调用保持幂等，不会重建或丢数据。
        XCTAssertTrue(store.openIfNeeded())
        XCTAssertEqual(store.databaseSchemaVersion, 2)

        // 退出登录后关闭上下文，再次登录可重新打开。
        store.close()
        XCTAssertFalse(store.isOpen)
        XCTAssertTrue(store.openIfNeeded())
        XCTAssertEqual(store.databaseSchemaVersion, 2)
        store.close()
    }

    func testLegacyStateDetectionFindsEncryptedAndPlaintextFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-legacy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertFalse(LocalLibraryPresence.legacyStateExists(in: directory))
        XCTAssertFalse(LocalLibraryPresence.databaseFileExists(at: directory.appendingPathComponent("river-v2.db")))

        try Data("state".utf8).write(to: directory.appendingPathComponent("journal.state"))
        XCTAssertTrue(LocalLibraryPresence.legacyStateExists(in: directory))

        // 更早的旧安装只有 SQLCipher 版 river-diary.db。
        let legacyDatabaseDirectory = directory.appendingPathComponent("Database", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDatabaseDirectory, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyDatabaseDirectory.appendingPathComponent("river-diary.db"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("journal.state"))
        XCTAssertTrue(LocalLibraryPresence.legacyStateExists(in: directory))
    }
}
