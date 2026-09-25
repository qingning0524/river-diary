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
}
