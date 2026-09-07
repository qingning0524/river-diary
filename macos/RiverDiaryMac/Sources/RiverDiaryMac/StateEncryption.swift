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
        (try? encryptionKey()) != nil
    }

    private static func encryptionKey() throws -> SymmetricKey {
        var query: [String: Any] = [
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

        guard status == errSecItemNotFound else {
            throw StateEncryptionError.keychainStatus(status)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw StateEncryptionError.keychainStatus(addStatus)
        }

        return key
    }
}
