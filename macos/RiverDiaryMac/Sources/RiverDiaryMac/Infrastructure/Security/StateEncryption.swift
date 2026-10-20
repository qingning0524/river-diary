import CryptoKit
import Foundation
import RiverDiaryCore
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
    /// 密钥文件 v2：AES-GCM(密钥, 包装密钥)，包装密钥只存在 Keychain。
    private static let wrappedKeyMagic = Data("RDMKEYv2\n".utf8)
    private static let service = RiverSecureStore.keychainServiceName("RiverDiaryMac.state")
    private static let account = "journal-encryption-key"
    private static let wrappingAccount = "journal-encryption-key-wrapper"
    private static let keyFileName = "journal-encryption.key"
    private static let fileManager = FileManager.default
    private static let keyCacheLock = NSLock()
    private static var keyCache: SymmetricKey?

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
        if isTestProcess && !isIsolatedTestProcess { return false }
        return loadStoredKeyFile() != nil
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
        // 整个解析过程串行：两个线程同时首解时可能各自生成密钥，
        // 内存里拿到的密钥会和最后落盘的那份不一致——数据从此解不开。
        keyCacheLock.lock()
        defer { keyCacheLock.unlock() }
        if let keyCache { return keyCache }
        let key = try resolveEncryptionKey()
        keyCache = key
        return key
    }

    private static func resolveEncryptionKey() throws -> SymmetricKey {
        if isTestProcess {
            guard isIsolatedTestProcess else {
                throw NSError(
                    domain: "RiverDiaryMac.TestIsolation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Mac 测试必须通过 scripts/test_macos_isolated.sh 启动，避免访问正式用户目录。"]
                )
            }
            // 测试进程保持纯文件路径（沙盒里没有可靠 Keychain），不参与包装迁移。
            if let localKey = loadLocalKey() { return localKey }
            let key = SymmetricKey(size: .bits256)
            try saveLocalKey(key)
            return key
        }

        // 主路径：密钥文件仍是主副本（历史上 Keychain ACL 提示曾让普通启动
        // 不可靠，且文件能随 Time Machine 恢复），但文件内容用 Keychain 里的
        // 包装密钥加密——拿到文件的进程还要过 Keychain ACL 这一关。
        switch loadStoredKeyFile() {
        case .wrapped(let sealed):
            return try unwrapMasterKey(sealed)
        case .raw(let key):
            // 旧版明文密钥文件：先原样使用，再尽力迁移成包装格式。
            try? storeMasterKey(key)
            return key
        case nil:
            break
        }

        // 密钥文件缺失：沿用旧迁移链（Keychain 主密钥 → 新建）。
        do {
            let migratedKey = try keychainKey()
            try storeMasterKey(migratedKey)
            return migratedKey
        } catch StateEncryptionError.keychainStatus(let status) where status == errSecItemNotFound {
            // 首次启动：新建密钥。
        }

        let key = SymmetricKey(size: .bits256)
        try storeMasterKey(key)
        return key
    }

    private enum StoredKeyFile {
        case raw(SymmetricKey)
        case wrapped(Data)
    }

    private static func loadStoredKeyFile() -> StoredKeyFile? {
        guard let url = localKeyURL, let data = try? Data(contentsOf: url) else { return nil }
        if data.count == 32 { return .raw(SymmetricKey(data: data)) }
        if data.starts(with: wrappedKeyMagic), data.count > wrappedKeyMagic.count + 28 {
            return .wrapped(data.dropFirst(wrappedKeyMagic.count))
        }
        return nil
    }

    private static func unwrapMasterKey(_ sealed: Data) throws -> SymmetricKey {
        let wrapper = try keychainWrappingKey()
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let keyData = try AES.GCM.open(box, using: wrapper)
            guard keyData.count == 32 else { throw StateEncryptionError.malformedFile }
            return SymmetricKey(data: keyData)
        } catch let error as StateEncryptionError {
            throw error
        } catch {
            // 包装密钥与密文不匹配（例如 Keychain 被另一台机器的数据覆盖）。
            // 绝不能在这里静默新建密钥：那会让全部旧数据变成永远解不开的密文。
            throw StateEncryptionError.decryptionFailed
        }
    }

    /// Keychain 里只放一把 32 字节包装密钥（非 ThisDeviceOnly：登录钥匙串可随
    /// 备份恢复，不至于还原系统后密钥凭空消失）。应用自己的条目读取不出提示。
    private static func keychainWrappingKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: wrappingAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        if status == errSecItemNotFound {
            let key = SymmetricKey(size: .bits256)
            let keyData = key.withUnsafeBytes { Data($0) }
            var addQuery = query
            addQuery[kSecValueData as String] = keyData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw StateEncryptionError.keychainStatus(addStatus)
            }
            return key
        }
        throw StateEncryptionError.keychainStatus(status)
    }

    private static func storeMasterKey(_ key: SymmetricKey) throws {
        // 包装失败（Keychain 暂不可用）时退回明文写入：密钥文件必须先写出来，
        // 启动才能继续；这与旧行为一致，只是常规路径下文件不再明文。
        let keyData = key.withUnsafeBytes { Data($0) }
        let payload: Data
        if let wrapper = try? keychainWrappingKey(),
           let combined = try? AES.GCM.seal(keyData, using: wrapper).combined {
            payload = wrappedKeyMagic + combined
        } else {
            payload = keyData
        }
        guard let url = localKeyURL,
              let directory = localKeyDirectory else {
            throw StateEncryptionError.keychainStatus(errSecIO)
        }
        try LocalStorageProtection.ensurePrivateDirectory(at: directory)
        try payload.write(to: url, options: .atomic)
        try LocalStorageProtection.protectFile(at: url)
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

    private static var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["RIVER_DIARY_MAC_TEST_HOME"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    private static var isIsolatedTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let testHome = environment["RIVER_DIARY_MAC_TEST_HOME"],
              let fixedHome = environment["CFFIXED_USER_HOME"],
              let userHome = environment["HOME"] else { return false }
        return canonicalPath(testHome) == canonicalPath(fixedHome)
            && canonicalPath(fixedHome) != canonicalPath(userHome)
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }
}
