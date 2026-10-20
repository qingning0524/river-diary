import XCTest
@testable import RiverDiaryMac

@MainActor
final class MemoryLibraryTests: XCTestCase {
    private func makeStore() throws -> V2Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return V2Store(databaseURL: directory.appendingPathComponent("library.db"))
    }

    func testRefreshBuildsOneRevisitableLibrary() throws {
        let v2 = try makeStore()
        let episode = Episode(startTime: Date(timeIntervalSince1970: 10), endTime: Date(timeIntervalSince1970: 70), title: "设计河流", summary: "整理时间线", category: .work)
        let memory = Memory(title: "持续设计", body: "河流时间线是长期项目", kind: .projectTrajectory, sourceEpisodeIDs: [episode.id])
        XCTAssertTrue(v2.insertEpisode(episode))
        XCTAssertTrue(v2.insertMemory(memory))

        let entry = DiaryEntry(
            pageID: "2026-09-20", date: "2026-09-20", score: 80, daily: nil,
            overview: "今天继续设计河流。", thoughts: [], memos: [], tags: [], category: "工作",
            metrics: nil, stage: nil, screenHours: nil, views: nil, screenApps: [], browseSites: [],
            screenNote: nil, browseNote: nil, didItems: [], health: nil
        )
        let letter = MonthlyLetter(month: "2026-09", title: "九月河流信", body: "继续设计。", evidence: "1 天日记", createdAt: Date(), updatedAt: Date())
        let library = MemoryLibraryStore(v2Store: v2)
        library.refresh(entries: [entry], captures: [:], letters: [letter.month: letter])

        XCTAssertEqual(library.durableMemories.map(\.id), [memory.id])
        XCTAssertEqual(library.sourceEpisodes[memory.id.uuidString]?.map(\.id), [episode.id])
        XCTAssertEqual(library.archiveDays.map(\.id), [entry.date])
        XCTAssertEqual(library.savedReflections.map(\.id), [letter.id])

        XCTAssertTrue(library.setConfirmation(for: memory, confirmed: true))
        XCTAssertEqual(library.confirmations[memory.id.uuidString]?.confirmed, true)
        XCTAssertEqual(v2.memoryConfirmation(for: memory.id)?.confirmed, true)
    }

    func testRefreshDeduplicatesSharedSourcesAndOmitsMissingEpisodes() throws {
        let v2 = try makeStore()
        let early = Episode(startTime: Date(timeIntervalSince1970: 10), endTime: Date(timeIntervalSince1970: 20), title: "early")
        let late = Episode(startTime: Date(timeIntervalSince1970: 30), endTime: Date(timeIntervalSince1970: 40), title: "late")
        let unrelated = Episode(startTime: Date(timeIntervalSince1970: 50), endTime: Date(timeIntervalSince1970: 60), title: "unrelated")
        for episode in [late, unrelated, early] { XCTAssertTrue(v2.insertEpisode(episode)) }
        let first = Memory(title: "first", sourceEpisodeIDs: [late.id, early.id, late.id, UUID()])
        let second = Memory(title: "second", sourceEpisodeIDs: [late.id])
        let missing = Memory(title: "missing", sourceEpisodeIDs: [UUID()])
        for memory in [first, second, missing] { XCTAssertTrue(v2.insertMemory(memory)) }
        let library = MemoryLibraryStore(v2Store: v2)

        library.refresh(entries: [], captures: [:], letters: [:])

        XCTAssertEqual(library.sourceEpisodes[first.id.uuidString]?.map(\.id), [early.id, late.id])
        XCTAssertEqual(library.sourceEpisodes[second.id.uuidString]?.map(\.id), [late.id])
        XCTAssertEqual(library.sourceEpisodes[missing.id.uuidString], [])
    }

    func testRefreshReplacesEpisodeLinksAfterMemoryUpdate() throws {
        let v2 = try makeStore()
        let first = Episode(startTime: Date(timeIntervalSince1970: 10), endTime: Date(timeIntervalSince1970: 20), title: "first")
        let second = Episode(startTime: Date(timeIntervalSince1970: 30), endTime: Date(timeIntervalSince1970: 40), title: "second")
        for episode in [first, second] { XCTAssertTrue(v2.insertEpisode(episode)) }
        var memory = Memory(title: "memory", sourceEpisodeIDs: [first.id])
        XCTAssertTrue(v2.insertMemory(memory))
        let library = MemoryLibraryStore(v2Store: v2)
        library.refresh(entries: [], captures: [:], letters: [:])
        XCTAssertEqual(library.sourceEpisodes[memory.id.uuidString]?.map(\.id), [first.id])

        memory.sourceEpisodeIDs = [second.id]
        XCTAssertTrue(v2.insertMemory(memory))
        library.refresh(entries: [], captures: [:], letters: [:])

        XCTAssertEqual(library.sourceEpisodes[memory.id.uuidString]?.map(\.id), [second.id])
    }
}
