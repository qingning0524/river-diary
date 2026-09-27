import Darwin
import Foundation

struct RestoreRecoverySnapshot {
    var activitySessions: [ActivitySession]? = nil
    var legacyDatabaseSnapshot: Data? = nil
    var v2DatabaseSnapshot: Data? = nil
    var trackingEnabled: Bool? = nil
}

struct RestoreRecoveryFile: Codable {
    var existed: Bool
    var contents: Data?
}

struct RestoreRecoveryPayload: Codable {
    var version = 1
    var createdAt = Date()
    var activitySessions: [ActivitySession]? = nil
    var legacyDatabaseSnapshot: Data? = nil
    var v2DatabaseSnapshot: Data? = nil
    var trackingEnabled: Bool? = nil
    var externalSourcePath: String? = nil
    var journalState: RestoreRecoveryFile
    var restoredData: RestoreRecoveryFile
}

/// A durable, encrypted rollback point for a restore that spans multiple stores.
/// The journal remains until every old store has been put back, so replaying it
/// after another interruption is safe and idempotent.
enum RestoreRecoveryJournal {
    static let fileName = "restore-transaction.state"
    private static let externalSourceKey = "externalSnapshotPath"
    private static let trackingKey = "activity.enabled"
    private static let fileManager = FileManager.default

    static func defaultSupportDirectory() throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw recoveryError("无法访问应用支持目录。")
        }
        return base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
    }

    static func journalURL(in supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func write(_ payload: RestoreRecoveryPayload, in supportDirectory: URL) throws {
        try LocalStorageProtection.ensurePrivateDirectory(at: supportDirectory)
        let destination = journalURL(in: supportDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw recoveryError("检测到尚未完成的恢复记录；请先重新启动应用完成回滚。")
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try StateEncryption.encrypt(encoder.encode(payload))
        try writeDurably(encrypted, to: destination)
    }

    @MainActor
    @discardableResult
    static func recoverIfNeeded(
        supportDirectory: URL? = nil,
        legacyDatabaseURL: URL? = nil,
        v2DatabaseURL: URL? = nil,
        activityDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) throws -> Bool {
        let support = try supportDirectory ?? defaultSupportDirectory()
        let url = journalURL(in: support)
        guard fileManager.fileExists(atPath: url.path) else { return false }

        let raw = try Data(contentsOf: url)
        let plaintext = try StateEncryption.decrypt(raw)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RestoreRecoveryPayload.self, from: plaintext)
        guard payload.version == 1,
              payload.journalState.existed == (payload.journalState.contents != nil),
              payload.restoredData.existed == (payload.restoredData.contents != nil) else {
            throw recoveryError("恢复记录不完整或版本不受支持，原记录已保留。")
        }

        let legacyURL = try legacyDatabaseURL ?? defaultLegacyDatabaseURL(in: support)
        let factsURL = try v2DatabaseURL ?? defaultV2DatabaseURL(in: support)
        if let snapshot = payload.legacyDatabaseSnapshot {
            try DatabaseCipher.validateEncryptedSnapshot(
                snapshot,
                purpose: "legacy-records-v1",
                in: legacyURL.deletingLastPathComponent()
            )
        }
        if let snapshot = payload.v2DatabaseSnapshot {
            try DatabaseCipher.validateEncryptedSnapshot(
                snapshot,
                purpose: "v2-facts-v1",
                in: factsURL.deletingLastPathComponent()
            )
        }

        // Validate all encrypted database snapshots before replacing any store.
        var replacedLegacyDatabase = false
        var replacedV2Database = false
        if let snapshot = payload.legacyDatabaseSnapshot {
            try DatabaseCipher.replaceEncryptedDatabase(
                at: legacyURL,
                with: snapshot,
                purpose: "legacy-records-v1"
            )
            replacedLegacyDatabase = true
        }
        if let snapshot = payload.v2DatabaseSnapshot {
            try DatabaseCipher.replaceEncryptedDatabase(
                at: factsURL,
                with: snapshot,
                purpose: "v2-facts-v1"
            )
            replacedV2Database = true
        }
        if let sessions = payload.activitySessions {
            try restoreActivitySessions(sessions, at: activityDirectory ?? support.appendingPathComponent("Activity", isDirectory: true))
        }

        try restoreFile(payload.journalState, to: support.appendingPathComponent("journal.state"))
        try restoreFile(payload.restoredData, to: support.appendingPathComponent("RestoredBackup.json"))
        if let sourcePath = payload.externalSourcePath {
            userDefaults.set(sourcePath, forKey: externalSourceKey)
        } else {
            userDefaults.removeObject(forKey: externalSourceKey)
        }
        if let trackingEnabled = payload.trackingEnabled {
            userDefaults.set(trackingEnabled, forKey: trackingKey)
        }
        try synchronizeCommittedStores(
            in: support,
            legacyDatabaseURL: legacyURL,
            v2DatabaseURL: factsURL,
            activityDirectory: activityDirectory,
            userDefaults: userDefaults
        )
        // 文件已被 POSIX rename 换掉：持有被换文件的那个连接必须重开到新
        // 文件，否则读旧 inode、写入丢失。只重开 URL 匹配的连接——共享
        // 单例指向默认路径，测试环境里的临时库连接各自匹配各自的 URL。
        if replacedV2Database {
            V2Store.reopenConnectionsAfterFileReplacement(at: factsURL)
        }
        if replacedLegacyDatabase {
            AppDatabase.shared.reopenAfterFileReplacementIfNecessary(url: legacyURL)
        }
        try clear(in: support)
        return true
    }

    static func synchronizeCommittedStores(
        in supportDirectory: URL,
        legacyDatabaseURL: URL? = nil,
        v2DatabaseURL: URL? = nil,
        activityDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) throws {
        let legacyURL = try legacyDatabaseURL ?? defaultLegacyDatabaseURL(in: supportDirectory)
        let factsURL = try v2DatabaseURL ?? defaultV2DatabaseURL(in: supportDirectory)
        let activityURL = activityDirectory ?? supportDirectory.appendingPathComponent("Activity", isDirectory: true)
        let files = [
            supportDirectory.appendingPathComponent("journal.state"),
            supportDirectory.appendingPathComponent("RestoredBackup.json"),
            legacyURL, URL(fileURLWithPath: legacyURL.path + "-wal"), URL(fileURLWithPath: legacyURL.path + "-shm"),
            factsURL, URL(fileURLWithPath: factsURL.path + "-wal"), URL(fileURLWithPath: factsURL.path + "-shm")
        ]
        for file in files where fileManager.fileExists(atPath: file.path) {
            try synchronizeFile(file)
        }
        if fileManager.fileExists(atPath: activityURL.path) {
            let activityFiles = try fileManager.contentsOfDirectory(at: activityURL, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "activity" }
            for file in activityFiles { try synchronizeFile(file) }
            try synchronizeDirectory(activityURL)
        }
        let directories = [supportDirectory, legacyURL.deletingLastPathComponent(), factsURL.deletingLastPathComponent()]
        for directory in directories where fileManager.fileExists(atPath: directory.path) {
            try synchronizeDirectory(directory)
        }
        userDefaults.synchronize()
    }

    static func clear(in supportDirectory: URL) throws {
        let url = journalURL(in: supportDirectory)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        try synchronizeDirectory(supportDirectory)
    }

    private static func defaultLegacyDatabaseURL(in support: URL) throws -> URL {
        support.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("river-diary.db")
    }

    private static func defaultV2DatabaseURL(in support: URL) throws -> URL {
        support.appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("V2", isDirectory: true)
            .appendingPathComponent("river-v2.db")
    }

    private static func restoreFile(_ snapshot: RestoreRecoveryFile, to url: URL) throws {
        if let contents = snapshot.contents {
            try writeDurably(contents, to: url)
            try LocalStorageProtection.protectFile(at: url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private static func restoreActivitySessions(_ sessions: [ActivitySession], at directory: URL) throws {
        let parent = directory.deletingLastPathComponent()
        try LocalStorageProtection.ensurePrivateDirectory(at: parent)
        let staging = parent.appendingPathComponent("Activity-recovery-\(UUID().uuidString)", isDirectory: true)
        let previous = parent.appendingPathComponent("Activity-previous-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: staging)
        defer { try? fileManager.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let grouped = Dictionary(grouping: sessions, by: \.dayKey)
        for (dayKey, daySessions) in grouped.sorted(by: { $0.key < $1.key }) {
            let file = staging.appendingPathComponent("\(dayKey).activity")
            let encrypted = try StateEncryption.encrypt(encoder.encode(daySessions.sorted { $0.start < $1.start }))
            try writeDurably(encrypted, to: file)
            try LocalStorageProtection.protectFile(at: file)
        }

        let hadPrevious = fileManager.fileExists(atPath: directory.path)
        if hadPrevious { try fileManager.moveItem(at: directory, to: previous) }
        do {
            try fileManager.moveItem(at: staging, to: directory)
            try LocalStorageProtection.ensurePrivateDirectory(at: directory)
            if hadPrevious { try fileManager.removeItem(at: previous) }
            let orphans = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.lastPathComponent.hasPrefix("Activity-previous-") }
            for orphan in orphans where fileManager.fileExists(atPath: orphan.path) {
                try fileManager.removeItem(at: orphan)
            }
            try synchronizeDirectory(parent)
        } catch {
            if hadPrevious, !fileManager.fileExists(atPath: directory.path), fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: directory)
            }
            throw error
        }
    }

    private static func writeDurably(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try LocalStorageProtection.ensurePrivateDirectory(at: parent)
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).pending-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw recoveryError("无法创建恢复记录临时文件。")
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try LocalStorageProtection.protectFile(at: temporary)
            let status = temporary.path.withCString { source in
                destination.path.withCString { target in Darwin.rename(source, target) }
            }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try synchronizeDirectory(parent)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func synchronizeFile(_ file: URL) throws {
        let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func recoveryError(_ message: String) -> NSError {
        NSError(domain: "RiverDiaryMac.RestoreRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
