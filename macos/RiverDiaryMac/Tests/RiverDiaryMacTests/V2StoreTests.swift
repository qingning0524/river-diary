import XCTest
@testable import RiverDiaryMac

@MainActor
final class V2StoreTests: XCTestCase {

    private let expectedTables = [
        "activities", "analysis_runs", "context_snapshots", "episode_annotations",
        "episodes", "memories", "memory_confirmations", "raw_events", "user_prefs",
    ]

    private func makeStore() throws -> (V2Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("river-v2.db")
        return (V2Store(databaseURL: url), url)
    }

    func testSchemaCreatesAllTables() throws {
        let (store, _) = try makeStore()
        let tables = store.tableNames()
        for table in expectedTables {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
        let indices = store.indexNames()
        XCTAssertTrue(indices.contains("idx_raw_events_ts"))
        XCTAssertTrue(indices.contains("idx_episodes_times"))
    }

    func testRawEventRoundTripAndEmptyState() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.countRows(in: "raw_events"), 0)

        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 5_000),
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(appName: "Xcode", windowTitle: "River.swift"),
            sourceHash: "hash-1"
        )
        XCTAssertTrue(store.insertRawEvent(event))

        let range = store.rawEvents(between: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(range.count, 1)
        XCTAssertEqual(range[0], event)
        XCTAssertEqual(range[0].payload.appName, "Xcode")

        let fetched = store.rawEvents(ids: [event.id])
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, event.id)
    }

    func testEpisodeRoundTripPreservesProvenance() throws {
        let (store, _) = try makeStore()
        let rawA = UUID()
        let rawB = UUID()
        let activity = Activity(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 300),
            groupKey: "xcode",
            primaryApp: "Xcode",
            category: .focused,
            evidenceIDs: [rawA]
        )
        XCTAssertTrue(store.insertActivity(activity))

        let episode = Episode(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 300),
            title: "Developing River",
            summary: "Reviewed architecture changes.",
            category: .work,
            confidence: 78,
            confidenceFactors: [ConfidenceFactor(name: "same-app", value: 0.9)],
            activityIDs: [activity.id],
            evidenceIDs: [rawB, rawA]
        )
        XCTAssertTrue(store.insertEpisode(episode))

        let loaded = store.episodes(between: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, episode.title)
        XCTAssertEqual(loaded[0].confidence, 78)
        XCTAssertEqual(loaded[0].confidenceFactors, episode.confidenceFactors)
        XCTAssertEqual(loaded[0].activityIDs, [activity.id])
        XCTAssertEqual(Set(loaded[0].evidenceIDs), Set([rawA, rawB]))
    }

    func testMemoryAndAnalysisRoundTrip() throws {
        let (store, _) = try makeStore()
        let episodeID = UUID()
        let memory = Memory(
            title: "常在深夜写代码",
            kind: .habit,
            confidence: 70,
            sourceEpisodeIDs: [episodeID]
        )
        XCTAssertTrue(store.insertMemory(memory))
        XCTAssertEqual(store.memories().count, 1)
        XCTAssertEqual(store.memories().first?.sourceEpisodeIDs, [episodeID])

        let evidence = UUID()
        let run = AnalysisRun(
            task: .weeklyReview,
            inputContextReference: UUID(),
            outputText: "本周主要在开发 River。",
            evidenceIDs: [evidence],
            model: "test-model"
        )
        XCTAssertTrue(store.insertAnalysisRun(run))
        let runs = store.analysisRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.evidenceIDs, [evidence])
        XCTAssertEqual(runs.first?.model, "test-model")
    }

    func testClearDerivedKeepsEvidence() throws {
        let (store, _) = try makeStore()
        let raw = RawEvent(source: .manual, kind: .quickCapture, payload: RawEventPayload(text: "留着"))
        let episode = Episode(startTime: Date(), endTime: Date(), title: "will be cleared")
        XCTAssertTrue(store.insertRawEvent(raw))
        XCTAssertTrue(store.insertEpisode(episode))
        XCTAssertTrue(store.insertMemory(Memory(title: "m")))

        store.clearDerivedData()

        XCTAssertEqual(store.countRows(in: "raw_events"), 1)
        XCTAssertEqual(store.countRows(in: "episodes"), 0)
        XCTAssertEqual(store.countRows(in: "memories"), 0)
        XCTAssertEqual(store.countRows(in: "analysis_runs"), 0)
    }

    func testUserPrefsPersist() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.setUserPref(key: "savedQuery.pinned", value: "本周工作"))
        XCTAssertEqual(store.userPref(key: "savedQuery.pinned"), "本周工作")
        XCTAssertNil(store.userPref(key: "missing"))
    }
}
