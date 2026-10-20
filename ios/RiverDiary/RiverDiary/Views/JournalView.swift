import RiverDiaryCore
import SwiftUI

struct JournalView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    var onEditRequest: (Date) -> Void

    private struct Item: Identifiable {
        let day: String
        let shared: RiverSharedStateRecord?
        let legacy: DiaryEntry?
        var id: String { day }
        var text: String {
            if let content = shared?.journalEntryContent { return content.body }
            guard let legacy else { return "" }
            let sections = [legacy.overview, legacy.mood].compactMap { $0 } + (legacy.thoughts ?? []) + (legacy.memos ?? [])
            return sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        }
        var title: String { legacy?.displayTitle ?? text.split(separator: "\n").first.map { String($0.prefix(28)) } ?? "一段日记" }
        var tags: String { (shared?.journalEntryContent?.tags ?? legacy?.tags ?? []).filter { $0 != "river-favorite" }.joined(separator: " ") }
        var favorite: Bool { shared?.journalEntryContent?.tags.contains("river-favorite") == true }
    }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var items: [Item] {
        let legacyDays = Set(store.entries.map(\.date))
        let modern = (node.database?.sharedUserRecords ?? []).filter {
            guard $0.kind == .journalEntry, $0.status == "current", let content = $0.journalEntryContent,
                  !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            return content.source != "legacy-data.json" || !legacyDays.contains(content.dayKey)
        }.compactMap { record -> Item? in
            guard let content = record.journalEntryContent else { return nil }
            return Item(day: content.dayKey, shared: record, legacy: nil)
        }
        let modernDays = Set(modern.map(\.day))
        let imported = store.entries.filter { !modernDays.contains($0.date) }.map { Item(day: $0.date, shared: nil, legacy: $0) }
        return (modern + imported).filter { item in
            searchText.isEmpty || [item.day, item.title, item.text, item.tags].contains { $0.localizedCaseInsensitiveContains(searchText) }
        }.sorted { $0.day > $1.day }
    }
    /// Sort the canonical yyyy-MM key before formatting: localized month titles are not chronological keys.
    private var grouped: [(String, [Item])] {
        Dictionary(grouping: items) { String($0.day.prefix(7)) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }
    private func monthTitle(_ key: String) -> String {
        guard key.count == 7, let year = Int(key.prefix(4)), let month = Int(key.suffix(2)), (1...12).contains(month) else { return key }
        return "\(year)年\(month)月"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        RiverSystemSignature()
                        Text("重读这些日子").font(theme.titleFont)
                        Text(searchText.isEmpty ? "按月份，慢慢翻回过去。" : "找到 \(items.count) 篇日记")
                            .font(theme.textFont(15)).foregroundStyle(theme.secondaryInk)
                    }
                    if items.isEmpty {
                        RiverEmptyState(title: searchText.isEmpty ? "第一篇日记，从今天开始" : "没有找到相关日记", detail: searchText.isEmpty ? "写下一句话，下一次就能在这里重读。" : "试试日期、正文、标题或标签。", systemImage: "book.closed", showsChrome: false, actionTitle: searchText.isEmpty ? "写今天的日记" : "清除搜索") {
                            if searchText.isEmpty { editDay(.now) } else { query = "" }
                        }
                    } else {
                        ForEach(grouped, id: \.0) { month, entries in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(monthTitle(month)).font(theme.sectionFont).accessibilityAddTraits(.isHeader)
                                    Spacer()
                                    Text("\(entries.count) 篇").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                                }.padding(.bottom, 4)
                                ForEach(entries) { item in
                                    NavigationLink {
                                        if let record = item.shared {
                                            RiverSavedJournalView(id: record.id, onEdit: editDay, onOpenDay: openDay)
                                        } else if let legacy = item.legacy {
                                            RiverArchiveLegacyJournalView(entry: legacy, onEdit: editDay, onOpenDay: openDay)
                                        }
                                    } label: {
                                        let layout = dynamicTypeSize.isAccessibilitySize
                                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                                        layout {
                                            if dynamicTypeSize.isAccessibilitySize {
                                                Text(item.day).font(.footnote).foregroundStyle(theme.secondaryInk)
                                            } else {
                                                Text(String(item.day.suffix(2))).font(theme.textFont(24, relativeTo: .title3, weight: .medium)).monospacedDigit().frame(width: 38, alignment: .leading)
                                            }
                                            VStack(alignment: .leading, spacing: 6) {
                                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                                    Text(item.title).font(theme.textFont(17, relativeTo: .headline, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                                    if item.favorite { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(theme.accentText) }
                                                }
                                                Text(item.text).font(theme.textFont(14)).foregroundStyle(theme.secondaryInk).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                                                Text(item.shared == nil ? "历史日记" : "你写下的日记").font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                                            }.frame(maxWidth: .infinity, alignment: .leading)
                                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk).padding(.top, 6)
                                        }.padding(.vertical, 12).frame(minHeight: 72).contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityIdentifier("river.journal.archive.\(item.day)")
                                    Divider().overlay(theme.separator)
                                }
                            }
                        }
                    }
                }.padding(.horizontal, theme.pageGutter).padding(.top, 20).padding(.bottom, 32)
            }
            .foregroundStyle(theme.ink).background(theme.canvas)
            .searchable(text: $query, prompt: "搜索日期、正文、标题或标签")
            .navigationTitle("日记档案").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.accessibilityLabel("关闭日记") } }
        }.tint(theme.accentText)
    }
    private func openDay(_ date: Date) {
        dismiss()
        coordinator.openTimeline(day: date)
    }
    private func editDay(_ date: Date) {
        onEditRequest(date)
    }
}

struct RiverSavedJournalView: View {
    @Environment(\.riverTheme) private var theme
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    let id: UUID
    var onEdit: ((Date) -> Void)? = nil
    var onOpenDay: ((Date) -> Void)? = nil
    private var record: RiverSharedStateRecord? { node.database?.sharedUserRecords.first { $0.id == id && $0.status == "current" } }
    var body: some View {
        ScrollView {
            if let content = record?.journalEntryContent {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(content.dayKey).font(theme.textFont(13, relativeTo: .footnote)).foregroundStyle(theme.accentText).monospacedDigit()
                        Text("这一天的手记").font(theme.titleFont)
                        Text("你写下的日记").font(theme.textFont(13)).foregroundStyle(theme.secondaryInk)
                    }
                    Text(content.body).font(theme.textFont(18)).lineSpacing(9).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if let mood = content.moodScore {
                        Text("当时的心情 · \(mood) / 100").font(theme.textFont(14)).foregroundStyle(theme.secondaryInk)
                    }
                    let tags = content.tags.filter { $0 != "river-favorite" }
                    if !tags.isEmpty { Text(tags.map { "#\($0)" }.joined(separator: "  ")).font(theme.textFont(13)).foregroundStyle(theme.accentText) }
                    Divider().overlay(theme.separator)
                    Text("最近保存 · \(content.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                }.padding(.horizontal, theme.pageGutter).padding(.top, 24).padding(.bottom, 32)
            } else { ContentUnavailableView("这篇日记暂不可用", systemImage: "book.closed") }
        }
        .foregroundStyle(theme.ink).background(theme.canvas).navigationTitle("日记正文").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if let content = record?.journalEntryContent, let date = riverArchiveDate(for: content.dayKey) {
                RiverJournalReadingActions(date: date, onEdit: { value in
                    if let onEdit { onEdit(value) } else { coordinator.presentJournal(on: value) }
                }, onOpenDay: { value in
                    if let onOpenDay { onOpenDay(value) } else { coordinator.openTimeline(day: value) }
                })
            }
        }
    }
}

struct RiverArchiveLegacyJournalView: View {
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    let entry: DiaryEntry
    var onEdit: ((Date) -> Void)? = nil
    var onOpenDay: ((Date) -> Void)? = nil
    var body: some View {
        EntryDetailView(entry: entry)
            .toolbar(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                RiverJournalReadingActions(date: entry.entryDate, onEdit: { date in
                    if let onEdit { onEdit(date) } else { coordinator.presentJournal(on: date) }
                }, onOpenDay: { date in
                    if let onOpenDay { onOpenDay(date) } else { coordinator.openTimeline(day: date) }
                })
            }
    }
}

private struct RiverJournalReadingActions: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let date: Date
    let onEdit: (Date) -> Void
    let onOpenDay: (Date) -> Void
    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button { onOpenDay(date) } label: { Label("回到当天", systemImage: "calendar").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.plain).foregroundStyle(theme.accentText).accessibilityIdentifier("river.journal.read.openDay")
            Button { onEdit(date) } label: { Label("继续编辑", systemImage: "square.and.pencil").frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.plain).foregroundStyle(theme.palette.onAccent)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("river.journal.read.edit")
        }
        .font(theme.textFont(15, weight: .medium)).padding(.horizontal, theme.pageGutter).padding(.vertical, 12)
        .background(theme.canvas)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }
}

private func riverArchiveDate(for key: String) -> Date? {
    let values = key.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3 else { return nil }
    return Calendar.current.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
}
