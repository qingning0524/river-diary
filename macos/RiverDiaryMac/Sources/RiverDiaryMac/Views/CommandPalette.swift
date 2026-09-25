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
    var onOpenSource: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = CommandPaletteSelection()
    @FocusState private var focused: Bool

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
        [
            .init(id: "today", title: "前往今日", symbol: "book.closed", keywords: "today 今天 首页", shortcutText: RiverDestination.today.navigationShortcut.label) { onNavigate(.today) },
            .init(id: "timeline", title: "打开时间线", symbol: "timeline.selection", keywords: "timeline 时间线 足迹", shortcutText: RiverDestination.timeline.navigationShortcut.label) { onNavigate(.timeline) },
            .init(id: "daily-review", title: "打开每日复盘", symbol: "checklist", keywords: "review 复盘 回顾", shortcutText: RiverDestination.dailyReview.navigationShortcut.label) { onNavigate(.dailyReview) },
            .init(id: "health", title: "查看健康", symbol: "heart.text.square", keywords: "health 健康 睡眠 心情 运动", shortcutText: RiverDestination.health.navigationShortcut.label) { onNavigate(.health) },
            .init(id: "footprints", title: "查看足迹", symbol: "mappin.and.ellipse", keywords: "footprints 足迹 地点 位置", shortcutText: RiverDestination.footprints.navigationShortcut.label) { onNavigate(.footprints) },
            .init(id: "work-learn", title: "查看学习与工作", symbol: "hammer.fill", keywords: "work learn 学习 工作 项目", shortcutText: RiverDestination.workLearn.navigationShortcut.label) { onNavigate(.workLearn) },
            .init(id: "memory", title: "前往记忆", symbol: "archivebox", keywords: "memory 记忆 搜索", shortcutText: RiverDestination.memory.navigationShortcut.label) { onNavigate(.memory) },
            .init(id: "ask", title: "前往询问", symbol: "questionmark.circle", keywords: "ask 询问 提问", shortcutText: RiverDestination.ask.navigationShortcut.label) { onNavigate(.ask) },
            .init(id: "progress", title: "查看进展", symbol: "chart.line.uptrend.xyaxis", keywords: "progress 进展 对比 趋势", shortcutText: RiverDestination.progress.navigationShortcut.label) { onNavigate(.progress) },
            .init(id: "database", title: "打开数据库", symbol: "cylinder.split.1x2", keywords: "database 数据库 原始数据 证据", shortcutText: RiverDestination.database.navigationShortcut.label) { onNavigate(.database) },
            .init(id: "sources", title: "查看数据源", symbol: "antenna.radiowaves.left.and.right", keywords: "sources 数据源 权限 采集", shortcutText: RiverDestination.sources.navigationShortcut.label) { onNavigate(.sources) },
            .init(id: "note", title: "写一句快记", symbol: "square.and.pencil", keywords: "note 快记 写", shortcutText: "⌘N") { onWriteNote() },
            .init(id: "refresh", title: "立即采集", symbol: "arrow.clockwise", keywords: "refresh 采集 刷新", shortcutText: nil) { onRefresh() },
            .init(id: "source", title: "打开数据源…", symbol: "folder", keywords: "source 数据 导入", shortcutText: nil) { onOpenSource() },
        ]
    }

    private var filtered: [CommandItem] {
        let n = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if n.isEmpty { return all }
        return all.filter {
            $0.title.lowercased().contains(n) || $0.keywords.lowercased().contains(n)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppSpacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                TextField("命令…", text: $query)
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
                            Button {
                                dismiss()
                                item.run()
                            } label: {
                                HStack(spacing: AppSpacing.sm) {
                                    Image(systemName: item.symbol)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(index == selection.index ? Color.ctaText : AppTheme.accent)
                                        .frame(width: 20)
                                    Text(item.title)
                                        .font(AppTypography.primary())
                                        .foregroundStyle(index == selection.index ? Color.ctaText : Color.ink)
                                    Spacer(minLength: 0)
                                    if let shortcutText = item.shortcutText {
                                        Text(shortcutText)
                                            .font(AppTypography.kicker())
                                            .foregroundStyle(index == selection.index ? Color.ctaText.opacity(0.8) : Color.tertiaryInk)
                                    }
                                }
                                .padding(.horizontal, AppSpacing.sm)
                                .frame(minHeight: AppSpacing.rowHeight)
                                .contentShape(Rectangle())
                                .background(
                                    index == selection.index ? AppTheme.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(AppSpacing.xs)
                }
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
