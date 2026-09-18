import XCTest
@testable import RiverDiaryMac

final class V2DomainTests: XCTestCase {

    func testRawEventCodableRoundTrip() throws {
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 10_000),
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: "River.swift"),
            sourceHash: "abc123"
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RawEvent.self, from: data)
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.payload.appName, "Xcode")
        XCTAssertEqual(decoded.sourceHash, "abc123")
    }

    func testRawEventDefaultsAreDeterministicEnoughForEvidence() {
        let a = RawEvent(source: .chrome, kind: .urlVisit)
        let b = RawEvent(source: .chrome, kind: .urlVisit)
        XCTAssertNotEqual(a.id, b.id) // each evidence is unique
        XCTAssertEqual(a.source, b.source)
    }

    func testActivityDurationAndCategory() {
        let activity = Activity(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 160),
            groupKey: "xcode",
            primaryApp: "Xcode",
            category: .focused,
            evidenceIDs: [UUID(), UUID()]
        )
        XCTAssertEqual(activity.duration, 60)
        XCTAssertEqual(activity.category, .focused)
        XCTAssertEqual(activity.evidenceIDs.count, 2)
    }

    func testEpisodeEvidenceUnionDeduplicatesProvenance() {
        let activity1 = Activity(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 60),
            groupKey: "a"
        )
        let activity2 = Activity(
            startTime: Date(timeIntervalSince1970: 60),
            endTime: Date(timeIntervalSince1970: 120),
            groupKey: "b"
        )
        let rawA = UUID()
        let rawB = UUID()
        let rawC = UUID()
        let bundle: [String: [UUID]] = [
            activity1.id.uuidString: [rawA, rawB],
            activity2.id.uuidString: [rawB, rawC],
        ]
        let episode = Episode(
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 120),
            title: "Focus block",
            activityIDs: [activity1.id, activity2.id],
            evidenceIDs: [rawA] // overlaps with activity evidence
        )
        let all = episode.allEvidenceIDs(bundle: bundle)
        XCTAssertEqual(Set(all), Set([rawA, rawB, rawC]))
        XCTAssertEqual(all.count, 3)
    }

    func testMemoryPreservesEpisodeProvenance() {
        let episodeID = UUID()
        let memory = Memory(
            title: "常常在夜里写代码",
            kind: .habit,
            confidence: 72,
            sourceEpisodeIDs: [episodeID]
        )
        XCTAssertEqual(memory.sourceEpisodeIDs, [episodeID])
        XCTAssertFalse(memory.isUserConfirmed)
        XCTAssertNil(memory.lastConfirmedAt)
    }

    func testAnalysisRunIsDetachedFromFactLayer() {
        let run = AnalysisRun(
            task: .query,
            inputContextReference: UUID(),
            outputText: "本周主要在开发 River。",
            evidenceIDs: [UUID(), UUID()],
            model: "test-model"
        )
        XCTAssertEqual(run.task, .query)
        XCTAssertEqual(run.evidenceIDs.count, 2)
        XCTAssertNotNil(run.inputContextReference)
    }

    func testEvidenceRefPointsToObject() {
        let objectID = UUID()
        let ref = EvidenceRef(kind: .episode, objectID: objectID, reason: "同一天连续出现")
        XCTAssertEqual(ref.kind, .episode)
        XCTAssertEqual(ref.objectID, objectID)
        XCTAssertFalse(ref.reason.isEmpty)
    }
}
