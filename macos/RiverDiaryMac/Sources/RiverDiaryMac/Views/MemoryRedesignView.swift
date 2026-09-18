import SwiftUI

private enum MemoryFilter: String, CaseIterable, Identifiable {
    case all
    case writing
    case captures
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .writing: "有笔记"
        case .captures: "快记"
        case .favorites: "收藏"
        }
    }
}

struct MemoryRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    var onSelectDate: (Date) -> Void

    @State private var query = ""
    @State private var filter: MemoryFilter = .all
    @State private var newestFirst = true

    private var favoriteDates: Set<String> {
        let favoredKeys = store.timelineAnnotations.filter { $0.value.isFavorite }
        return Set(favoredKeys.map(\.key).compactMap { key -> String? in
            guard let first = key.split(separator: "|").first,
                  let timestamp = Int64(first) else { return nil }
            return DiaryEntry.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        })
    }

    private var allDays: [MemoryArchiveDay] {
        MemoryArchive.days(entries: store.entries, captures: store.quickCaptures)
    }

    private var filteredDays: [MemoryArchiveDay] {
        let favorites = favoriteDates
        var days = allDays.filter { day in
            switch filter {
            case .all: true
            case .writing: day.hasWriting
            case .captures: !day.captures.isEmpty
            case .favorites: favorites.contains(day.id)
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            days = days.filter { $0.matches(needle) }
        }
        return days.sorted {
            newestFirst ? $0.id > $1.id : $0.id < $1.id
        }
    }

    private var recent: [MemoryArchiveDay] { Array(filteredDays.prefix(10)) }

    private var projects: [ProjectRow] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        let cutoffKey = DiaryEntry.dateFormatter.string(from: cutoff)
        let recentEntries = store.entries.filter { $0.date >= cutoffKey }
        let grouped = Dictionary(grouping: recentEntries, by: { $0.category ?? "未分类" })
        return grouped.map { category, entries in
            ProjectRow(name: category, dayCount: entries.count, latestDate: entries.map(\.date).max() ?? "")
        }
        .sorted { $0.latestDate > $1.latestDate }
        .prefix(6)
        .map { $0 }
    }

    private var isFiltering: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filter != .all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            searchField
            filterBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if filteredDays.isEmpty {
                        emptyResult
                    } else if isFiltering {
                        section("Results") {
                            ForEach(recent) { day in
                                MemoryRow(day: day, favorite: favoriteDates.contains(day.id))
                                    .contentShape(Rectangle())
                                    .contextMenu { openMenu(day) }
                                    .onTapGesture { open(day) }
                            }
                        }
                    } else {
                        let favored = favoriteDates
                        let importantDays = filteredDays.filter { favoriteContains($0, favored) || tagged($0) }
                        if !importantDays.isEmpty {
                            section("Important") {
                                ForEach(importantDays.prefix(5)) { day in
                                    MemoryRow(day: day, favorite: favoriteDates.contains(day.id))
                                        .contentShape(Rectangle())
                                        .contextMenu { openMenu(day) }
                                        .onTapGesture { open(day) }
                                }
                            }
                        }
                        section("Recent") {
                            ForEach(recent) { day in
                                MemoryRow(day: day, favorite: favoriteDates.contains(day.id))
                                    .contentShape(Rectangle())
                                    .contextMenu { openMenu(day) }
                                    .onTapGesture { open(day) }
                            }
                            if recent.isEmpty {
                                EmptyStateView(
                                    title: "还没有内容",
                                    message: "多写几句、记录快记，或打开 Today 看看这一天的片段，记忆会在这里成形。"
                                )
                            }
                        }
                        if !projects.isEmpty {
                            section("Projects") {
                                ForEach(projects) { project in
                                    ProjectRowView(project: project)
                                        .contentShape(Rectangle())
                                        .contextMenu {
                                            Button("打开最近一天") { openLatest(project) }
                                        }
                                        .onTapGesture { openLatest(project) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func favoriteContains(_ day: MemoryArchiveDay, _ favorites: Set<String>) -> Bool {
        favorites.contains(day.id)
    }

    private func tagged(_ day: MemoryArchiveDay) -> Bool {
        !(day.entry.tags ?? []).isEmpty
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            PageTitle(title: "Memory", subtitle: "搜索你的过去")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search your past…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { /* results update live */ }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16)
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(alignment: .center, spacing: 6) {
            ForEach(MemoryFilter.allCases) { item in
                FilterChip(
                    title: item.title,
                    isSelected: filter == item
                ) {
                    filter = item
                }
            }
            Spacer()
            Button {
                newestFirst.toggle()
            } label: {
                Label(newestFirst ? "最近优先" : "最早优先", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.secondaryInk)
            }
            .buttonStyle(.plain)
            .help("切换排序")
            if isFiltering {
                Button {
                    query = ""
                    filter = .all
                } label: {
                    Label("重置", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.riverAmethyst)
                }
                .buttonStyle(.plain)
                .help("重置搜索与筛选")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var emptyResult: some View {
        EmptyStateView(
            title: "没有找到匹配的记忆",
            message: "换个关键词或筛选条件。搜索范围包括日期、笔记、标签、想法和快记。",
            actionTitle: isFiltering ? "重置条件" : nil,
            action: isFiltering ? { query = ""; filter = .all } : nil
        )
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func openMenu(_ day: MemoryArchiveDay) -> some View {
        Button("打开这一天") { open(day) }
        if day.hasWriting || !day.captures.isEmpty {
            Button("复制预览") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(day.preview, forType: .string)
            }
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
    let favorite: Bool
    @State private var isHovering = false

    private var tags: [String] { day.entry.tags ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(day.entry.shortDate)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if favorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                if !tags.isEmpty {
                    Text(tags.prefix(2).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Text(day.preview)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .foregroundStyle(Color.ink)
            HStack(spacing: 10) {
                if day.hasWriting {
                    Label("日记", systemImage: "doc.text")
                }
                if !day.captures.isEmpty {
                    Label("\(day.captures.count) 条快记", systemImage: "square.and.pencil")
                }
                if !tags.isEmpty {
                    Label("\(tags.count) 个标签", systemImage: "tag")
                }
                if let category = day.entry.category, !category.isEmpty {
                    Label(category, systemImage: "folder")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(isHovering ? Color.primary.opacity(0.03) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
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
