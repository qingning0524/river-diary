import Foundation
import RiverDiaryCore

/// 跨 Mac 可移植备份的容器。
///
/// 外层用同步恢复码（`SyncEncryptionKey`）做 AES-GCM；内层是本机完整备份
/// 的 journal payload，以及两个数据库的**明文 SQLite 字节**。明文只在容器
/// 内存在，落盘前已被外层加密；恢复时先用目标 Mac 的本机密钥重新加密数据库，
/// 再走现有的 `restoreFullBackup` 回滚/恢复流程。
struct PortableBackupPayload: Codable {
    static let currentVersion = 1
    var version = currentVersion
    var exportedAt: Date
    var journal: Data
    var legacyDatabasePlaintext: Data?
    var v2DatabasePlaintext: Data?
}

enum PortableBackupArchiveError: LocalizedError {
    case notPortableBackup
    case unsupportedVersion
    case recoveryCodeRequired
    case corrupted

    var errorDescription: String? {
        switch self {
        case .notPortableBackup: "文件不是 River Diary 可移植备份。"
        case .unsupportedVersion: "可移植备份版本高于当前应用支持范围。"
        case .recoveryCodeRequired: "恢复可移植备份前，请先在同步设置中导入恢复码。"
        case .corrupted: "可移植备份无法解密或内容损坏；请确认恢复码正确。"
        }
    }
}

enum PortableBackupArchive {
    static let kind = "portable_backup"

    static func seal(
        journal: Data,
        legacyDatabasePlaintext: Data?,
        v2DatabasePlaintext: Data?,
        using key: SyncEncryptionKey
    ) throws -> Data {
        let payload = PortableBackupPayload(
            exportedAt: Date(),
            journal: journal,
            legacyDatabasePlaintext: legacyDatabasePlaintext,
            v2DatabasePlaintext: v2DatabasePlaintext
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let id = "portable-backup-\(Int(Date().timeIntervalSince1970))"
        let object = try EncryptedReplicationObject.seal(plaintext, id: id, kind: kind, using: key)
        return try encoder.encode(object)
    }

    static func open(_ data: Data, using key: SyncEncryptionKey) throws -> PortableBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let object = try? decoder.decode(EncryptedReplicationObject.self, from: data),
              object.kind == kind,
              object.protocolVersion == EncryptedReplicationObject.currentProtocolVersion else {
            throw PortableBackupArchiveError.notPortableBackup
        }
        guard let plaintext = try? object.open(using: key) else {
            throw PortableBackupArchiveError.corrupted
        }
        guard let payload = try? decoder.decode(PortableBackupPayload.self, from: plaintext) else {
            throw PortableBackupArchiveError.corrupted
        }
        guard (1...PortableBackupPayload.currentVersion).contains(payload.version) else {
            throw PortableBackupArchiveError.unsupportedVersion
        }
        return payload
    }

    /// 把可移植 payload 还原成当前 Mac 可用的本机加密备份文件。
    /// 调用方负责提供已用目标本机密钥加密的两个数据库快照。
    static func localBackupData(
        from payload: PortableBackupPayload,
        legacyDatabaseSnapshot: Data?,
        v2DatabaseSnapshot: Data?
    ) throws -> Data {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var journal = try? decoder.decode(LocalBackupPayload.self, from: payload.journal) else {
            throw PortableBackupArchiveError.corrupted
        }
        journal.legacyDatabaseSnapshot = legacyDatabaseSnapshot
        journal.v2DatabaseSnapshot = v2DatabaseSnapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try StateEncryption.encrypt(try encoder.encode(journal))
    }
}
