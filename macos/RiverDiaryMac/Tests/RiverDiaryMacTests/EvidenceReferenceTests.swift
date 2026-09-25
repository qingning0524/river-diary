import XCTest

@testable import RiverDiaryMac

/// 证据引用的白名单/解析回归。
///
/// 这一层的意义是：AI 写下的"依据"只有在能被本机记录核对时才算依据。
/// 测试锁住的正是"模型编造的引用必须被丢弃"这条红线。
final class EvidenceReferenceTests: XCTestCase {

    private let sessionID = UUID()
    private let captureID = UUID()

    private var allowed: Set<String> {
        EvidenceReference.allowedSet(
            sessionIDs: [sessionID],
            diaryDays: ["2026-09-23"],
            captureIDs: [captureID],
            healthDays: ["2026-09-24"]
        )
    }

    func testParsesEverySupportedKind() {
        XCTAssertEqual(EvidenceReference.parse("raw:\(sessionID.uuidString)")?.kind, .raw)
        XCTAssertEqual(EvidenceReference.parse("diary:2026-09-23")?.value, "2026-09-23")
        XCTAssertEqual(EvidenceReference.parse("capture:\(captureID.uuidString)")?.kind, .capture)
        XCTAssertEqual(EvidenceReference.parse("health:2026-09-24")?.kind, .health)
        XCTAssertEqual(EvidenceReference.parse("episode:\(UUID().uuidString)")?.kind, .episode)
    }

    func testRejectsMalformedAndUnknownForms() {
        // 未知前缀、非 UUID、非日期键、空值都不允许成为证据。
        XCTAssertNil(EvidenceReference.parse("memory:\(UUID().uuidString)"))
        XCTAssertNil(EvidenceReference.parse("raw:not-a-uuid"))
        XCTAssertNil(EvidenceReference.parse("diary:2026-9-3"))
        XCTAssertNil(EvidenceReference.parse("diary:2026-13-01"))
        XCTAssertNil(EvidenceReference.parse("raw:"))
        XCTAssertNil(EvidenceReference.parse("2026-09-23"))
    }

    func testSanitizeDropsReferencesThatDoNotExistLocally() {
        let fabricated = "raw:\(UUID().uuidString)"
        let result = EvidenceReference.sanitize(
            ["diary:2026-09-23", fabricated, "diary:2026-01-01", "bogus"],
            allowed: allowed
        )
        // 只有真实存在、格式合法的那一条留下；编造与格式错误各计一次丢弃。
        XCTAssertEqual(result.kept, ["diary:2026-09-23"])
        XCTAssertEqual(result.dropped, 3)
    }

    func testSanitizeDeduplicatesWhileKeepingOrder() {
        let result = EvidenceReference.sanitize(
            ["diary:2026-09-23", "raw:\(sessionID.uuidString)", "diary:2026-09-23"],
            allowed: allowed
        )
        XCTAssertEqual(result.kept, ["diary:2026-09-23", "raw:\(sessionID.uuidString)"])
        XCTAssertEqual(result.dropped, 0)
    }

    func testExtractPullsReferencesOutOfModelProse() {
        let text = """
        **关键依据**
        - 2026-09-23 专注度下降（diary:2026-09-23）
        - 上午单段 85 分钟（raw:\(sessionID.uuidString)）
        - 无关的编号 123e4567
        """
        XCTAssertEqual(
            EvidenceReference.extract(from: text),
            ["diary:2026-09-23", "raw:\(sessionID.uuidString)"]
        )
    }

    func testStableDigestIsProcessStable() {
        // String.hashValue 每进程随机；缓存键必须用稳定摘要。
        XCTAssertEqual(
            AIAssistantStore.stableDigest("删聊天记录的挣扎"),
            AIAssistantStore.stableDigest("删聊天记录的挣扎")
        )
        XCTAssertNotEqual(
            AIAssistantStore.stableDigest("a"),
            AIAssistantStore.stableDigest("b")
        )
    }
}
