import SwiftUI

struct CommandPaletteSelection: Equatable {
    private(set) var index = 0

    mutating func reset() {
        index = 0
    }

    mutating func moveDown(itemCount: Int) {
        guard itemCount > 0 else {
            index = 0
            return
        }
        index = min(index + 1, itemCount - 1)
    }

    mutating func moveUp(itemCount: Int) {
        guard itemCount > 0 else {
            index = 0
            return
        }
        index = max(index - 1, 0)
    }

    func selectedIndex(itemCount: Int) -> Int? {
        itemCount > 0 && index < itemCount ? index : nil
    }
}

/// ⌘K quick command palette: navigate pages and run the most common actions.
/// Real actions only — every row maps to an existing destination or handler.
struct CommandPaletteView: View {
    var onNavigate: (RiverDestination) -> Void
    var onWriteNote: () -> Void
    var onRefresh: () -> Void
    var onImport: () -> Void
    var onOpenSettings: () -> Void
    var entries: [DiaryEntry] = []
    var onOpenDay: (DiaryEntry) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = CommandPaletteSelection()
    @FocusState private var focused: Bool
    @State private var hoverIndex: Int?

    private struct CommandItem: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let keywords: String
        /// 右侧尾注（如 ⌘1）：与「前往」菜单一致的快捷键。
        var shortcutText: String?
        let run: () -> Void
    }

    private var all: [CommandItem] {
        let navigation = RiverNavigationGroup.allCases.flatMap(\.destinations).map { destination in
            CommandItem(
                id: destination.rawValue, title: "前往 " + destination.title,
                symbol: destination.symbol,
                keywords: destination.title + " " + destination.group.title + " " + destination.searchKeywords,
                shortcutText: destination.navigationShortcut.label
            ) { onNavigate(destination) }
        }
        let sections = [RiverDestination.footprints, .health, .confirmations, .habitReview, .progress].map { item in
            CommandItem(id: item.rawValue, title: item.workspaceRoot.title + " · " + item.sectionTitle,
                        symbol: item.symbol, keywords: item.searchKeywords + " " + item.title,
                        shortcutText: item.navigationShortcut.label) { onNavigate(item) }
        }
        let commands: [CommandItem] = navigation + sections + [
            .init(id: "sources", title: "设置 · 数据源与采集", symbol: "gearshape", keywords: "sources 数据源 权限 采集", shortcutText: "⌘⇧S") { onNavigate(.sources) },
            .init(id: "database", title: "设置 · 本地数据库", symbol: "externaldrive", keywords: "database 数据库 原始记录", shortcutText: "⌘0") { onNavigate(.database) },
            .init(id: "note", title: "写一句快记", symbol: "square.and.pencil", keywords: "note 快记 写", shortcutText: "⌘N") { onWriteNote() },
            .init(id: "refresh", title: "立即采集", symbol: "arrow.clockwise", keywords: "refresh 采集 刷新", shortcutText: "⌘R") { onRefresh() },
            .init(id: "import", title: "导入数据文件…", symbol: "folder.badge.plus", keywords: "import 数据 导入 ios", shortcutText: nil) { onImport() },
            .init(id: "settings", title: "打开设置", symbol: "gearshape", keywords: "settings 设置 偏好", shortcutText: "⌘,") { onOpenSettings() },
        ]
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return commands }
        let matches = CommandPaletteArchiveSearch.matches(entries: entries, query: needle).prefix(8).map { entry in
            CommandItem(
                id: "archive-" + entry.id,
                title: entry.shortDate + " · " + String(entry.displayOverview.prefix(34)),
                symbol: "book", keywords: CommandPaletteArchiveSearch.searchText(entry),
                shortcutText: "日记"
            ) { onOpenDay(entry) }
        }
        return Array(matches) + commands
    }

    private var filtered: [CommandItem] {
        let n = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.isEmpty { return all }
        return all.filter {
            $0.title.localizedStandardContains(n) || $0.keywords.localizedStandardContains(n)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                TextField("搜索记忆、日期，或功能…", text: $query)
                    .textFieldStyle(.plain)
                    .font(AppTypography.primary())
                    .focused($focused)
                    .onExitCommand { dismiss() }
                    .onSubmit { runSelected() }
                    .onChange(of: query) { _, _ in selection.reset() }
                    .onKeyPress(.downArrow) {
                        selection.moveDown(itemCount: filtered.count)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selection.moveUp(itemCount: filtered.count)
                        return .handled
                    }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.tertiaryInk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除命令")
                    .help("清除搜索词")
                }
            }
            .padding(AppSpacing.md)

            RiverRule()

            if filtered.isEmpty {
                EmptyStateView(
                    title: "没有匹配的命令",
                    message: "换个词试试，或按 Esc 关闭。",
                    symbol: "magnifyingglass"
                )
                .padding(AppSpacing.md)
            } else {
                ScrollView {
                    LazyVStack(spacing: AppSpacing.xxs) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                            let isHighlighted = index == selection.index || index == hoverIndex
                            Button {
                                dismiss()
                                item.run()
                            } label: {
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(isHighlighted ? Color.ctaText : AppTheme.accent)
                                        .frame(width: 20)
                                        .accessibilityHidden(true)
                                    Text(item.title)
                                        .font(AppTypography.primary())
                                        .foregroundStyle(isHighlighted ? Color.ctaText : Color.ink)
                                    Spacer(minLength: 0)
                                    if let shortcutText = item.shortcutText {
                                        Text(shortcutText)
                                            .font(AppTypography.kicker())
                                            .foregroundStyle(isHighlighted ? Color.ctaText.opacity(0.8) : Color.tertiaryInk)
                                    }
                                }
                                .padding(.horizontal, AppSpacing.sm)
                                .frame(minHeight: AppSpacing.rowHeight)
                                .contentShape(Rectangle())
                                .background(
                                    isHighlighted ? AppTheme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            // 键盘高亮之外补鼠标悬停：指针用户悬停行没有任何反馈会显得"死"。
                            .onHover { hovering in
                                hoverIndex = hovering ? index : (hoverIndex == index ? nil : hoverIndex)
                            }
                        }
                    }
                    .padding(AppSpacing.xs)
                }
                .frame(maxHeight: 320)
                .riverScrollIndicators()
            }

            // 操作提示：面板自解释，不猜按键。
            RiverRule()
            HStack(spacing: AppSpacing.sm) {
                Text("↑↓ 选择")
                Text("·").foregroundStyle(Color.tertiaryInk)
                Text("↩ 执行")
                Text("·").foregroundStyle(Color.tertiaryInk)
                Text("esc 关闭")
            }
            .font(AppTypography.micro())
            .foregroundStyle(Color.secondaryInk)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.xs)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 460)
        .background(Color.strongSurface)
        .onAppear { focused = true }
    }

    private func runSelected() {
        guard let index = selection.selectedIndex(itemCount: filtered.count) else { return }
        dismiss()
        filtered[index].run()
    }
}

enum CommandPaletteArchiveSearch {
    static func searchText(_ entry: DiaryEntry) -> String {
        ([entry.date, entry.displayOverview, entry.daily ?? ""] + (entry.memos ?? []) + (entry.tags ?? [])).joined(separator: " ")
    }
    static func matches(entries: [DiaryEntry], query: String) -> [DiaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return entries.filter { searchText($0).localizedStandardContains(needle) }
    }
}
