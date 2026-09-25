import SwiftUI

/// 常驻证据控制台（右栏静息态）。
///
/// DESIGN.md 规划的"右侧证据控制台"：宽窗（≥1320pt）且未选中任何节点时，
/// 右列不停留在空白，而是回答三个始终成立的问题——
/// 仪器在工作吗（正在记录）、有什么需要我纠正（待确认）、数据在我手里吗（信任）。
/// 选中时间线节点后，同一列被证据详情（InspectorPanel）接管。
///
/// 窄窗下整列收起，不挤压内容。
struct EvidenceConsoleView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    /// 与全进程共享的 V2 连接；信任卡读取证据规模。
    let v2Store: V2Store
    let selectedDate: Date
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onStartTracking: () -> Void

    private var entry: DiaryEntry { store.entry(for: selectedDate) }

    /// 每帧构建一次时间线；控制台只在 store 发布变更时重渲染。
    private func buildTimeline() -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: store.captures(for: entry),
            annotations: store.timelineAnnotations
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                nowCard
                reviewQueueCard
                trustCard
            }
            .padding(.leading, density.spacing(AppSpacing.md))
            .padding(.trailing, density.spacing(AppSpacing.page))
            .padding(.top, AppSpacing.headerTop)
            .padding(.bottom, density.spacing(AppSpacing.lg))
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.workspace)
        .overlay(alignment: .leading) { RiverRule().frame(width: 1) }
    }

    // MARK: - 正在记录

    private var nowCard: some View {
        RiverPanel(title: "正在记录", systemImage: "dot.radiowaves.left.and.right", accent: AppTheme.accent) {
            if activity.isTracking {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                    if let active = activity.activeSession {
                        HStack(spacing: density.spacing(AppSpacing.sm)) {
                            Circle()
                                .fill(AppTheme.recording)
                                .frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                            Text(active.appName)
                                .font(AppTypography.rowTitle())
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(ActivityFormatter.time(Date().timeIntervalSince(active.start)))
                                .font(AppTypography.numeric())
                                .foregroundStyle(Color.secondaryInk)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("正在记录 \(active.appName)，已持续 \(ActivityFormatter.time(Date().timeIntervalSince(active.start)))")
                    } else {
                        Text("当前没有前台片段；应用切换后会自动继续。")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    todayTotalRow
                    if let saved = activity.lastSavedAt {
                        Text("上次保存 \(saved.formatted(date: .omitted, time: .shortened))")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                    Text("实时记录未开启。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("开始记录") { onStartTracking() }
                        .buttonStyle(.plain)
                        .smallAction()
                }
            }
        }
    }

    private var todayTotalRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日已记录")
                .font(AppTypography.label())
                .foregroundStyle(Color.secondaryInk)
            Spacer(minLength: 0)
            Text(ActivityFormatter.time(todayTotal))
                .font(AppTypography.numeric())
                .foregroundStyle(Color.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private var todayTotal: TimeInterval {
        activity
            .liveSessions(for: Date())
            .reduce(0) { $0 + max($1.duration, $1.end.timeIntervalSince($1.start)) }
    }

    // MARK: - 待确认

    private var reviewQueueCard: some View {
        let timeline = buildTimeline()
        let items = Array(timeline.items.filter { item in
            item.annotation?.isReviewed != true && (item.kind == .gap || item.sessions.contains { session in
                (session.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }.prefix(4))

        return RiverPanel(
            title: "需要你确认",
            systemImage: "questionmark.circle",
            detail: items.isEmpty ? "没有待确认项" : "\(items.count) 条",
            accent: AppTheme.warning
        ) {
            if items.isEmpty {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppTheme.ok)
                        .accessibilityHidden(true)
                    Text("\(Calendar.current.isDateInToday(selectedDate) ? "今天" : "这一天")没有需要确认的时间片。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(spacing: density.spacing(AppSpacing.xxs)) {
                    ForEach(items) { item in
                        consoleReviewRow(item)
                    }
                    Text("更多待确认项在时间线。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                }
            }
        }
    }

    private func consoleReviewRow(_ item: ActivityTimelineItem) -> some View {
        let focusID = "console-review:\(item.id)"
        return Button {
            onSelectTimelineItem(item, focusID)
        } label: {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                VStack(alignment: .leading, spacing: density.spacing(2)) {
                    Text(item.title)
                        .font(AppTypography.rowTitle())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(item.start.formatted(date: .omitted, time: .shortened))
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.tertiaryInk)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, density.spacing(AppSpacing.sm))
            .padding(.vertical, density.spacing(6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看待确认：\(item.title)，\(item.start.formatted(date: .omitted, time: .shortened))")
    }

    // MARK: - 信任

    private var trustCard: some View {
        RiverPanel(title: "信任", systemImage: "lock.shield", accent: AppTheme.ok) {
            VStack(spacing: 0) {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Text("本机加密")
                        .font(AppTypography.label())
                        .foregroundStyle(Color.secondaryInk)
                    Spacer(minLength: 0)
                    StatusBadge(store.isEncrypted ? "已开启" : "未开启", tone: store.isEncrypted ? .positive : .attention)
                }
                .padding(.vertical, density.spacing(6))
                RiverRowDivider(inset: 0)
                trustRow(title: "上次采集", value: lastCaptureText)
                trustRow(title: "V2 证据", value: "\(v2Store.countRows(in: .rawEvents)) 条原始事件")
                trustRow(title: "实时片段", value: "\(activity.sessions.count) 段 · 近 365 天", showsDivider: false)
            }
        }
    }

    private var lastCaptureText: String {
        if let last = ingestion.lastIngestedAt {
            let prefix = Calendar.current.isDateInToday(last) ? "今天 " : ""
            return "\(prefix)\(last.formatted(date: .omitted, time: .shortened))"
        }
        return ingestion.enabled ? "等待下一次采集" : "未启用"
    }

    private func trustRow(title: String, value: String, showsDivider: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTypography.label())
                .foregroundStyle(Color.secondaryInk)
            Spacer(minLength: 0)
            Text(value)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, density.spacing(6))
        .overlay(alignment: .bottom) {
            if showsDivider { RiverRowDivider(inset: 0) }
        }
        .accessibilityElement(children: .combine)
    }
}
