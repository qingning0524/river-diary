import Combine
import Foundation

struct JournalEditingBuffer: Equatable {
    var text: String
    var mood: Int?
    var isDirty = false
}

struct JournalDraftRecord: Codable, Equatable {
    let text: String
    let mood: Int?
    let updatedAt: Date
}

@MainActor
final class JournalEditorStore: ObservableObject {
    @Published private(set) var buffers: [String: JournalEditingBuffer] = [:]
    @Published private(set) var persistenceStatus: [String: String] = [:]
    var hasUnsavedChanges: Bool { buffers.values.contains(where: \.isDirty) }

    private weak var diaryStore: DiaryStore?
    private var persistenceTasks: [String: Task<Void, Never>] = [:]
    private var draftObserver: AnyCancellable?

    func attach(to store: DiaryStore) {
        guard diaryStore !== store else { return }
        diaryStore = store
        draftObserver = store.$journalDrafts.sink { [weak self] drafts in
            self?.synchronizeDurableDrafts(drafts)
        }
    }

    private func synchronizeDurableDrafts(_ drafts: [String: JournalDraftRecord]) {
        for (date, draft) in drafts {
            // Never replace newer text that is currently waiting for its debounce save.
            guard persistenceTasks[date] == nil else { continue }
            let restored = JournalEditingBuffer(text: draft.text, mood: draft.mood, isDirty: true)
            if buffers[date] != restored {
                buffers[date] = restored
            }
            persistenceStatus[date] = "草稿已加密保存在本机"
        }

        for date in Set(buffers.keys).subtracting(drafts.keys) where persistenceTasks[date] == nil {
            buffers[date] = nil
            persistenceStatus[date] = nil
        }
    }

    func buffer(for entry: DiaryEntry) -> JournalEditingBuffer {
        buffers[entry.date] ?? JournalEditingBuffer(text: entry.displayOverview)
    }
    func edit(_ entry: DiaryEntry, text: String? = nil, mood: Int? = nil) {
        var buffer = buffer(for: entry)
        if let text { buffer.text = text }
        if let mood { buffer.mood = mood }
        buffer.isDirty = true
        buffers[entry.date] = buffer
        schedulePersistence(buffer, for: entry.date)
    }

    func saved(_ date: String) {
        persistenceTasks[date]?.cancel()
        persistenceTasks[date] = nil
        buffers[date] = nil
        persistenceStatus[date] = nil
    }

    func discarded(_ date: String) {
        persistenceTasks[date]?.cancel()
        persistenceTasks[date] = nil
        do {
            try diaryStore?.removeJournalDraft(for: date)
            buffers[date] = nil
            persistenceStatus[date] = nil
        } catch {
            persistenceStatus[date] = "丢弃失败：\(UserFacingError.message(for: error))"
        }
    }

    private func schedulePersistence(_ buffer: JournalEditingBuffer, for date: String) {
        persistenceTasks[date]?.cancel()
        persistenceStatus[date] = "正在加密保存草稿…"
        persistenceTasks[date] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let diaryStore = self.diaryStore else { return }
            do {
                try diaryStore.saveJournalDraft(
                    JournalDraftRecord(text: buffer.text, mood: buffer.mood, updatedAt: Date()),
                    for: date
                )
                self.persistenceStatus[date] = "草稿已加密保存在本机"
            } catch {
                self.persistenceStatus[date] = "草稿保存失败：\(UserFacingError.message(for: error))"
            }
            self.persistenceTasks[date] = nil
        }
    }
}

enum JournalWriting {
    static func applying(_ override: EntryOverride, to entry: DiaryEntry) -> DiaryEntry {
        var result = entry
        result.overview = override.overview
        if override.overview.isEmpty { result.daily = nil }
        if override.preservesMetrics != true {
            let score = Int(Double(override.mood) * 0.4 + Double(override.output) * 0.25 + Double(override.focus) * 0.2 + Double(override.energy) * 0.15)
            result.score = Double(score)
            result.tags = override.tags
            result.category = override.category
            result.metrics = DayMetrics(mood: Double(override.mood), energy: Double(override.energy), focus: Double(override.focus), output: Double(override.output), overall: Double(score))
            result.stage = Stage(label: score >= 70 ? "积极" : score >= 40 ? "平稳" : "低落", color: score >= 70 ? "#7CB342" : score >= 40 ? "#D4A017" : "#E57373")
            return result
        }
        if let mood = override.writtenMood {
            let value = Double(min(100, max(0, mood)))
            var metrics = entry.metrics ?? DayMetrics()
            metrics.mood = value
            // A text-only save preserves every original metric. An explicit mood
            // affects the mood only; an existing composite score remains intact.
            if entry.metrics?.overall == nil { result.score = value }
            result.metrics = metrics
        }
        return result
    }

    static func merging(entries: [DiaryEntry], overrides: [String: EntryOverride]) -> [DiaryEntry] {
        var dates = Set<String>()
        var result = entries.map { entry in
            dates.insert(entry.date)
            guard let value = overrides[entry.id] ?? overrides["local-\(entry.date)"] ?? overrides["ingested-\(entry.date)"] else { return entry }
            return applying(value, to: entry)
        }
        for (id, value) in overrides.sorted(by: { $0.key < $1.key }) {
            let prefix = id.hasPrefix("local-") ? "local-" : id.hasPrefix("ingested-") ? "ingested-" : ""
            guard !prefix.isEmpty else { continue }
            let date = String(id.dropFirst(prefix.count))
            guard !dates.contains(date), DiaryEntry.dateFormatter.date(from: date) != nil else { continue }
            result.append(applying(value, to: DiaryEntry(pageID: id, date: date)))
            dates.insert(date)
        }
        return result.sorted { $0.date < $1.date }
    }
}
