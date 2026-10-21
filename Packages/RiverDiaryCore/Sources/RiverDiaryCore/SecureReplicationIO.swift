import Foundation
import Security

public enum SecureStoreError: Error, Equatable, LocalizedError {
    case keychainStatus(OSStatus)
    case missingValue
    case accessDenied

    public var errorDescription: String? {
        switch self {
        case .keychainStatus(let status) where status == errSecMissingEntitlement:
            "应用缺少 Keychain access-group 权限 (OSStatus \(status))"
        case .keychainStatus(let status) where status == errSecInteractionNotAllowed:
            "钥匙串暂不可访问，请解锁设备后重试 (OSStatus \(status))"
        case .keychainStatus(let status): "钥匙串操作失败 (OSStatus \(status))"
        case .missingValue: "钥匙串没有返回所需数据"
        case .accessDenied: "钥匙串访问被拒绝"
        }
    }
}

public enum RiverSecureStore {
    private static var service: String { keychainServiceName("local.riverdiary.node") }

    /// QA/演示启动可以用独立 Keychain 命名空间，避免读到开发机已有的
    /// 正式条目并触发 ACL 弹窗。正常启动不设置该环境变量。
    public static var keychainNamespaceSuffix: String {
        guard let raw = ProcessInfo.processInfo.environment["RIVER_DIARY_KEYCHAIN_NAMESPACE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "" }
        let safe = raw.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return safe.isEmpty ? "" : ".\(safe)"
    }

    /// QA app bundles must never read or overwrite production Keychain items.
    /// iOS also gets bundle-scoped access groups; macOS uses this namespace
    /// because its generic-password queries otherwise share the user's login
    /// Keychain across app bundle identifiers.
    public static func keychainServiceName(_ baseName: String,
                                           bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let scoped = bundleIdentifier?.hasSuffix(".qa") == true ? "\(baseName).qa" : baseName
        return scoped + keychainNamespaceSuffix
    }

    public static func loadOrCreateDeviceID(kind: String) throws -> RiverDeviceID {
        if let saved = try? read(account: "device-id"),
           let value = String(data: saved, encoding: .utf8), !value.isEmpty {
            return RiverDeviceID(rawValue: value)
        }
        let identity = RiverDeviceID(kind: kind)
        do {
            try write(Data(identity.rawValue.utf8), account: "device-id")
            return identity
        } catch {
            #if targetEnvironment(simulator)
            // 模拟器构建没有 provisioning profile 时 Keychain 会返回
            // errSecMissingEntitlement。真机不受影响；这里只为本地优先的
            // 模拟器验收提供可丢弃的设备身份，不能用于生产数据。
            if case SecureStoreError.keychainStatus(let status) = error,
               status == errSecMissingEntitlement,
               let fallback = simulatorDeviceID(kind: kind) {
                return fallback
            }
            #endif
            throw error
        }
    }

    #if targetEnvironment(simulator)
    private static func simulatorDeviceID(kind: String) -> RiverDeviceID? {
        let key = "river.simulator.device-id.\(kind)"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return RiverDeviceID(rawValue: saved)
        }
        let identity = RiverDeviceID(kind: kind)
        UserDefaults.standard.set(identity.rawValue, forKey: key)
        return identity
    }
    #endif

    public static func saveSyncKey(_ key: SyncEncryptionKey) throws {
        try write(key.rawRepresentation, account: "sync-encryption-key-v1")
    }

    public static func loadSyncKey() throws -> SyncEncryptionKey {
        try SyncEncryptionKey(rawRepresentation: read(account: "sync-encryption-key-v1"))
    }

    public static func hasSyncKey() -> Bool {
        (try? loadSyncKey()) != nil
    }

    public static func importSyncKey(code: String) throws -> SyncEncryptionKey {
        let key = try SyncEncryptionKey(importCode: code)
        try saveSyncKey(key)
        return key
    }

    public static func saveNetworkAIKey(_ value: String) throws {
        try write(Data(value.utf8), account: "network-ai-key-v1")
    }

    public static func loadNetworkAIKey() throws -> String {
        guard let value = String(data: try read(account: "network-ai-key-v1"), encoding: .utf8), !value.isEmpty else {
            throw SecureStoreError.missingValue
        }
        return value
    }

    public static func hasNetworkAIKey() -> Bool {
        (try? loadNetworkAIKey()) != nil
    }

    public static func deleteNetworkAIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "network-ai-key-v1"
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStoreError.keychainStatus(status)
        }
    }

    private static func read(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw SecureStoreError.keychainStatus(status) }
        guard let data = item as? Data else { throw SecureStoreError.missingValue }
        return data
    }

    private static func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecureStoreError.keychainStatus(update) }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SecureStoreError.keychainStatus(status)
        }
        if status == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retry == errSecSuccess else { throw SecureStoreError.keychainStatus(retry) }
        }
    }
}

public enum SecurityScopedBookmark {
    public static func create(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

public enum CoordinatedFileIO {
    public static func read(_ url: URL) throws -> Data {
        var result: Result<Data, Error>?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    public static func writeAtomically(_ data: Data, to url: URL) throws {
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public static func writeImmutable(_ data: Data, to url: URL, objectID: String) throws {
        var writeError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existing = try Data(contentsOf: coordinatedURL)
                    guard existing == data else {
                        throw ReplicationIOError.immutableObjectCollision(objectID)
                    }
                    return
                }
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

public enum ReplicationIOError: Error, Equatable {
    case immutableObjectCollision(String)
    case invalidObjectPath
}

public struct LocatedEncryptedReplicationObject: Sendable {
    public let deviceID: RiverDeviceID
    public let stream: String
    public let object: EncryptedReplicationObject

    public init(deviceID: RiverDeviceID, stream: String, object: EncryptedReplicationObject) {
        self.deviceID = deviceID
        self.stream = stream
        self.object = object
    }
}

/// Writes one immutable file per replication object. The selected root may be
/// an iCloud Drive folder; coordination is used for every read and write.
public struct ReplicationDirectory: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public func readObject(id: String, stream: String, deviceID: RiverDeviceID) throws -> EncryptedReplicationObject? {
        let safeDevice = Self.safeComponent(deviceID.rawValue)
        let safeStream = Self.safeComponent(stream)
        let safeID = Self.safeComponent(id)
        guard !safeDevice.isEmpty, !safeStream.isEmpty, !safeID.isEmpty else {
            throw ReplicationIOError.invalidObjectPath
        }
        let url = rootURL.appendingPathComponent("Devices", isDirectory: true)
            .appendingPathComponent(safeDevice, isDirectory: true)
            .appendingPathComponent(safeStream, isDirectory: true)
            .appendingPathComponent("\(safeID).rdo")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(EncryptedReplicationObject.self, from: CoordinatedFileIO.read(url))
    }

    public func publish(_ object: EncryptedReplicationObject, stream: String, deviceID: RiverDeviceID) throws -> URL {
        let safeDevice = Self.safeComponent(deviceID.rawValue)
        let safeStream = Self.safeComponent(stream)
        let safeID = Self.safeComponent(object.id)
        guard !safeDevice.isEmpty, !safeStream.isEmpty, !safeID.isEmpty else {
            throw ReplicationIOError.invalidObjectPath
        }
        let directory = rootURL
            .appendingPathComponent("Devices", isDirectory: true)
            .appendingPathComponent(safeDevice, isDirectory: true)
            .appendingPathComponent(safeStream, isDirectory: true)
        let url = directory.appendingPathComponent("\(safeID).rdo")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(object)
        try CoordinatedFileIO.writeImmutable(bytes, to: url, objectID: object.id)
        return url
    }

    public func scan() throws -> [EncryptedReplicationObject] {
        try scanFiles().map(\.object)
    }

    public func scanFiles() throws -> [LocatedEncryptedReplicationObject] {
        let devicesURL = rootURL.appendingPathComponent("Devices", isDirectory: true)
        guard FileManager.default.fileExists(atPath: devicesURL.path) else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: devicesURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        var objects: [LocatedEncryptedReplicationObject] = []
        for case let url as URL in enumerator where url.pathExtension == "rdo" {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let stream = url.deletingLastPathComponent().lastPathComponent
            let device = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let object = try decoder.decode(EncryptedReplicationObject.self, from: CoordinatedFileIO.read(url))
            objects.append(LocatedEncryptedReplicationObject(
                deviceID: RiverDeviceID(rawValue: device),
                stream: stream,
                object: object
            ))
        }
        return objects.sorted { lhs, rhs in
            if lhs.deviceID != rhs.deviceID { return lhs.deviceID.rawValue < rhs.deviceID.rawValue }
            if lhs.stream != rhs.stream { return lhs.stream < rhs.stream }
            return lhs.object.id < rhs.object.id
        }
    }

    private static func safeComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
}
