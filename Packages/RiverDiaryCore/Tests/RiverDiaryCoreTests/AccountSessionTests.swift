import Foundation
import XCTest
@testable import RiverDiaryCore

@MainActor
final class AccountSessionTests: XCTestCase {
    private func makeStore(vault: AccountTestVault = AccountTestVault(), server: AccountTestServer) throws -> RiverAccountSessionStore {
        if vault.values["account-session-v1"] == nil {
            vault.values["account-session-v1"] = try JSONEncoder().encode(RiverAccountSession(
                email: "test@example.invalid", userID: "user-a", accessToken: "old-access", refreshToken: "old-refresh",
                revokeToken: "revoke-a", accessExpiresAt: .distantPast))
        }
        vault.values["account-client-instance-v1"] = Data(UUID().uuidString.utf8)
        vault.values["account-profile-binding-v1"] = Data("user-a".utf8)
        return RiverAccountSessionStore(platform: .macos, deviceName: "Isolated test", vault: vault,
                                        transport: { try await server.send($0) })
    }

    func testConcurrentExpiredRequestsRefreshOnlyOnce() async throws {
        let server = AccountTestServer()
        let store = try makeStore(server: server)
        let first = Task { try await store.refreshEntitlements() }
        await server.waitForRequests(1)
        var secondStarted = false
        let second = Task { secondStarted = true; return try await store.passwordEnabled() }
        while !secondStarted { await Task.yield() }
        let refreshCount = await server.refreshCount
        await server.finishRefreshes()
        try await first.value
        _ = try await second.value
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(store.session?.accessToken, "new-access")
    }

    func testLateRefreshCannotRestoreSignedOutSession() async throws {
        let server = AccountTestServer()
        let vault = AccountTestVault()
        let store = try makeStore(vault: vault, server: server)
        let request = Task { try? await store.refreshEntitlements() }
        await server.waitForRequests(1)
        await store.signOut()
        await server.finishRefreshes()
        await request.value
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(vault.values["account-session-v1"])
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testLateEntitlementsCannotRepopulateSignedOutState() async throws {
        let server = AccountTestServer()
        await server.setDelayEntitlements()
        let vault = AccountTestVault()
        vault.values["account-session-v1"] = try JSONEncoder().encode(RiverAccountSession(
            email: "test@example.invalid", userID: "user-a", accessToken: "valid-access", refreshToken: "refresh-a",
            revokeToken: "revoke-a", accessExpiresAt: Date().addingTimeInterval(3600)))
        let store = try makeStore(vault: vault, server: server)
        let request = Task { try? await store.refreshEntitlements() }
        await server.waitForEntitlementRequest()
        await store.signOut()
        await server.finishEntitlements()
        await request.value
        XCTAssertFalse(store.isSignedIn)
        XCTAssertTrue(store.entitlements.isEmpty)
    }

    func testOfflineSignOutPersistsOnlyRevocationAndRetriesAfterRestart() async throws {
        let server = AccountTestServer()
        await server.setLogoutUnavailable(true)
        let vault = AccountTestVault()
        let store = try makeStore(vault: vault, server: server)
        await store.signOut()
        XCTAssertFalse(store.isSignedIn)
        XCTAssertNil(vault.values["account-session-v1"])
        let pending = try XCTUnwrap(vault.values["account-pending-revocations-v1"])
        XCTAssertTrue(String(decoding: pending, as: UTF8.self).contains("revoke-a"))
        XCTAssertFalse(String(decoding: pending, as: UTF8.self).contains("old-refresh"))

        await server.setLogoutUnavailable(false)
        let restarted = RiverAccountSessionStore(platform: .macos, deviceName: "Isolated restart", vault: vault,
                                                 transport: { try await server.send($0) })
        await restarted.retryPendingSignOuts()
        XCTAssertFalse(restarted.isSignedIn)
        XCTAssertNil(vault.values["account-pending-revocations-v1"])
        let authenticatedLogouts = await server.authenticatedLogouts
        XCTAssertEqual(authenticatedLogouts, 0)
    }

    func testFailedCredentialDeletionCannotRestoreSignedOutSessionOnRestart() async throws {
        let server = AccountTestServer()
        let vault = AccountTestVault()
        vault.failSessionRemoval = true
        let store = try makeStore(vault: vault, server: server)
        await store.signOut()
        let restarted = RiverAccountSessionStore(platform: .macos, deviceName: "Isolated restart", vault: vault,
                                                 transport: { try await server.send($0) })
        XCTAssertFalse(restarted.isSignedIn)
        XCTAssertNotNil(store.lastError)
    }

    func testRestartReusesThePersistedRefreshRequestID() async throws {
        let server = AccountTestServer()
        let vault = AccountTestVault()
        let store = try makeStore(vault: vault, server: server)
        let first = Task { try? await store.refreshEntitlements() }
        await server.waitForRequests(1)
        let firstID = await server.lastRefreshIdempotencyKey
        XCTAssertNotNil(firstID)

        // 刷新请求发出后立即持久化了请求 ID；重启后必须复用它，刷新才是幂等的。
        let persisted = try JSONDecoder().decode(
            RiverAccountSession.self,
            from: try XCTUnwrap(vault.values["account-session-v1"])
        )
        XCTAssertEqual(persisted.pendingRefreshRequestID, firstID)

        let restarted = RiverAccountSessionStore(
            platform: .macos, deviceName: "Isolated restart", vault: vault,
            transport: { try await server.send($0) }
        )
        let second = Task { try? await restarted.refreshEntitlements() }
        await server.waitForRequests(2)
        let secondID = await server.lastRefreshIdempotencyKey
        XCTAssertEqual(secondID, firstID)

        await server.finishRefreshes()
        await first.value
        await second.value
        XCTAssertEqual(restarted.session?.accessToken, "new-access")
        XCTAssertNil(restarted.session?.pendingRefreshRequestID)
    }

    func testLateSuccessfulRefreshCannotOverwriteANewerLogin() async throws {
        let server = AccountTestServer()
        let store = try makeStore(server: server)
        let oldRequest = Task { try? await store.refreshEntitlements() }
        await server.waitForRequests(1)
        await store.signOut()
        try await store.loginWithPassword(
            email: "test@example.invalid",
            password: "test-only-password",
            idempotencyKey: UUID().uuidString
        )

        // 旧上下文的 200 响应必须被丢弃（并撤销其未采用的令牌），不能覆盖新登录。
        await server.finishRefreshes(status: 200)
        await oldRequest.value
        XCTAssertEqual(store.session?.accessToken, "login-access")
        XCTAssertEqual(store.session?.refreshToken, "login-refresh")
        let logouts = await server.logoutCount
        XCTAssertGreaterThanOrEqual(logouts, 1)
    }

    func testOldUnauthorizedRefreshCannotClearANewerLogin() async throws {
        let server = AccountTestServer()
        let store = try makeStore(server: server)
        let oldRequest = Task { try? await store.refreshEntitlements() }
        await server.waitForRequests(1)
        await store.signOut()
        try await store.loginWithPassword(email: "test@example.invalid", password: "test-only-password", idempotencyKey: UUID().uuidString)
        await server.finishRefreshes(status: 401)
        await oldRequest.value
        XCTAssertTrue(store.isSignedIn)
        XCTAssertEqual(store.session?.accessToken, "login-access")
    }
}

private final class AccountTestVault: RiverAccountVaultStorage {
    var values: [String: Data] = [:]
    var failSessionRemoval = false
    func read(_ key: String) -> Data? { values[key] }
    func write(_ data: Data, key: String) throws { values[key] = data }
    func remove(_ key: String) throws {
        if failSessionRemoval && key == "account-session-v1" { throw URLError(.cannotWriteToFile) }
        values.removeValue(forKey: key)
    }
}

private actor AccountTestServer {
    private(set) var refreshCount = 0
    private var refreshes: [CheckedContinuation<(Data, URLResponse), Error>] = []
    private var refreshWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var delayEntitlements = false
    private var entitlement: CheckedContinuation<(Data, URLResponse), Error>?
    private var entitlementWaiter: CheckedContinuation<Void, Never>?
    private var logoutUnavailable = false
    private(set) var authenticatedLogouts = 0
    private(set) var logoutCount = 0
    private(set) var refreshIdempotencyKeys: [String] = []
    var lastRefreshIdempotencyKey: String? { refreshIdempotencyKeys.last }

    func setDelayEntitlements() { delayEntitlements = true }
    func setLogoutUnavailable(_ value: Bool) { logoutUnavailable = value }
    func waitForRequests(_ count: Int) async {
        if refreshCount >= count { return }
        await withCheckedContinuation { refreshWaiters.append((count, $0)) }
    }
    func waitForEntitlementRequest() async {
        if entitlement != nil { return }
        await withCheckedContinuation { entitlementWaiter = $0 }
    }
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        switch request.url!.path {
        case "/v1/auth/refresh":
            refreshCount += 1
            refreshIdempotencyKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            return try await withCheckedThrowingContinuation { continuation in
                refreshes.append(continuation)
                let ready = refreshWaiters.filter { $0.0 <= refreshCount }
                refreshWaiters.removeAll { $0.0 <= refreshCount }
                ready.forEach { $0.1.resume() }
            }
        case "/v1/me/entitlements":
            if delayEntitlements {
                return try await withCheckedThrowingContinuation {
                    entitlement = $0
                    entitlementWaiter?.resume(); entitlementWaiter = nil
                }
            }
            return result("{\"entitlements\":[]}")
        case "/v1/me/password": return result("{\"password_enabled\":true}")
        case "/v1/auth/password/login":
            return result("{\"access_token\":\"login-access\",\"refresh_token\":\"login-refresh\",\"revoke_token\":\"login-revoke\",\"expires_in\":3600,\"user\":{\"id\":\"user-a\"}}")
        case "/v1/auth/logout":
            logoutCount += 1
            if request.value(forHTTPHeaderField: "Authorization") != nil { authenticatedLogouts += 1 }
            if logoutUnavailable { throw URLError(.notConnectedToInternet) }
            return result("")
        default: throw URLError(.unsupportedURL)
        }
    }
    func finishRefreshes(status: Int = 200) {
        let body = status == 200
            ? "{\"access_token\":\"new-access\",\"refresh_token\":\"new-refresh\",\"revoke_token\":\"revoke-a\",\"expires_in\":3600,\"user\":{\"id\":\"user-a\"}}"
            : "{\"error\":\"auth_required\"}"
        let result = result(body, status: status)
        let pending = refreshes; refreshes = []
        pending.forEach { $0.resume(returning: result) }
    }
    func finishEntitlements() {
        entitlement?.resume(returning: result("{\"entitlements\":[{\"product_code\":\"riverdiary_premium\",\"active\":true,\"starts_at\":\"2026-10-17\",\"permanent\":true}]}"))
        entitlement = nil
    }
    private func result(_ body: String, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: URL(string: "https://example.invalid/v1")!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
