import Foundation
import SQLCipher

enum DatabaseCipherError: LocalizedError {
    case keyRejected(String)
    case invalidDatabase(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .keyRejected(let message): "数据库密钥设置失败：\(message)"
        case .invalidDatabase(let message): "数据库无法通过密钥校验：\(message)"
        case .migrationFailed(let message): "旧数据库迁移失败：\(message)"
        }
    }
}

enum DatabaseCipher {
    static func key(for purpose: String) throws -> String {
        try StateEncryption.derivedDatabaseKey(purpose: purpose)
    }

    static func apply(_ key: String, to database: OpaquePointer) throws {
        let keyData = Data(key.utf8)
        let status = keyData.withUnsafeBytes { bytes in
            sqlite3_key(database, bytes.baseAddress, Int32(bytes.count))
        }
        guard status == SQLITE_OK else {
            throw DatabaseCipherError.keyRejected(errorMessage(from: database))
        }
    }

    static func open(
        at url: URL,
        purpose: String,
        flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    ) throws -> OpaquePointer {
        try LocalStorageProtection.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        let key = try key(for: purpose)
        try recoverInterruptedReplacement(at: url, key: key)
        try migratePlaintextDatabaseIfNeeded(at: url, key: key)

        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage(from:)) ?? "数据库无法打开"
            sqlite3_close(database)
            throw DatabaseCipherError.invalidDatabase(message)
        }

        do {
            try apply(key, to: database)
            try validate(database)
            try LocalStorageProtection.protectFile(at: url)
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    static func migratePlaintextDatabaseIfNeeded(at url: URL, key: String) throws {
        let temporaryURL = url.appendingPathExtension("sqlcipher-migrating")
        let backupURL = url.appendingPathExtension("plaintext-migration")
        try recoverInterruptedMigration(databaseURL: url, temporaryURL: temporaryURL, backupURL: backupURL, key: key)

        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize > 0 else { return }

        let header = try fileHeader(at: url)
        let sqliteHeader = Data("SQLite format 3\0".utf8)
        guard header.starts(with: sqliteHeader) else {
            try validateEncryptedFile(at: url, key: key)
            return
        }

        try encryptPlaintextDatabase(at: url, temporaryURL: temporaryURL, backupURL: backupURL, key: key)
    }

    static func encryptedSnapshot(
        of source: OpaquePointer,
        purpose: String,
        in directory: URL
    ) throws -> Data {
        let snapshotsDirectory = directory.appendingPathComponent("Snapshots", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: snapshotsDirectory)
        let snapshotURL = snapshotsDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).db")
        defer {
            try? removeSQLiteSidecars(for: snapshotURL)
            try? FileManager.default.removeItem(at: snapshotURL)
        }

        let destination = try open(at: snapshotURL, purpose: purpose)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            let message = errorMessage(from: destination)
            sqlite3_close(destination)
            throw DatabaseCipherError.migrationFailed("加密快照初始化失败：\(message)")
        }

        var stepStatus = sqlite3_backup_step(backup, -1)
        var retryCount = 0
        while stepStatus == SQLITE_OK || stepStatus == SQLITE_BUSY || stepStatus == SQLITE_LOCKED {
            guard retryCount < 100 else { break }
            retryCount += 1
            Thread.sleep(forTimeInterval: 0.01)
            stepStatus = sqlite3_backup_step(backup, -1)
        }
        let finishStatus = sqlite3_backup_finish(backup)
        guard stepStatus == SQLITE_DONE, finishStatus == SQLITE_OK else {
            let message = errorMessage(from: destination)
            sqlite3_close(destination)
            throw DatabaseCipherError.migrationFailed("加密快照写入失败：\(message)")
        }
        let closeStatus = sqlite3_close(destination)
        guard closeStatus == SQLITE_OK else {
            throw DatabaseCipherError.migrationFailed("加密快照关闭失败")
        }

        try LocalStorageProtection.protectFile(at: snapshotURL)
        try validateEncryptedFile(at: snapshotURL, key: try key(for: purpose))
        return try Data(contentsOf: snapshotURL)
    }

    /// 把本机密钥加密的快照转成明文 SQLite 字节，仅用于用户主动导出的可移植备份。
    /// 明文只在临时目录内短暂存在，外层容器必须再用恢复码加密。
    static func plaintextSnapshot(
        fromEncrypted snapshot: Data,
        purpose: String,
        in directory: URL
    ) throws -> Data {
        let working = directory.appendingPathComponent("PortableSnapshots", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: working)
        let encryptedURL = working.appendingPathComponent("source-\(UUID().uuidString).db")
        let plaintextURL = working.appendingPathComponent("plain-\(UUID().uuidString).db")
        defer {
            try? removeSQLiteSidecars(for: encryptedURL)
            try? removeSQLiteSidecars(for: plaintextURL)
            try? FileManager.default.removeItem(at: encryptedURL)
            try? FileManager.default.removeItem(at: plaintextURL)
        }
        try snapshot.write(to: encryptedURL, options: .atomic)
        try LocalStorageProtection.protectFile(at: encryptedURL)
        try LocalStorageProtection.protectFile(at: plaintextURL)

        var target: OpaquePointer?
        do {
            let status = sqlite3_open_v2(
                plaintextURL.path,
                &target,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard status == SQLITE_OK, let opened = target else {
                let message = target.map(errorMessage(from:)) ?? "明文副本无法创建"
                throw DatabaseCipherError.invalidDatabase(message)
            }
            let key = try key(for: purpose)
            let escapedPath = encryptedURL.path.replacingOccurrences(of: "'", with: "''")
            let escapedKey = key.replacingOccurrences(of: "'", with: "''")
            try execute("ATTACH DATABASE '\(escapedPath)' AS encrypted KEY '\(escapedKey)'", on: opened)
            try execute("SELECT sqlcipher_export('main','encrypted')", on: opened)
            try execute("DETACH DATABASE encrypted", on: opened)
            guard sqlite3_close(opened) == SQLITE_OK else {
                throw DatabaseCipherError.invalidDatabase("明文副本关闭失败")
            }
            target = nil
            try validatePlaintextFile(at: plaintextURL)
            return try Data(contentsOf: plaintextURL)
        } catch {
            if let target { sqlite3_close(target) }
            throw error
        }
    }

    /// 把可移植备份里的明文 SQLite 字节重新用当前 Mac 的本机密钥加密。
    static func encryptedSnapshot(
        fromPlaintext plaintext: Data,
        purpose: String,
        in directory: URL
    ) throws -> Data {
        let working = directory.appendingPathComponent("PortableSnapshots", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: working)
        let plaintextURL = working.appendingPathComponent("plain-\(UUID().uuidString).db")
        let encryptedURL = working.appendingPathComponent("encrypted-\(UUID().uuidString).db")
        defer {
            try? removeSQLiteSidecars(for: plaintextURL)
            try? removeSQLiteSidecars(for: encryptedURL)
            try? FileManager.default.removeItem(at: plaintextURL)
            try? FileManager.default.removeItem(at: encryptedURL)
        }
        try plaintext.write(to: plaintextURL, options: .atomic)
        try validatePlaintextFile(at: plaintextURL)

        var target: OpaquePointer?
        do {
            let status = sqlite3_open_v2(
                encryptedURL.path,
                &target,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard status == SQLITE_OK, let opened = target else {
                let message = target.map(errorMessage(from:)) ?? "加密副本无法创建"
                throw DatabaseCipherError.invalidDatabase(message)
            }
            let key = try key(for: purpose)
            try apply(key, to: opened)
            try execute("PRAGMA journal_mode=DELETE", on: opened)
            try execute("PRAGMA synchronous=FULL", on: opened)
            let escaped = plaintextURL.path.replacingOccurrences(of: "'", with: "''")
            try execute("ATTACH DATABASE '\(escaped)' AS plaintext KEY ''", on: opened)
            try execute("SELECT sqlcipher_export('main','plaintext')", on: opened)
            try execute("DETACH DATABASE plaintext", on: opened)
            guard sqlite3_close(opened) == SQLITE_OK else {
                throw DatabaseCipherError.invalidDatabase("加密副本关闭失败")
            }
            target = nil
            try LocalStorageProtection.protectFile(at: encryptedURL)
            try validateEncryptedFile(at: encryptedURL, key: key)
            return try Data(contentsOf: encryptedURL)
        } catch {
            if let target { sqlite3_close(target) }
            throw error
        }
    }

    static func validatePlaintextFile(at url: URL) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage(from:)) ?? "明文数据库无法打开"
            throw DatabaseCipherError.invalidDatabase(message)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw DatabaseCipherError.invalidDatabase(errorMessage(from: database))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0),
              String(cString: text) == "ok" else {
            throw DatabaseCipherError.invalidDatabase("明文备份未通过 SQLite 完整性检查")
        }
    }

    static func validateEncryptedSnapshot(_ snapshot: Data, purpose: String, in directory: URL) throws {
        let validationDirectory = directory.appendingPathComponent("SnapshotValidation", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: validationDirectory)
        let validationURL = validationDirectory.appendingPathComponent("validate-\(UUID().uuidString).db")
        defer {
            try? removeSQLiteSidecars(for: validationURL)
            try? FileManager.default.removeItem(at: validationURL)
        }
        try snapshot.write(to: validationURL, options: .atomic)
        try LocalStorageProtection.protectFile(at: validationURL)
        try validateEncryptedFile(at: validationURL, key: try key(for: purpose))
    }

    static func replaceEncryptedDatabase(
        at url: URL,
        with snapshot: Data,
        purpose: String
    ) throws {
        let key = try key(for: purpose)
        try LocalStorageProtection.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        try recoverInterruptedReplacement(at: url, key: key)

        let stagingURL = url.appendingPathExtension("restore-staging")
        let backupURL = url.appendingPathExtension("restore-backup")
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }
        try snapshot.write(to: stagingURL, options: .atomic)
        try LocalStorageProtection.protectFile(at: stagingURL)
        try validateEncryptedFile(at: stagingURL, key: key)
        try removeSQLiteSidecars(for: url)

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.moveItem(at: url, to: backupURL)
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: url)
            try LocalStorageProtection.protectFile(at: url)
            try validateEncryptedFile(at: url, key: key)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
        } catch {
            if fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.moveItem(at: backupURL, to: url)
            }
            throw error
        }
    }

    static func validate(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "SELECT count(*) FROM sqlite_master",
            -1,
            &statement,
            nil
        )
        defer { sqlite3_finalize(statement) }
        guard prepareStatus == SQLITE_OK else {
            throw DatabaseCipherError.invalidDatabase(errorMessage(from: database))
        }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseCipherError.invalidDatabase(errorMessage(from: database))
        }
    }

    static func errorMessage(from database: OpaquePointer) -> String {
        sqlite3_errmsg(database).map(String.init(cString:)) ?? "未知数据库错误"
    }

    private static func fileHeader(at url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: 16) ?? Data()
    }

    static func validateEncryptedFile(at url: URL, key: String) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let database else {
            let message = database.map(errorMessage(from:)) ?? "数据库无法打开"
            sqlite3_close(database)
            throw DatabaseCipherError.invalidDatabase(message)
        }
        defer { sqlite3_close(database) }
        try apply(key, to: database)
        try validate(database)
    }

    private static func encryptPlaintextDatabase(
        at sourceURL: URL,
        temporaryURL: URL,
        backupURL: URL,
        key: String
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try removeSQLiteSidecars(for: temporaryURL)

        var source: OpaquePointer?
        var target: OpaquePointer?
        do {
            let sourceStatus = sqlite3_open_v2(
                sourceURL.path,
                &source,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard sourceStatus == SQLITE_OK, let openedSource = source else {
                let message = source.map(errorMessage(from:)) ?? "明文数据库无法打开"
                throw DatabaseCipherError.migrationFailed(message)
            }
            try execute("PRAGMA wal_checkpoint(TRUNCATE)", on: openedSource)
            try execute("PRAGMA synchronous=FULL", on: openedSource)
            let sourceCloseStatus = sqlite3_close(openedSource)
            source = nil
            guard sourceCloseStatus == SQLITE_OK else {
                throw DatabaseCipherError.migrationFailed("明文数据库检查点未能关闭")
            }
            try removeSQLiteSidecars(for: sourceURL)

            let targetStatus = sqlite3_open_v2(
                temporaryURL.path,
                &target,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard targetStatus == SQLITE_OK, let encryptedTarget = target else {
                let message = target.map(errorMessage(from:)) ?? "加密副本无法创建"
                throw DatabaseCipherError.migrationFailed(message)
            }
            try apply(key, to: encryptedTarget)
            try execute("PRAGMA journal_mode=DELETE", on: encryptedTarget)
            try execute("PRAGMA synchronous=FULL", on: encryptedTarget)

            let escapedSourcePath = sourceURL.path.replacingOccurrences(of: "'", with: "''")
            try execute(
                "ATTACH DATABASE '\(escapedSourcePath)' AS plaintext KEY ''",
                on: encryptedTarget
            )
            try execute("SELECT sqlcipher_export('main', 'plaintext')", on: encryptedTarget)
            try execute("DETACH DATABASE plaintext", on: encryptedTarget)
            let targetCloseStatus = sqlite3_close(encryptedTarget)
            target = nil
            guard targetCloseStatus == SQLITE_OK else {
                throw DatabaseCipherError.migrationFailed("加密副本关闭失败")
            }

            try LocalStorageProtection.protectFile(at: temporaryURL)
            try validateEncryptedFile(at: temporaryURL, key: key)
            try removeSQLiteSidecars(for: temporaryURL)

            try fileManager.moveItem(at: sourceURL, to: backupURL)
            do {
                try fileManager.moveItem(at: temporaryURL, to: sourceURL)
                try LocalStorageProtection.protectFile(at: sourceURL)
                try validateEncryptedFile(at: sourceURL, key: key)
                try fileManager.removeItem(at: backupURL)
            } catch {
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try? fileManager.removeItem(at: sourceURL)
                }
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.moveItem(at: backupURL, to: sourceURL)
                }
                throw error
            }
        } catch {
            if let source { sqlite3_close(source) }
            if let target { sqlite3_close(target) }
            try? removeSQLiteSidecars(for: temporaryURL)
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
            if !fileManager.fileExists(atPath: sourceURL.path), fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: sourceURL)
            }
            if let cipherError = error as? DatabaseCipherError { throw cipherError }
            throw DatabaseCipherError.migrationFailed(error.localizedDescription)
        }
    }

    private static func recoverInterruptedMigration(
        databaseURL: URL,
        temporaryURL: URL,
        backupURL: URL,
        key: String
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else {
            try removeSQLiteSidecars(for: temporaryURL)
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try fileManager.removeItem(at: temporaryURL)
            }
            return
        }

        if fileManager.fileExists(atPath: databaseURL.path),
           (try? validateEncryptedFile(at: databaseURL, key: key)) != nil {
            try fileManager.removeItem(at: backupURL)
        } else {
            if fileManager.fileExists(atPath: databaseURL.path) {
                try fileManager.removeItem(at: databaseURL)
            }
            try fileManager.moveItem(at: backupURL, to: databaseURL)
        }
        try removeSQLiteSidecars(for: temporaryURL)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
    }

    private static func recoverInterruptedReplacement(at url: URL, key: String) throws {
        let fileManager = FileManager.default
        let stagingURL = url.appendingPathExtension("restore-staging")
        let backupURL = url.appendingPathExtension("restore-backup")
        if fileManager.fileExists(atPath: backupURL.path) {
            if fileManager.fileExists(atPath: url.path),
               (try? validateEncryptedFile(at: url, key: key)) != nil {
                try fileManager.removeItem(at: backupURL)
            } else {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                try validateEncryptedFile(at: backupURL, key: key)
                try fileManager.moveItem(at: backupURL, to: url)
            }
        }
        try removeSQLiteSidecars(for: stagingURL)
        if fileManager.fileExists(atPath: stagingURL.path) {
            try fileManager.removeItem(at: stagingURL)
        }
    }

    private static func removeSQLiteSidecars(for url: URL) throws {
        let fileManager = FileManager.default
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        }
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorPointer)
        defer { sqlite3_free(errorPointer) }
        guard status == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage(from: database)
            let operation = sql.hasPrefix("ATTACH DATABASE") ? "附加加密副本" : "执行迁移语句"
            throw DatabaseCipherError.migrationFailed("\(operation)：\(message)")
        }
    }
}
