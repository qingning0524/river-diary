import SwiftUI

struct WorkLearnWorkspaceView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var activity: ActivityStore
    let entries: [DiaryEntry]
    let selectedDate: Date
    @FocusState.Binding var inspectorSourceFocusID: String?
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void

    private var stats: FusedDayStats { activity.dayStats(entries: entries, date: selectedDate) }
    private var sessions: [ActivitySession] { activity.liveSessions(for: selectedDate) }
    private var timeline: ActivityTimeline { ActivityTimelineEngine.build(for: selectedDate, sessions: sessions) }

    var body: some View {
        RiverPage {
            PageHeader("学习与工作", context: selectedDate.formatted(.dateTime.year().month().day())) {
                StatusBadge("事实优先", tone: .neutral)
            }
            .riverAppear(index: 0)

            RiverPanel(title: "时间分布", systemImage: "chart.bar", accent: AppTheme.accent, tint: AppTheme.accent) {
                if stats.categoryUsage.isEmpty {
                    Text("这一天还没有足够的分类证据。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(stats.categoryUsage.prefix(8).enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: density.spacing(10)) {
                                Image(systemName: ActivityClassifier.symbol(for: item.name))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(AppTheme.categoryTint(item.category))
                                    .frame(width: 18)
                                Text(item.category)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.ink)
                                    .frame(width: 54, alignment: .leading)
                                Text(item.name)
                                    .font(AppTypography.secondary())
                                    .foregroundStyle(Color.secondaryInk)
                                    .lineLimit(1)
                                Spacer(minLength: density.spacing(AppSpacing.sm))
                                Text(item.timeText)
                                    .font(AppTypography.numeric())
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            .padding(.vertical, density.spacing(7))
                            .overlay(alignment: .bottom) {
                                if index < min(stats.categoryUsage.count, 8) - 1 { RiverRowDivider(inset: 0) }
                            }
                        }
                    }
                }
            }
            .riverAppear(index: 1)

            RiverPanel(title: "项目与浏览证据", systemImage: "doc.text.magnifyingglass", accent: AppTheme.neutral) {
                VStack(spacing: 0) {
                    evidenceRow("项目足迹", stats.pipelineTotal > 0 ? ActivityFormatter.time(stats.pipelineTotal) : "未知", "项目数据管道")
                    evidenceRow("实时足迹", stats.liveTotal > 0 ? ActivityFormatter.time(stats.liveTotal) : "未知", "macOS 实时片段")
                    evidenceRow("浏览来源", stats.browseUsage.isEmpty ? "未知" : "\(stats.browseUsage.count) 个站点", "浏览历史", showsDivider: false)
                }
            }
            .riverAppear(index: 2)

            RiverPanel(title: "时间线证据", systemImage: "timeline.selection", accent: AppTheme.accent, padding: AppSpacing.sm) {
                RiverTimelineView(
                    items: Array(timeline.items.prefix(12)),
                    nowSession: Calendar.current.isDateInToday(selectedDate) ? activity.activeSession : nil,
                    selectedItemID: nil,
                    onSelect: onSelectTimelineItem,
                    onWriteNote: {},
                    inspectorSourceFocusID: $inspectorSourceFocusID,
                    isScrollable: true
                )
                .frame(height: 320)
            }
            .riverAppear(index: 3)
        }
    }

    private func evidenceRow(_ title: String, _ value: String, _ source: String, showsDivider: Bool = true) -> some View {
        RiverValueRow(title: title, value: value, detail: source, showsDivider: showsDivider)
    }
}
