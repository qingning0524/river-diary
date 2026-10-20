import XCTest
@testable import RiverDiaryMac

/// T04：退出登录后，AI 循环不得再发起新的外发请求。
@MainActor
final class AIGateTests: XCTestCase {
    func testSignedOutStoreSendsNoRequest() async {
        CountingURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let suite = "river-ai-gate-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AIAssistantStore(userDefaults: defaults, urlSession: session)
        store.endpoint = "https://example.invalid/v1/models"
        store.setAccountActive(false)

        await store.fetchAvailableModels()

        XCTAssertEqual(CountingURLProtocol.requestCount, 0, "signed-out AI store must not reach the network")
        XCTAssertEqual(store.modelMessage, "账号已退出，已停止后续分析请求。")
    }
}

final class CountingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
