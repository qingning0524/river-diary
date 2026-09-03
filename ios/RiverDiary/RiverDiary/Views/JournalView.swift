import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var store: DiaryStore
    @State private var query = ""

    private var filteredEntries: [DiaryEntry] {
        let text = query.lowercased()
        guard !text.isEmpty else { return store.entries }
        return store.entries.filter {
            ($0.title ?? "").lowercased().contains(text)
                || ($0.overview ?? "").lowercased().contains(text)
                || ($0.mood ?? "").lowercased().contains(text)
                || ($0.tags ?? []).contains { $0.lowercased().contains(text) }
        }
    }

    private var grouped: [(String, [DiaryEntry])] {
        Dictionary(grouping: filteredEntries) { String($0.date.prefix(7)) }
            .map { ($0.key, $0.value) }
            .sorted { $0.0 > $1.0 }
    }

    var body: some View {
        NavigationStack {
            List {
                if filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(grouped, id: \.0) { month, entries in
                        Section(month) {
                            ForEach(entries) { entry in
                                NavigationLink(value: entry) {
                                    JournalRow(entry: entry)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索标题、心情、标签")
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("日记")
            .navigationDestination(for: DiaryEntry.self) { entry in
                EntryDetailView(entry: entry)
            }
        }
    }
}

struct JournalRow: View {
    let entry: DiaryEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack {
                Text(String(entry.date.suffix(2)))
                    .font(.title3.weight(.bold))
                Text("\(Int(entry.date.dropFirst(5).prefix(2)) ?? 1)月")
                    .font(.caption2)
            }
            .frame(width: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(entry.overview ?? entry.mood ?? "无内容")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
            Text(entry.score.map { String(format: "%.0f", $0) } ?? "—")
                .font(.headline)
                .foregroundStyle(entry.stageColor)
        }
        .padding(.vertical, 3)
    }
}
