import Foundation
import Security

enum AIKeychainError: LocalizedError {
    case invalidStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStatus(let status): "钥匙串保存失败（\(status)）"
        }
    }
}

enum AIKeychain {
    private static let service = "RiverDiaryMac.ai"
    private static let legacyAccount = "footprint-api-key"

    private static func account(for profileID: String) -> String {
        "footprint-api-key-\(profileID)"
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func hasKey(for profileID: String) -> Bool {
        var query = keychainQuery(account: account(for: profileID))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }

        var legacyQuery = keychainQuery(account: legacyAccount)
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess { return true }
        return AISecureKeyStore.hasKey(for: profileID)
    }

    static func readKey(for profileID: String) -> String? {
        var item: CFTypeRef?
        var query = keychainQuery(account: account(for: profileID))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var status = SecItemCopyMatching(query as CFDictionary, &item)

        if status != errSecSuccess {
            query = keychainQuery(account: legacyAccount)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(query as CFDictionary, &item)
        }

        if status == errSecSuccess, let data = item as? Data,
           let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        return AISecureKeyStore.readKey(for: profileID)
    }

    static func saveKey(_ value: String, for profileID: String) throws {
        try AISecureKeyStore.saveKey(value, for: profileID)
        let keyData = Data(value.utf8)
        var query = keychainQuery(account: account(for: profileID))
        let update: [String: Any] = [kSecValueData as String: keyData]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AIKeychainError.invalidStatus(updateStatus)
        }

        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AIKeychainError.invalidStatus(addStatus)
        }
    }

    static func deleteKey(for profileID: String) {
        AISecureKeyStore.deleteKey(for: profileID)
        SecItemDelete(keychainQuery(account: account(for: profileID)) as CFDictionary)
        SecItemDelete(keychainQuery(account: legacyAccount) as CFDictionary)
    }
}

/// 加密文件作为 API Key 的备用存储。应用已用同一机制保护日记状态。
enum AISecureKeyStore {
    private static var keyFileURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("RiverDiaryMac", isDirectory: true).appendingPathComponent("Keys", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("api-keys.bin")
    }

    private static func loadKeys() -> [String: String] {
        guard let url = keyFileURL,
              let raw = try? Data(contentsOf: url),
              let decrypted = try? StateEncryption.decrypt(raw),
              let decoded = try? JSONDecoder().decode([String: String].self, from: decrypted) else {
            return [:]
        }
        return decoded
    }

    private static func persist(_ keys: [String: String]) throws {
        guard let url = keyFileURL else { return }
        let plaintext = try JSONEncoder().encode(keys)
        try StateEncryption.encrypt(plaintext).write(to: url, options: .atomic)
    }

    static func hasKey(for profileID: String) -> Bool {
        !(loadKeys()[profileID] ?? "").isEmpty
    }

    static func readKey(for profileID: String) -> String? {
        let key = loadKeys()[profileID] ?? ""
        return key.isEmpty ? nil : key
    }

    static func saveKey(_ value: String, for profileID: String) throws {
        var keys = loadKeys()
        keys[profileID] = value
        try persist(keys)
    }

    static func deleteKey(for profileID: String) {
        var keys = loadKeys()
        keys.removeValue(forKey: profileID)
        try? persist(keys)
    }
}
