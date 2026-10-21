import Combine
import Foundation
import Security

public enum RiverAccountPlatform: String {
    case ios
    case macos
}

public struct RiverAccountSession: Codable, Equatable {
    public let email: String
    public let userID: String
    public let accessToken: String
    public let refreshToken: String
    public let revokeToken: String
    public let accessExpiresAt: Date
    public let pendingRefreshRequestID: String?

    public init(email: String, userID: String, accessToken: String, refreshToken: String, revokeToken: String, accessExpiresAt: Date, pendingRefreshRequestID: String? = nil) {
        self.email = email
        self.userID = userID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.revokeToken = revokeToken
        self.accessExpiresAt = accessExpiresAt
        self.pendingRefreshRequestID = pendingRefreshRequestID
    }
}

public struct RiverAccountEntitlement: Decodable, Identifiable, Equatable {
    public let product_code: String
    public let active: Bool
    public let starts_at: String
    public let expires_at: String?
    public let permanent: Bool

    public var id: String { product_code }
}

public struct RiverRedemptionReceipt: Decodable, Equatable {
    public let status: String
    public let product_code: String
    public let starts_at: String
    public let expires_at: String?
    public let permanent: Bool
}

public struct RiverAccountAPIError: LocalizedError, Equatable {
    public let status: Int
    public let code: String

    public var errorDescription: String? {
        switch code {
        case "rate_limited": "操作太频繁，请稍后再试。"
        case "invalid_credentials": "邮箱或密码不正确。若尚未设置密码，可以先使用验证码登录。"
        case "password_policy_failed": "请使用 15–128 个字符的密码，避免常见密码或邮箱地址。"
        case "terms_consent_required": "请先阅读并同意服务与隐私说明。"
        case "activation_code_invalid": "兑换码无效、已使用、已撤销或已过期。"
        case "auth_required", "reauthentication_required", "session_reuse_detected": "账号会话已过期，请重新登录。"
        case "temporarily_unavailable": "账号服务暂时不可用，请稍后重试。"
        case "invalid_or_expired_challenge": "验证码不正确或已过期，请重新获取。"
        case "local_profile_account_mismatch": "此设备上的本地资料已绑定另一个账号。当前版本不支持直接切换账号，以免混用两个人的日记资料。"
        default: "账号服务请求失败（\(status)）。请稍后重试。"
        }
    }
}

@MainActor
public final class RiverAccountSessionStore: ObservableObject {
    public static let apiBaseURL = URL(string: "https://api.flowriver.xyz/v1")!

    @Published public private(set) var session: RiverAccountSession?
    @Published public private(set) var entitlements: [RiverAccountEntitlement] = []
    @Published public private(set) var isBusy = false
    @Published public private(set) var lastError: String?

    public var isSignedIn: Bool { session != nil }
    public var accountEmail: String? { session?.email }
    public var hasPremiumEntitlement: Bool {
        entitlements.contains { $0.product_code == "riverdiary_premium" && $0.active }
    }

    /// 本机资料 owner 的读写钩子。由平台层注入，指向本机数据库/受保护文件；
    /// 不能用 Keychain 的 ThisDeviceOnly 绑定代替它，否则换机恢复后 owner 会丢失。
    public var localProfileOwnerProvider: (() -> String?)?
    public var localProfileOwnerWriter: ((String) throws -> Void)?
    public var localProfileOwnerClearer: (() throws -> Void)?

    /// Keychain 里的旧绑定，只用于迁移和兼容，不作为唯一事实来源。
    public var boundProfileUserID: String? {
        guard let data = vault.read(profileBindingStoreKey) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 把旧安装的 Keychain 绑定迁移到本机资料 owner；只在 owner 为空时写入。
    public func seedLocalProfileOwnerFromKeychain() {
        guard localProfileOwnerProvider?() == nil, let bound = boundProfileUserID else { return }
        try? localProfileOwnerWriter?(bound)
    }

    /// 本机资料已有 owner 且与当前会话不一致时，退出当前会话。
    /// owner 在本机库里，换机恢复后仍然可靠；会话只是凭据。
    public func enforceLocalProfileOwner() async {
        guard let owner = localProfileOwnerProvider?(), let current = session, current.userID != owner else { return }
        await signOut()
        lastError = "本机资料已绑定另一个账号，已退出当前登录。请使用原账号，或导出/认领本机资料后再切换。"
    }

    private let platform: RiverAccountPlatform
    private let deviceName: String
    private let vault: RiverAccountVaultStorage
    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private var clientInstanceID: String
    private let sessionStoreKey = "account-session-v1"
    private let instanceStoreKey = "account-client-instance-v1"
    private let profileBindingStoreKey = "account-profile-binding-v1"
    private let pendingRevocationsStoreKey = "account-pending-revocations-v1"
    private var hasLoadedPersistedSession = false
    private var isDrainingRevocations = false
    // Every login/logout invalidates responses issued by an older context.
    private var generation = UUID()
    private var refreshTask: (id: UUID, task: Task<Void, Error>)?

    public convenience init(platform: RiverAccountPlatform, deviceName: String, loadPersistedSession: Bool = true) {
        self.init(platform: platform, deviceName: deviceName, loadPersistedSession: loadPersistedSession,
                  vault: RiverAccountVault(), transport: { try await URLSession.shared.data(for: $0) })
    }

    init(platform: RiverAccountPlatform, deviceName: String, loadPersistedSession: Bool = true,
         vault: RiverAccountVaultStorage, transport: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.vault = vault
        self.transport = transport
        self.platform = platform
        self.deviceName = String(deviceName.prefix(80))
        // 本地优先：client instance 不是秘密，先用 UserDefaults，避免启动时
        // 为了一个非敏感 ID 去碰 Keychain。真正的会话按需加载。
        if let value = UserDefaults.standard.string(forKey: instanceStoreKey), UUID(uuidString: value) != nil {
            clientInstanceID = value
        } else {
            let value = UUID().uuidString.lowercased()
            clientInstanceID = value
            UserDefaults.standard.set(value, forKey: instanceStoreKey)
        }
        if loadPersistedSession {
            restorePersistedSession()
        }
    }

    /// 本地优先后，启动时不再无条件读取账号 Keychain；需要账号能力时再加载。
    /// 这避免只有本机日记、从未绑定账号的用户在启动时被钥匙串 ACL 挡住。
    public func loadPersistedSessionIfNeeded() {
        restorePersistedSession()
    }

    private func restorePersistedSession() {
        guard !hasLoadedPersistedSession else { return }
        hasLoadedPersistedSession = true
        if let savedInstance = vault.read(instanceStoreKey),
           let value = String(data: savedInstance, encoding: .utf8), UUID(uuidString: value) != nil {
            clientInstanceID = value
            UserDefaults.standard.set(value, forKey: instanceStoreKey)
        }
        if let saved = vault.read(sessionStoreKey), let decoded = try? JSONDecoder().decode(RiverAccountSession.self, from: saved) {
            // A durable logout tombstone wins even if credential deletion failed.
            if !pendingRevocations().contains(decoded.revokeToken) { session = decoded }
        }
    }

    /// 给系统入口（Shortcuts、后台任务）用：不创建客户端实例、不写钥匙串，
    /// 只回答“现在是否有可用的持久登录会话”。没有会话且本机也没有资料库时，
    /// 系统入口不应创建正式库。
    public static func hasUsablePersistedSession() -> Bool {
        hasUsablePersistedSession(in: RiverAccountVault())
    }

    static func hasUsablePersistedSession(in vault: RiverAccountVaultStorage) -> Bool {
        guard let bytes = vault.read("account-session-v1"),
              let stored = try? JSONDecoder().decode(RiverAccountSession.self, from: bytes) else {
            return false
        }
        let pending: [String]
        if let pendingBytes = vault.read("account-pending-revocations-v1"),
           let decoded = try? JSONDecoder().decode([String].self, from: pendingBytes) {
            pending = decoded
        } else {
            pending = []
        }
        return !pending.contains(stored.revokeToken)
    }

    public func requestEmailCode(_ email: String) async throws -> String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 320, trimmed.contains("@") else { throw RiverAccountAPIError(status: 400, code: "invalid_request") }
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        struct Response: Decodable { let challenge_id: String }
        let response: Response = try await send(path: "/auth/email/start", method: "POST", body: ["email": trimmed], idempotencyKey: nil, accessToken: nil)
        return response.challenge_id
    }

    public func verifyEmailCode(challengeID: String, code: String, email: String, acceptTerms: Bool, idempotencyKey: String) async throws {
        let requestGeneration = beginAuthentication()
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let body: [String: Any] = [
            "challenge_id": challengeID,
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_instance_id": clientInstanceID,
            "platform": platform.rawValue,
            "device_name": deviceName,
            "accept_terms": acceptTerms
        ]
        let response: TokenResponse = try await send(path: "/auth/email/verify", method: "POST", body: body, idempotencyKey: idempotencyKey, accessToken: nil)
        try await acceptSignIn(response, email: email, generation: requestGeneration)
    }

    public func loginWithPassword(email: String, password: String, idempotencyKey: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 320, address.contains("@"), !password.isEmpty, password.utf8.count <= 512 else { throw RiverAccountAPIError(status: 400, code: "invalid_request") }
        let requestGeneration = beginAuthentication()
        isBusy = true; lastError = nil; defer { isBusy = false }
        let response: TokenResponse = try await send(path: "/auth/password/login", method: "POST", body: ["email": address, "password": password, "client_instance_id": clientInstanceID, "platform": platform.rawValue, "device_name": deviceName], idempotencyKey: idempotencyKey, accessToken: nil)
        try await acceptSignIn(response, email: address, generation: requestGeneration)
    }

    public func requestPasswordReset(_ email: String) async throws -> String {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.count <= 320, address.contains("@") else { throw RiverAccountAPIError(status: 400, code: "invalid_request") }
        isBusy = true; lastError = nil; defer { isBusy = false }
        struct Response: Decodable { let challenge_id: String }
        let response: Response = try await send(path: "/auth/password/reset/start", method: "POST", body: ["email": address], idempotencyKey: nil, accessToken: nil)
        return response.challenge_id
    }

    public func resetPassword(email: String, challengeID: String, code: String, newPassword: String, idempotencyKey: String) async throws {
        let normalized = newPassword.precomposedStringWithCanonicalMapping
        guard (15...128).contains(normalized.unicodeScalars.count), normalized.utf8.count <= 512, !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RiverAccountAPIError(status: 400, code: "password_policy_failed") }
        let requestGeneration = beginAuthentication()
        isBusy = true; lastError = nil; defer { isBusy = false }
        let response: TokenResponse = try await send(path: "/auth/password/reset/complete", method: "POST", body: ["challenge_id": challengeID, "code": code, "new_password": newPassword, "client_instance_id": clientInstanceID, "platform": platform.rawValue, "device_name": deviceName], idempotencyKey: idempotencyKey, accessToken: nil)
        try await acceptSignIn(response, email: email, generation: requestGeneration)
    }

    public func passwordEnabled() async throws -> Bool {
        struct Response: Decodable { let password_enabled: Bool }
        let response: Response = try await authenticated(path: "/me/password", method: "GET", body: nil)
        return response.password_enabled
    }

    private func beginAuthentication() -> UUID {
        generation = UUID()
        refreshTask?.task.cancel()
        refreshTask = nil
        return generation
    }

    private func acceptSignIn(_ response: TokenResponse, email: String, generation requestGeneration: UUID) async throws {
        guard generation == requestGeneration, !Task.isCancelled else {
            await revokeUnstored(response)
            throw CancellationError()
        }
        if let stored = vault.read(profileBindingStoreKey),
           let boundUserID = String(data: stored, encoding: .utf8), boundUserID != response.user.id {
            await revokeUnstored(response)
            throw RiverAccountAPIError(status: 403, code: "local_profile_account_mismatch")
        }
        // 本机资料 owner 是比 Keychain 绑定更可靠的事实来源：
        // 它能随数据库/受保护文件恢复，换机后不会被另一个账号静默认领。
        let previousOwner = localProfileOwnerProvider?()
        var wroteOwner = false
        if let owner = previousOwner {
            if owner != response.user.id {
                await revokeUnstored(response)
                throw RiverAccountAPIError(status: 403, code: "local_profile_account_mismatch")
            }
        } else if let writer = localProfileOwnerWriter {
            do {
                try writer(response.user.id)
                wroteOwner = true
            } catch {
                await revokeUnstored(response)
                throw error
            }
        }
        let previousBinding = vault.read(profileBindingStoreKey)
        do {
            try vault.write(Data(response.user.id.utf8), key: profileBindingStoreKey)
        } catch {
            if wroteOwner { try? localProfileOwnerClearer?() }
            await revokeUnstored(response)
            throw error
        }
        do {
            try save(response, email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // 会话没保存成功就不能把设备永久绑到这个账号上，否则下一次登录
            // 另一个账号会被 local_profile_account_mismatch 挡住。
            restoreProfileBinding(previousBinding)
            if wroteOwner { try? localProfileOwnerClearer?() }
            await revokeUnstored(response)
            throw error
        }
        entitlements = []
        try? await refreshEntitlements()
    }

    public func refreshEntitlements() async throws {
        let requestGeneration = generation
        struct Response: Decodable { let entitlements: [RiverAccountEntitlement] }
        let response: Response = try await authenticated(path: "/me/entitlements", method: "GET", body: nil)
        guard generation == requestGeneration, session != nil else { throw CancellationError() }
        entitlements = response.entitlements
    }

    @discardableResult
    public func redeem(code: String, idempotencyKey: String) async throws -> RiverRedemptionReceipt {
        isBusy = true
        lastError = nil
        defer { isBusy = false }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipt: RiverRedemptionReceipt = try await authenticated(path: "/me/activation-codes/redeem", method: "POST", body: ["code": normalized], idempotencyKey: idempotencyKey)
        try? await refreshEntitlements()
        return receipt
    }

    public func signOut() async {
        _ = beginAuthentication()
        let saved = session
        session = nil
        entitlements = []
        lastError = nil
        do {
            if let saved { try enqueueRevocation(saved.revokeToken) }
            try vault.remove(sessionStoreKey)
        } catch {
            lastError = "已关闭本次会话，但钥匙串清理尚未完成，请重试退出：\(error.localizedDescription)"
            return
        }
        await retryPendingSignOuts()
    }

    private func pendingRevocations() -> [String] {
        guard let data = vault.read(pendingRevocationsStoreKey) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func enqueueRevocation(_ token: String) throws {
        var pending = pendingRevocations()
        if !pending.contains(token) { pending.append(token) }
        try vault.write(try JSONEncoder().encode(pending), key: pendingRevocationsStoreKey)
    }

    /// The queue holds revoke-only capabilities, never access/refresh credentials.
    /// Retry at startup and after explicit logout; a failed delivery stays durable.
    public func retryPendingSignOuts() async {
        guard !isDrainingRevocations else { return }
        isDrainingRevocations = true
        defer { isDrainingRevocations = false }
        while let token = pendingRevocations().first {
            do {
                // Never erase the tombstone while an undeleted session could reload.
                if let bytes = vault.read(sessionStoreKey),
                   let stored = try? JSONDecoder().decode(RiverAccountSession.self, from: bytes),
                   stored.revokeToken == token {
                    try vault.remove(sessionStoreKey)
                }
                let body = try JSONSerialization.data(withJSONObject: ["revoke_token": token])
                let _: EmptyResponse = try await sendRaw(path: "/auth/logout", method: "POST", data: body,
                    idempotencyKey: nil, accessToken: nil, allowEmptyResponse: true)
                let remaining = pendingRevocations().filter { $0 != token }
                if remaining.isEmpty { try vault.remove(pendingRevocationsStoreKey) }
                else { try vault.write(try JSONEncoder().encode(remaining), key: pendingRevocationsStoreKey) }
            } catch {
                lastError = "本机已退出，服务端撤销待重试：\(error.localizedDescription)"
                return
            }
        }
    }

    private func authenticated<T: Decodable>(path: String, method: String, body: Any?, idempotencyKey: String? = nil) async throws -> T {
        let requestGeneration = generation
        guard var current = session else { throw RiverAccountAPIError(status: 401, code: "auth_required") }
        if current.accessExpiresAt < Date().addingTimeInterval(45) {
            try await refreshSession()
            guard generation == requestGeneration, let renewed = session else { throw CancellationError() }
            current = renewed
        }
        do {
            let result: T = try await send(path: path, method: method, body: body, idempotencyKey: idempotencyKey, accessToken: current.accessToken)
            guard generation == requestGeneration, session != nil else { throw CancellationError() }
            return result
        } catch let error as RiverAccountAPIError where error.status == 401 {
            guard generation == requestGeneration, let active = session else { throw CancellationError() }
            if active.accessToken == current.accessToken { try await refreshSession() }
            guard generation == requestGeneration, let renewed = session else { throw CancellationError() }
            let result: T = try await send(path: path, method: method, body: body, idempotencyKey: idempotencyKey, accessToken: renewed.accessToken)
            guard generation == requestGeneration, session != nil else { throw CancellationError() }
            return result
        }
    }

    private func refreshSession() async throws {
        if let pending = refreshTask { return try await pending.task.value }
        guard let previous = session else { throw RiverAccountAPIError(status: 401, code: "auth_required") }
        let requestGeneration = generation
        let requestID = previous.pendingRefreshRequestID ?? UUID().uuidString
        if previous.pendingRefreshRequestID == nil {
            let marked = RiverAccountSession(email: previous.email, userID: previous.userID, accessToken: previous.accessToken,
                refreshToken: previous.refreshToken, revokeToken: previous.revokeToken,
                accessExpiresAt: previous.accessExpiresAt, pendingRefreshRequestID: requestID)
            try vault.write(try JSONEncoder().encode(marked), key: sessionStoreKey)
            session = marked
        }
        let taskID = UUID()
        let task = Task { @MainActor [self] in
            let body: [String: Any] = ["refresh_token": previous.refreshToken, "revoke_token": previous.revokeToken, "client_instance_id": clientInstanceID]
            do {
                let response: TokenResponse = try await send(path: "/auth/refresh", method: "POST", body: body, idempotencyKey: requestID, accessToken: nil)
                guard generation == requestGeneration, session?.refreshToken == previous.refreshToken else {
                    await revokeUnstored(response)
                    throw CancellationError()
                }
                guard response.user.id == previous.userID else {
                    await revokeUnstored(response)
                    throw RiverAccountAPIError(status: 403, code: "local_profile_account_mismatch")
                }
                try save(response, email: previous.email)
            } catch let error as RiverAccountAPIError where error.status == 401 {
                // A failed request from an older context must not sign out a newer login.
                if generation == requestGeneration {
                    _ = beginAuthentication()
                    session = nil
                    entitlements = []
                    try? vault.remove(sessionStoreKey)
                }
                throw error
            }
        }
        refreshTask = (taskID, task)
        defer { if refreshTask?.id == taskID { refreshTask = nil } }
        try await task.value
    }

    private func restoreProfileBinding(_ previous: Data?) {
        if let previous {
            try? vault.write(previous, key: profileBindingStoreKey)
        } else {
            try? vault.remove(profileBindingStoreKey)
        }
    }

    private func save(_ response: TokenResponse, email: String) throws {
        let value = RiverAccountSession(email: email, userID: response.user.id, accessToken: response.access_token,
            refreshToken: response.refresh_token, revokeToken: response.revoke_token,
            accessExpiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in)), pendingRefreshRequestID: nil)
        let data = try JSONEncoder().encode(value)
        try vault.write(data, key: sessionStoreKey)
        session = value
    }

    private func revokeUnstored(_ response: TokenResponse) async {
        do {
            try enqueueRevocation(response.revoke_token)
            await retryPendingSignOuts()
        } catch { lastError = "未接纳的会话撤销保存失败：\(error.localizedDescription)" }
    }

    private func send<T: Decodable>(path: String, method: String, body: Any?, idempotencyKey: String?, accessToken: String?) async throws -> T {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        return try await sendRaw(path: path, method: method, data: data, idempotencyKey: idempotencyKey, accessToken: accessToken, allowEmptyResponse: false)
    }

    private func sendRaw<T: Decodable>(path: String, method: String, data: Data?, idempotencyKey: String?, accessToken: String?, allowEmptyResponse: Bool) async throws -> T {
        var request = URLRequest(url: Self.apiBaseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let data {
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "无法连接 River Diary 账号服务，请检查网络后重试。"])
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))
            throw RiverAccountAPIError(status: http.statusCode, code: envelope?.error ?? "request_failed")
        }
        if allowEmptyResponse, data.isEmpty, let empty = EmptyResponse() as? T { return empty }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct TokenResponse: Decodable {
        struct User: Decodable { let id: String }
        let access_token: String
        let refresh_token: String
        let revoke_token: String
        let expires_in: Int
        let user: User
    }
    private struct ErrorEnvelope: Decodable { let error: String? }
    private struct EmptyResponse: Decodable {}
}

protocol RiverAccountVaultStorage {
    func read(_ key: String) -> Data?
    func write(_ data: Data, key: String) throws
    func remove(_ key: String) throws
}

private final class RiverAccountVault: RiverAccountVaultStorage {
    private let service = RiverSecureStore.keychainServiceName("RiverDiary.account")

    func read(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func write(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw SecureStoreError.keychainStatus(update) }
        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw SecureStoreError.keychainStatus(status) }
        if status == errSecDuplicateItem {
            let retry = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retry == errSecSuccess else { throw SecureStoreError.keychainStatus(retry) }
        }
    }

    func remove(_ key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError.keychainStatus(status) }
    }
}
