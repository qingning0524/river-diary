import SwiftUI

struct DatabasePreviewWindow: Equatable {
    static let pageSize = 40

    private(set) var pageIndex = 0
    private(set) var totalCount = 0

    var startIndex: Int { max(0, totalCount - (pageIndex + 1) * Self.pageSize) }
    var endIndex: Int { max(0, totalCount - pageIndex * Self.pageSize) }
    var range: Range<Int> { startIndex..<endIndex }
    var canShowNewer: Bool { pageIndex > 0 }
    var canShowOlder: Bool { startIndex > 0 }

    mutating func reset() {
        pageIndex = 0
    }

    mutating func setTotalCount(_ count: Int) {
        totalCount = max(0, count)
        let lastPage = max(0, (totalCount - 1) / Self.pageSize)
        pageIndex = min(pageIndex, lastPage)
    }

    mutating func showOlder() {
        guard canShowOlder else { return }
        pageIndex += 1
    }

    mutating func showNewer() {
        guard canShowNewer else { return }
        pageIndex -= 1
    }
}

struct DatabaseOverviewView: View {
    @Environment(\.riverDensity) private var density
    let selectedDate: Date
    let dailyGoal: DailyGoal?
    @State private var rows: [(table: V2Table, count: Int)] = []
    @State private var lastLoadedAt: Date?
    @State private var selectedTable: V2Table = .rawEvents
    @State private var previewRows: [DatabasePreviewRow] = []
    @State private var previewWindow = DatabasePreviewWindow()

    private var dayLabel: String {
        selectedDate.formatted(.dateTime.year().month().day())
    }

    var body: some View {
        RiverPage(maxWidth: 820) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                PageHeader("数据库", context: "\(dayLabel) · V2 本地事实层") {
                    Button("刷新", action: refresh)
                        .buttonStyle(.plain)
                        .smallAction()
                }
                .riverAppear(index: 0)

                RiverPanel(title: "本地事实层", systemImage: "cylinder.split.1x2", accent: AppTheme.accent, tint: AppTheme.accent) {
                    HStack(alignment: .top, spacing: density.spacing(AppSpacing.md)) {
                        RiverIconWell(systemImage: "cylinder.split.1x2", tint: AppTheme.accent, size: 34)
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                            Text("本机数据库")
                                .font(AppTypography.rowTitle())
                                .foregroundStyle(Color.ink)
                            Text("原始事件保持可追溯，派生活动和分析可以重新生成。当前页面只读，不修改用户数据。")
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.secondaryInk)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            if let lastLoadedAt {
                                Text("最近读取 \(lastLoadedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.tertiaryInk)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .riverAppear(index: 1)

                RiverPanel(title: "数据表 · 全库", systemImage: "tablecells", accent: AppTheme.neutral) {
                    if rows.isEmpty {
                        Text("数据库还没有可展示的表。")
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.table.id) { index, row in
                                HStack(spacing: density.spacing(AppSpacing.sm)) {
                                    Text(row.table.title)
                                        .font(AppTypography.rowTitle())
                                        .foregroundStyle(Color.ink)
                                    Text(row.table.rawValue)
                                        .font(AppTypography.mono())
                                        .foregroundStyle(Color.tertiaryInk)
                                    Spacer(minLength: density.spacing(AppSpacing.sm))
                                    Text("\(row.count) 行")
                                        .font(AppTypography.numeric())
                                        .foregroundStyle(Color.secondaryInk)
                                }
                                .padding(.vertical, density.spacing(7))
                                .overlay(alignment: .bottom) {
                                    if index < rows.count - 1 { RiverRowDivider(inset: 0) }
                                }
                            }
                        }
                    }
                }
                .riverAppear(index: 2)

                RiverPanel(title: "当日记录 · \(previewWindow.totalCount) 条", accent: AppTheme.accent) {
                    HStack(spacing: density.spacing(AppSpacing.xs)) {
                        ForEach([V2Table.rawEvents, .activities, .episodes, .analysisRuns], id: \.self) { table in
                            tableButton(table)
                        }
                    }

                    if previewWindow.totalCount > DatabasePreviewWindow.pageSize {
                        HStack(spacing: 8) {
                            Text("显示第 \(previewWindow.startIndex + 1)–\(previewWindow.endIndex) 条")
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.secondaryInk)
                            Spacer()
                            Button("较新") {
                                previewWindow.showNewer()
                                loadPreview()
                            }
                            .buttonStyle(.plain)
                            .smallAction()
                            .disabled(!previewWindow.canShowNewer)
                            Button("较早") {
                                previewWindow.showOlder()
                                loadPreview()
                            }
                            .buttonStyle(.plain)
                            .smallAction()
                            .disabled(!previewWindow.canShowOlder)
                        }
                    }

                    if previewRows.isEmpty {
                        Text("这一天暂无 \(selectedTable.title) 记录。")
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.top, density.spacing(AppSpacing.xs))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(previewRows.enumerated()), id: \.element.id) { index, row in
                                HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                                    Text(row.time)
                                        .font(AppTypography.mono())
                                        .foregroundStyle(Color.secondaryInk)
                                        .frame(width: 58, alignment: .leading)
                                    VStack(alignment: .leading, spacing: density.spacing(2)) {
                                        Text(row.title)
                                            .font(AppTypography.rowTitle())
                                            .foregroundStyle(Color.ink)
                                            .lineLimit(1)
                                        Text(row.detail)
                                            .font(AppTypography.metadata())
                                            .foregroundStyle(Color.secondaryInk)
                                            .lineLimit(2)
                                    }
                                    Spacer(minLength: density.spacing(AppSpacing.xs))
                                    Text(row.source)
                                        .font(AppTypography.metadata())
                                        .foregroundStyle(AppTheme.accent)
                                }
                                .padding(.vertical, density.spacing(7))
                                .overlay(alignment: .bottom) {
                                    if index < previewRows.count - 1 { RiverRowDivider(inset: 0) }
                                }
                            }
                        }
                    }
                }
                .riverAppear(index: 3)

                RiverPanel(title: "用户记录", systemImage: "target", accent: AppTheme.accent) {
                    if let dailyGoal {
                        HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                            Image(systemName: dailyGoal.isCompleted ? "checkmark.circle.fill" : "target")
                                .foregroundStyle(dailyGoal.isCompleted ? AppTheme.ok : AppTheme.accent)
                            VStack(alignment: .leading, spacing: density.spacing(3)) {
                                Text(dailyGoal.title)
                                    .font(AppTypography.rowTitle())
                                    .foregroundStyle(Color.ink)
                                Text(dailyGoal.isCompleted ? "用户手动确认完成" : "用户目标 · 进行中")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            Spacer(minLength: density.spacing(AppSpacing.sm))
                            Text("加密本地状态")
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.tertiaryInk)
                        }
                    } else {
                        Text("这一天没有用户设定的目标记录。")
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                    }
                }
            }
        }
        .onAppear {
            reload()
            loadPreview()
        }
        .onChange(of: selectedDate) { _, _ in
            previewWindow.reset()
            loadPreview()
        }
    }

    private func reload() {
        let store = V2Store()
        rows = V2Table.allCases.map { ($0, store.countRows(in: $0)) }
        lastLoadedAt = Date()
    }

    private func refresh() {
        previewWindow.reset()
        reload()
        loadPreview()
    }

    @ViewBuilder
    private func tableButton(_ table: V2Table) -> some View {
        if selectedTable == table {
            Button(table.title) {
                selectedTable = table
                previewWindow.reset()
                loadPreview()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button(table.title) {
                selectedTable = table
                previewWindow.reset()
                loadPreview()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func loadPreview() {
        let store = V2Store()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) ?? selectedDate

        switch selectedTable {
        case .rawEvents:
            let events = store.rawEvents(between: start, end: end)
            setPreviewPage(events) { event in
                DatabasePreviewRow(
                    id: event.id.uuidString,
                    time: event.timestamp.formatted(date: .omitted, time: .shortened),
                    title: event.payload.appName ?? event.kind.displayName,
                    detail: event.payload.windowTitle ?? event.payload.text ?? event.kind.displayName,
                    source: event.source.displayName
                )
            }
        case .activities:
            let activities = store.activities(between: start, end: end)
            setPreviewPage(activities) { activity in
                DatabasePreviewRow(
                    id: activity.id.uuidString,
                    time: activity.startTime.formatted(date: .omitted, time: .shortened),
                    title: activity.primaryApp ?? activity.groupKey,
                    detail: "\(activity.category.rawValue) · \(ActivityFormatter.time(activity.duration))",
                    source: "activity"
                )
            }
        case .episodes:
            let episodes = store.episodes(between: start, end: end)
            setPreviewPage(episodes) { episode in
                DatabasePreviewRow(
                    id: episode.id.uuidString,
                    time: episode.startTime.formatted(date: .omitted, time: .shortened),
                    title: episode.title,
                    detail: "\(episode.summary.isEmpty ? "无摘要" : episode.summary) · 置信度 \(episode.confidence)%",
                    source: "episode"
                )
            }
        case .analysisRuns:
            let runs = store.analysisRuns().filter { run in
                calendar.isDate(run.createdAt, inSameDayAs: selectedDate)
            }
            setPreviewPage(runs) { run in
                DatabasePreviewRow(
                    id: run.id.uuidString,
                    time: run.createdAt.formatted(date: .omitted, time: .shortened),
                    title: run.title,
                    detail: run.outputText.isEmpty ? "尚无输出" : run.outputText,
                    source: run.model.isEmpty ? "本机" : run.model
                )
            }
        default:
            previewWindow.setTotalCount(0)
            previewRows = []
        }
    }

    private func setPreviewPage<Item>(
        _ items: [Item],
        makeRow: (Item) -> DatabasePreviewRow
    ) {
        previewWindow.setTotalCount(items.count)
        previewRows = items[previewWindow.range].map(makeRow)
    }
}

private struct DatabasePreviewRow: Identifiable {
    let id: String
    let time: String
    let title: String
    let detail: String
    let source: String
}
