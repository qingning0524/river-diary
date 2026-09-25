import CryptoKit
import Foundation
import Security

enum StateEncryptionError: LocalizedError {
    case keychainStatus(OSStatus)
    case malformedFile
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status): "钥匙串读取失败（\(status)）"
        case .malformedFile: "本地状态文件格式不正确"
        case .decryptionFailed: "本地状态解密失败"
        }
    }
}

enum StateEncryption {
    private static let magic = Data("RDMACv1\n".utf8)
    private static let service = "RiverDiaryMac.state"
    private static let account = "journal-encryption-key"
    private static let keyFileName = "journal-encryption.key"
    private static let fileManager = FileManager.default

    static func encrypt(_ plaintext: Data) throws -> Data {
        let key = try encryptionKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)

        guard let combined = sealed.combined else {
            throw StateEncryptionError.malformedFile
        }

        return magic + combined
    }

    static func decrypt(_ fileData: Data) throws -> Data {
        guard fileData.starts(with: magic), fileData.count > magic.count + 28 else {
            throw StateEncryptionError.malformedFile
        }

        let combined = fileData.dropFirst(magic.count)
        let box = try AES.GCM.SealedBox(combined: combined)
        let key = try encryptionKey()
        return try AES.GCM.open(box, using: key)
    }

    static func hasStateEncryptionKey() -> Bool {
        loadLocalKey() != nil
    }

    static func derivedDatabaseKey(purpose: String) throws -> String {
        let masterKey = try encryptionKey()
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: Data("RiverDiaryMac.SQLCipher.v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: 32
        )
        return derivedKey.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private static func encryptionKey() throws -> SymmetricKey {
        if let localKey = loadLocalKey() {
            return localKey
        }

        // Existing installations may still have their key in Keychain. Migrate
        // it once, then keep normal launches independent from Keychain ACLs.
        do {
            let migratedKey = try keychainKey()
            try saveLocalKey(migratedKey)
            return migratedKey
        } catch StateEncryptionError.keychainStatus(let status) where status == errSecItemNotFound {
            // First launch on a clean installation: create a local key below.
        }

        let key = SymmetricKey(size: .bits256)
        try saveLocalKey(key)
        return key
    }

    private static func keychainKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let keyData = item as? Data {
            return SymmetricKey(data: keyData)
        }

        throw StateEncryptionError.keychainStatus(status)
    }

    private static func loadLocalKey() -> SymmetricKey? {
        guard let url = localKeyURL,
              let keyData = try? Data(contentsOf: url),
              keyData.count == 32 else { return nil }
        return SymmetricKey(data: keyData)
    }

    private static func saveLocalKey(_ key: SymmetricKey) throws {
        guard let url = localKeyURL,
              let directory = localKeyDirectory else {
            throw StateEncryptionError.keychainStatus(errSecIO)
        }

        let keyData = key.withUnsafeBytes { Data($0) }
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        try keyData.write(to: url, options: .atomic)
        try LocalStorageProtection.protectFile(at: url)
    }

    private static var localKeyDirectory: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
    }

    private static var localKeyURL: URL? {
        localKeyDirectory?.appendingPathComponent(keyFileName, isDirectory: false)
    }
}
