import Combine
import Foundation

struct JournalEditingBuffer: Equatable {
    var text: String
    var mood: Int?
    var isDirty = false
}

@MainActor
final class JournalEditorStore: ObservableObject {
    @Published private(set) var buffers: [String: JournalEditingBuffer] = [:]

    func buffer(for entry: DiaryEntry) -> JournalEditingBuffer {
        buffers[entry.date] ?? JournalEditingBuffer(text: entry.displayOverview)
    }
    func edit(_ entry: DiaryEntry, text: String? = nil, mood: Int? = nil) {
        var buffer = buffer(for: entry)
        if let text { buffer.text = text }
        if let mood { buffer.mood = mood }
        buffer.isDirty = true
        buffers[entry.date] = buffer
    }
    func saved(_ date: String) { buffers[date] = nil }
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
