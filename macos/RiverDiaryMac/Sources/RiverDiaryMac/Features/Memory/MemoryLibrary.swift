import Combine
import Foundation

/// Shared read model for everything that can be revisited:
/// durable V2 memories, encrypted user reflections, and the day archive.
/// It intentionally does not create a second persistence layer.
@MainActor
final class MemoryLibraryStore: ObservableObject {
    @Published private(set) var durableMemories: [Memory] = []
    @Published private(set) var savedReflections: [MonthlyLetter] = []
    @Published private(set) var archiveDays: [MemoryArchiveDay] = []
    @Published private(set) var sourceEpisodes: [String: [Episode]] = [:]
    @Published private(set) var confirmations: [String: (confirmed: Bool, note: String)] = [:]
    @Published private(set) var analysisRuns: [AnalysisRun] = []

    private let v2: V2Store
    private var syncChangeObserver: NSObjectProtocol?
    private var lastRefreshEntries: [DiaryEntry] = []
    private var lastRefreshCaptures: [String: [QuickCapture]] = [:]
    private var lastRefreshLetters: [String: MonthlyLetter] = [:]

    init(v2Store: V2Store? = nil) {
        v2 = v2Store ?? V2Store()
        syncChangeObserver = NotificationCenter.default.addObserver(
            forName: .riverCanonicalSyncDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh(entries: self.lastRefreshEntries, captures: self.lastRefreshCaptures, letters: self.lastRefreshLetters)
            }
        }
    }

    deinit {
        if let syncChangeObserver { NotificationCenter.default.removeObserver(syncChangeObserver) }
    }

    func refresh(entries: [DiaryEntry], captures: [String: [QuickCapture]], letters: [String: MonthlyLetter]) {
        lastRefreshEntries = entries
        lastRefreshCaptures = captures
        lastRefreshLetters = letters
        durableMemories = v2.memories().sorted { $0.createdAt > $1.createdAt }
        analysisRuns = v2.analysisRuns().sorted { $0.createdAt > $1.createdAt }
        savedReflections = letters.values.sorted { $0.updatedAt > $1.updatedAt }
        archiveDays = MemoryArchive.days(entries: entries, captures: captures)

        // 一次性取回全部关联时间段与确认状态；此前对每条记忆各发一次
        // 查询（N+1），且整段刷新同步跑在主线程上。
        let allEpisodes = v2.episodes(ids: durableMemories.flatMap(\.sourceEpisodeIDs))
        // Index once, then resolve only each memory's own references.
        let episodesByID = Dictionary(uniqueKeysWithValues: allEpisodes.map { ($0.id, $0) })
        sourceEpisodes = durableMemories.reduce(into: [:]) { result, memory in
            result[memory.id.uuidString] = Set(memory.sourceEpisodeIDs)
                .compactMap { episodesByID[$0] }
                .sorted { lhs, rhs in
                    lhs.startTime == rhs.startTime ? lhs.id.uuidString < rhs.id.uuidString : lhs.startTime < rhs.startTime
                }
        }
        confirmations = [:]
        for (id, value) in v2.memoryConfirmations(ids: durableMemories.map(\.id)) {
            confirmations[id.uuidString] = value
        }
    }

    @discardableResult
    func setConfirmation(for memory: Memory, confirmed: Bool, note: String = "") -> Bool {
        guard v2.setMemoryConfirmation(memory.id, confirmed: confirmed, note: note) else { return false }
        confirmations[memory.id.uuidString] = (confirmed, note)
        if let index = durableMemories.firstIndex(where: { $0.id == memory.id }) {
            durableMemories[index].isUserConfirmed = confirmed
            durableMemories[index].lastConfirmedAt = Date()
        }
        return true
    }
}
