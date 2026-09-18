import Foundation

struct MemoryArchiveDay: Identifiable, Hashable {
    var id: String { entry.date }
    var entry: DiaryEntry
    var captures: [QuickCapture]
    var hasWriting: Bool { !entry.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var preview: String { hasWriting ? entry.displayOverview : captures.first?.text ?? "这一天，留下一些生活线索。" }
    var mood: Double? { entry.metrics?.mood ?? entry.score }
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let text = ([entry.date, entry.displayOverview, entry.category ?? ""] + (entry.tags ?? []) + (entry.thoughts ?? []) + (entry.memos ?? []) + captures.map(\.text)).joined(separator: " ")
        return text.localizedStandardContains(needle)
    }
}

enum MemoryArchive {
    static func days(entries: [DiaryEntry], captures: [String: [QuickCapture]]) -> [MemoryArchiveDay] {
        var byDate = entries.reduce(into: [String: DiaryEntry]()) { $0[$1.date] = $1 }
        for (date, values) in captures where !values.isEmpty && byDate[date] == nil {
            guard DiaryEntry.dateFormatter.date(from: date) != nil else { continue }
            byDate[date] = DiaryEntry(pageID: "local-\(date)", date: date)
        }
        return byDate.values.map {
            MemoryArchiveDay(entry: $0, captures: QuickCapture.sortedForDisplay(captures[$0.date] ?? []))
        }.sorted { $0.id > $1.id }
    }
}
