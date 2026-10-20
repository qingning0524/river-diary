import Foundation
import CryptoKit
import RiverDiaryCore
import XCTest
@testable import RiverDiary

final class RiverDayAnalysisTests: XCTestCase {
    private func event(_ offset: Double) -> RiverEvent {
        RiverEvent(id: UUID(), originDeviceID: RiverDeviceID(rawValue: "qa-test"), originSequence: UInt64(offset),
                   observedAt: Date(timeIntervalSince1970: offset), source: "manual", kind: "manual.note", payload: Data())
    }
    func testRejectsUnknownAndDuplicateEvidenceAndUsesLocalTimes() throws {
        let first = event(100), last = event(200)
        let raw = """
        {"overview":"A recorded day","moments":[
          {"title":"Valid activity","summary":"Supported by records","event_ids":["\(first.id.uuidString)","\(last.id.uuidString)"]},
          {"title":"Duplicate activity","summary":"Must not count twice","event_ids":["\(first.id.uuidString)"]},
          {"title":"Unknown activity","summary":"No evidence","event_ids":["\(UUID().uuidString)"]}
        ]}
        """
        let result = try XCTUnwrap(RiverDayAnalysisResponse.decode(raw)).digest(dayKey: "2026-10-03", events: [first, last])
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments[0].start, first.observedAt)
        XCTAssertEqual(result.segments[0].end, last.observedAt)
        XCTAssertEqual(result.segments[0].evidenceRefs.count, 2)
    }
    func testRawRecordsDoNotBecomeAIResultsAndHandlesCodeFence() throws {
        XCTAssertNil(RiverDayAnalysisResponse.decode("A raw manual note"))
        let result = try XCTUnwrap(RiverDayAnalysisResponse.decode("```json\n{\"overview\":\"Only a journal\",\"moments\":[]}\n```"))
        XCTAssertTrue(result.digest(dayKey: "2026-10-03", events: []).segments.isEmpty)
        XCTAssertEqual(result.readableReview, "Only a journal")
    }
    @MainActor func testNewestSameDayAnalysisWinsAndDifferentDaysStaySeparate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try RiverLocalDatabase(databaseURL: folder.appendingPathComponent("test.sqlite"), testDeviceID: RiverDeviceID(rawValue: "iphone-day-analysis-test"))
        let day = Calendar.current.startOfDay(for: .now), key = RiverIOSProjection.dayKey(day)
        let evidence = try db.append(source: "manual", kind: "manual.note", payload: RiverEventPayload(text: "A recorded note"), observedAt: day.addingTimeInterval(100))
        for (logical, title) in [("a-old|d-" + key, "Old interpretation"), ("z-new|d-" + key, "Newest interpretation")] {
            let digest = RiverDayAnalysisDigest(dayKey: key, segments: [.init(candidateIDs: ["source"], title: title, summary: "Supported by the saved note", evidenceRefs: ["event:\(evidence.id.uuidString)"], start: evidence.observedAt, end: evidence.observedAt)])
            let content = try JSONEncoder().encode(digest), stamp = try db.nextManifestStamp()
            try db.insertArtifactRevision(.init(id: UUID().uuidString, logicalKey: logical, kind: .semanticTimeline, revisionNumber: 1,
                originDeviceID: db.deviceID, clock: stamp.clock, inputFrontier: try db.currentInputFrontier(), inputSnapshotHash: "test",
                pipelineVersion: "test", promptVersion: "3", modelProvider: "test", modelIdentifier: "test",
                content: content, contentHash: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()))
        }
        db.refreshTimeline(for: day)
        let snapshot = RiverDayAnalysisSnapshot.load(database: db, date: day)
        XCTAssertEqual(snapshot.moments.first?.title, "Newest interpretation")
        XCTAssertEqual(snapshot.overview, "Newest interpretation")
        XCTAssertNotNil(snapshot.fullReview)
        let previous = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: day))
        XCTAssertTrue(RiverDayAnalysisSnapshot.load(database: db, date: previous).moments.isEmpty)
    }

}

private final class DayAnalysisMockProtocol: URLProtocol {
    static var response = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension RiverDayAnalysisTests {
    @MainActor func testProviderResponsePersistsReviewAndEvidenceBasedMomentsForSelectedDay() async throws {
        let keys = ["endpoint", "model", "includeManualText", "includePlaces", "includeHealth", "photoConsent", "networkConsent"]
            .map { "river.ai." + $0 }
        let old = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = old[key] ?? nil { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let db = try RiverLocalDatabase(databaseURL: folder.appendingPathComponent("test.sqlite"), testDeviceID: .init(rawValue: "iphone-model-pipeline-test"))
        let day = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: .now)))
        let evidence = try db.append(source: "manual", kind: "manual.note", payload: RiverEventPayload(text: "I wrote a note"), observedAt: day.addingTimeInterval(3600))
        let modelText = """
        {"overview":"A day with recorded writing.","moments":[{"title":"Writing a note","summary":"The saved manual note is the evidence.","event_ids":["\(evidence.id.uuidString)"]}]}
        """
        DayAnalysisMockProtocol.response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": modelText]]]])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DayAnalysisMockProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let ai = IPhoneAIStore(database: db, session: session)
        ai.allowsNetworkAnalysis = false; ai.allowsPhotoAI = false
        ai.endpoint = "http://127.0.0.1:9999/v1"; ai.model = "isolated-test-model"; ai.includeManualText = true
        await ai.analyzeToday(analysisDate: day)
        XCTAssertNil(ai.errorMessage)
        db.refreshTimeline(for: day)
        let snapshot = RiverDayAnalysisSnapshot.load(database: db, date: day)
        XCTAssertEqual(snapshot.overview, "A day with recorded writing.")
        XCTAssertEqual(snapshot.moments.first?.title, "Writing a note")
        XCTAssertEqual(snapshot.moments.first?.eventIDs, [evidence.id])
        XCTAssertFalse(snapshot.fullReview?.hasPrefix("{") ?? true, "Cross-device daily-review content remains readable plain text")
    }
}
