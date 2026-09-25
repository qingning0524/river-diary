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
        // Startup must not touch Keychain. SecItemCopyMatching can invoke a
        // macOS ACL/password prompt even when the app only wants to know
        // whether a key exists. The encrypted local fallback is sufficient
        // for this non-sensitive presence check.
        AISecureKeyStore.hasKey(for: profileID)
    }

    static func readKey(for profileID: String) -> String? {
        guard !profileID.isEmpty else { return nil }

        // Prefer the encrypted local copy so normal startup and requests do
        // not need to unlock the Keychain. Only fall back to Keychain for
        // legacy installs or when the local copy is missing.
        if let localKey = AISecureKeyStore.readKey(for: profileID) {
            return localKey
        }

        if let key = readKeychain(for: profileID) {
            try? AISecureKeyStore.saveKey(key, for: profileID)
            return key
        }
        return nil
    }

    private static func readKeychain(for profileID: String) -> String? {
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
        return nil
    }

    static func saveKey(_ value: String, for profileID: String) throws {
        guard !profileID.isEmpty, !value.isEmpty else { return }

        // Write the encrypted fallback first and retain it permanently. The
        // macOS Keychain can be unavailable briefly (locked session, changed
        // ACL, or a first-launch race); deleting the fallback after a
        // successful Keychain write caused repeated API-key prompts later.
        var secureStoreError: Error?
        do {
            try AISecureKeyStore.saveKey(value, for: profileID)
        } catch {
            secureStoreError = error
        }

        do {
            try saveKeychain(value, for: profileID)
        } catch {
            if let secureStoreError {
                throw secureStoreError
            }
        }
    }

    private static func saveKeychain(_ value: String, for profileID: String) throws {
        guard let data = value.data(using: .utf8), !data.isEmpty else { return }
        let query = keychainQuery(account: account(for: profileID))
        let updateStatus = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw AIKeychainError.invalidStatus(updateStatus) }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(query as CFDictionary, [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ] as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw AIKeychainError.invalidStatus(retryStatus)
            }
            return
        }
        throw AIKeychainError.invalidStatus(addStatus)
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
        let appDirectory = base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        let directory = appDirectory.appendingPathComponent("Keys", isDirectory: true)
        do {
            try LocalStorageProtection.ensurePrivateDirectory(at: appDirectory)
            try LocalStorageProtection.ensurePrivateDirectory(at: directory)
            return directory.appendingPathComponent("api-keys.bin")
        } catch {
            return nil
        }
    }

    private static func loadKeys() -> [String: String] {
        guard let url = keyFileURL,
              let raw = try? Data(contentsOf: url),
              let decrypted = try? StateEncryption.decrypt(raw),
              let decoded = try? JSONDecoder().decode([String: String].self, from: decrypted) else {
            return [:]
        }
        try? LocalStorageProtection.protectFile(at: url)
        return decoded
    }

    private static func persist(_ keys: [String: String]) throws {
        guard let url = keyFileURL else { return }
        let plaintext = try JSONEncoder().encode(keys)
        try StateEncryption.encrypt(plaintext).write(to: url, options: .atomic)
        try LocalStorageProtection.protectFile(at: url)
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
