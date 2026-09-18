import SwiftUI

struct MemoryRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    var onSelectDate: (Date) -> Void

    @State private var query = ""

    private var days: [MemoryArchiveDay] {
        let all = MemoryArchive.days(entries: store.entries, captures: store.quickCaptures)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.matches(needle) }
    }

    private var recent: [MemoryArchiveDay] { Array(days.prefix(8)) }

    private var projects: [ProjectRow] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let cutoffKey = DiaryEntry.dateFormatter.string(from: cutoff)
        let recent = store.entries.filter { $0.date >= cutoffKey }
        let grouped = Dictionary(grouping: recent, by: { $0.category ?? "未分类" })
        return grouped.map { category, entries in
            ProjectRow(name: category, dayCount: entries.count, latestDate: entries.map(\.date).max() ?? "")
        }
        .sorted { $0.latestDate > $1.latestDate }
        .prefix(6)
        .map { $0 }
    }

    private var important: [MemoryArchiveDay] {
        let favoredKeys = Set(store.timelineAnnotations.filter { $0.value.isFavorite }.map(\.key))
        let days = MemoryArchive.days(entries: store.entries, captures: store.quickCaptures)
        return days.filter { day in
            let tagged = !(day.entry.tags ?? []).isEmpty
            let annotated = favoredKeys.contains { $0.contains(day.entry.date) }
            return tagged || annotated
        }
        .prefix(5)
        .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !query.isEmpty {
                        section("Results") {
                            ForEach(recent) { day in
                                MemoryRow(day: day, detail: "\(day.captures.count) 条快记")
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(day) }
                            }
                            if recent.isEmpty {
                                Text("No memories found.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        if !important.isEmpty {
                            section("Important") {
                                ForEach(important) { day in
                                    MemoryRow(day: day, detail: "有笔记或收藏")
                                        .contentShape(Rectangle())
                                        .onTapGesture { open(day) }
                                }
                            }
                        }
                        section("Recent") {
                            ForEach(recent) { day in
                                MemoryRow(day: day, detail: day.hasWriting ? (day.entry.category ?? "随笔") : "\(day.captures.count) 条快记")
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(day) }
                            }
                            if recent.isEmpty {
                                Text("把你的生活留在这里，记忆会慢慢成形。")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !projects.isEmpty {
                            section("Projects") {
                                ForEach(projects) { project in
                                    ProjectRowView(project: project)
                                        .contentShape(Rectangle())
                                        .onTapGesture { openLatest(project) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Memory")
                .font(.system(size: 28, weight: .semibold, design: .serif))
            Spacer()
            Text("记住那些值得记住的。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your past…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 24)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func open(_ day: MemoryArchiveDay) {
        if let date = DiaryEntry.dateFormatter.date(from: day.id) {
            onSelectDate(date)
        }
    }

    private func openLatest(_ project: ProjectRow) {
        if let date = DiaryEntry.dateFormatter.date(from: project.latestDate) {
            onSelectDate(date)
        }
    }
}

private struct ProjectRow: Identifiable {
    var id: String { name }
    var name: String
    var dayCount: Int
    var latestDate: String
}

private struct MemoryRow: View {
    let day: MemoryArchiveDay
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.entry.shortDate)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(day.preview)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .lineLimit(2)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct ProjectRowView: View {
    let project: ProjectRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(project.name)
                .font(.system(size: 14, weight: .medium))
            Text("\(project.dayCount) 天 · 最近 \(project.latestDate)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
