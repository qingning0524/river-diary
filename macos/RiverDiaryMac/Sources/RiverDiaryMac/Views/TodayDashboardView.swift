import SwiftUI

/// Phase 1 home: orient first, then open the evidence behind the day.
///
/// Reading order: glance (totals + the day band) → read (the day brief) →
/// inspect (time split, goal, facts) → act (the review queue).
struct TodayDashboardView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    let selectedDate: Date
    @FocusState.Binding var inspectorSourceFocusID: String?
    var onOpenTimeline: () -> Void
    var onOpenJournal: () -> Void
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onShowCapture: () -> Void
    var onOpenAsk: (String) -> Void
    var onOpenFootprints: () -> Void
    var onOpenSettings: () -> Void

    @State private var reportError: String?
    @State private var isBriefExpanded = false

    private var entry: DiaryEntry { store.entry(for: selectedDate) }
    private var isSelectedDateToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var selectedDateLabel: String { selectedDate.formatted(.dateTime.month().day()) }
    private var pageTitle: String {
        selectedDate.formatted(.dateTime.month().day().weekday(.wide))
    }
    private var dayName: String { isSelectedDateToday ? "今天" : "这一天" }
    private var captures: [QuickCapture] { store.captures(for: entry) }

    /// 一帧渲染的全部昂贵派生值。dayStats、时间线引擎和日报生成都不便宜，
    /// 而本页观察的 store 每次自动保存草稿都会发布变更——必须每帧只算一次。
    struct Snapshot {
        let entry: DiaryEntry
        let captures: [QuickCapture]
        let stats: FusedDayStats
        let timeline: ActivityTimeline
        let localReport: LocalDayReport
    }

    private func makeSnapshot() -> Snapshot {
        let snapshotEntry = store.entry(for: selectedDate)
        let snapshotCaptures = store.captures(for: snapshotEntry)
        let snapshotStats = activity.dayStats(entries: store.entries, date: selectedDate)
        let snapshotTimeline = ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: snapshotCaptures,
            annotations: store.timelineAnnotations
        )
        let writing = snapshotEntry.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines)
        let brief: String
        if !writing.isEmpty {
            brief = snapshotEntry.displayOverview
        } else if !snapshotStats.headline.isEmpty {
            brief = snapshotStats.headline
        } else if snapshotTimeline.items.isEmpty {
            brief = "这一天还没有足够证据，先从一个来源开始。"
        } else {
            brief = "这一天已有 \(snapshotTimeline.items.count) 个时间节点，可以沿时间线查看。"
        }
        let fallbackKind = LocalDayReportKind.fallbackKind(
            hasDiaryContent: !writing.isEmpty,
            hasSourceSnapshot: snapshotStats.pipelineAvailable
        )
        let report = LocalDayReportBuilder.make(
            timeline: snapshotTimeline,
            stats: snapshotStats,
            fallback: brief,
            fallbackKind: fallbackKind
        )
        return Snapshot(
            entry: snapshotEntry,
            captures: snapshotCaptures,
            stats: snapshotStats,
            timeline: snapshotTimeline,
            localReport: report
        )
    }

    private func hasRecordedTime(_ s: Snapshot) -> Bool { s.timeline.totalDuration > 0 }

    private func focusShareText(_ s: Snapshot) -> String {
        guard hasRecordedTime(s) else { return "还没有可计的记录" }
        let share = Int((s.stats.focusTotal / s.timeline.totalDuration) * 100)
        return "占全部记录 \(share)%"
    }

    private func longestSessionCaption(_ s: Snapshot) -> String {
        guard let longest = s.stats.longestSession else { return "没有可识别的连续片段" }
        return "\(longest.appName) · \(ActivityFormatter.timeRange(longest.start, longest.end))"
    }

    private func workDuration(_ s: Snapshot) -> TimeInterval {
        s.stats.categoryUsage
            .filter { ActivityClassifier.isFocus($0.category) }
            .reduce(0) { $0 + $1.duration }
    }

    private func entertainmentDuration(_ s: Snapshot) -> TimeInterval {
        s.stats.categoryUsage
            .filter { $0.category == "娱乐" }
            .reduce(0) { $0 + $1.duration }
    }

    private func categorySlices(_ s: Snapshot) -> [TodayCategorySlice] {
        let total = s.stats.categoryUsage.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }
        return s.stats.categoryUsage.prefix(5).map { item in
            TodayCategorySlice(
                name: item.name,
                durationText: ActivityFormatter.time(item.duration),
                tint: AppTheme.categoryTint(item.category),
                fraction: CGFloat(min(item.duration / total, 1))
            )
        }
    }

    private func healthSummary(_ s: Snapshot) -> String {
        guard let health = s.entry.health else { return "健康数据未知，不按零计算" }
        var values: [String] = []
        if let sleep = health.resolvedSleepHours { values.append("睡眠 \(sleep.formatted(.number.precision(.fractionLength(1))))h") }
        if let steps = health.steps { values.append("步数 \(steps)") }
        if let energy = health.activeEnergyKcal { values.append("活动 \(Int(energy))kcal") }
        return values.isEmpty ? "健康数据部分缺失" : values.joined(separator: " · ")
    }

    private var dateKey: String { DiaryEntry.dateFormatter.string(from: selectedDate) }

    private var dailyTaskState: AITaskState? { ai.state(for: .analysisDaily) }

    private var dailyReport: String? {
        guard let answer = dailyTaskState?.answer?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else {
            return nil
        }
        return answer
    }

    private var dailyReportSource: String {
        if let state = dailyTaskState, let updatedAt = state.updatedAt {
            return "AI 生成于 \(updatedAt.formatted(date: .omitted, time: .shortened)) · 依据 \(state.sourceSummary ?? "当天事实")"
        }
        return "打开时间线查看每个节点；打开证据详情查看来源。"
    }

    private var reportButtonTitle: String {
        if dailyTaskState?.isLoading == true { return "正在生成…" }
        if dailyReport != nil { return "重新生成日报" }
        if !ai.isConfigured { return "连接模型后生成 AI 日报" }
        return isSelectedDateToday ? "生成今日日报" : "生成\(selectedDateLabel)日报"
    }

    var body: some View {
        let s = makeSnapshot()
        return RiverPage {
            reportHeader.riverAppear(index: 0)
            glanceHero(s).riverAppear(index: 1)
            dayBrief(s).riverAppear(index: 2)
            insightRow(s).riverAppear(index: 3)
            evidenceInbox(s).riverAppear(index: 4)
        }
        .task(id: dateKey) {
            ai.restoreAnalysisResults(startDate: dateKey, endDate: dateKey)
        }
        .onChange(of: dateKey) { _, _ in
            reportError = nil
            isBriefExpanded = false
        }
    }

    // MARK: Header

    private var reportHeader: some View {
        PageHeader(
            pageTitle,
            context: isSelectedDateToday ? "你今天实际把时间花在哪里" : "你在\(selectedDateLabel)实际把时间花在哪里",
            badge: isSelectedDateToday ? "今天" : nil,
            emphasis: true
        ) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Button("询问这一天") { onOpenAsk("这一天做了什么？") }
                    .primaryCTA()
                Button("写日记", action: onOpenJournal)
                    .secondaryCTA()
                Button("写一句", action: onShowCapture)
                    .secondaryCTA()
            }
        }
    }

    // MARK: Glance hero

    /// The ten-second read of the day: four totals and the whole day in one band.
    /// Carries the page's accent wash so the eye lands here first.
    private func glanceHero(_ s: Snapshot) -> some View {
        RiverPanel(padding: AppSpacing.panelPadding, tint: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.lg)) {
                HStack(alignment: .top, spacing: 0) {
                    TodayHeroStat(
                        title: "记录总时长",
                        value: hasRecordedTime(s) ? ActivityFormatter.time(s.timeline.totalDuration) : "—",
                        caption: hasRecordedTime(s)
                            ? "\(s.timeline.sessions.count) 段实时片段 · \(s.captures.count) 条快记"
                            : "\(dayName)还没有记录的时间段",
                        valueFont: AppTypography.metricDisplay()
                    )
                    TodayStatDivider()
                    TodayHeroStat(
                        title: "专注时长",
                        value: hasRecordedTime(s) ? ActivityFormatter.time(s.stats.focusTotal) : "—",
                        caption: focusShareText(s)
                    )
                    TodayStatDivider()
                    TodayHeroStat(
                        title: "最长连续",
                        value: s.stats.longestSession.map { ActivityFormatter.time($0.duration) } ?? "—",
                        caption: longestSessionCaption(s)
                    )
                    TodayStatDivider()
                    TodayHeroStat(
                        title: "证据质量",
                        value: "\(s.stats.confidence)%",
                        caption: "数据量与来源一致性",
                        progress: Double(s.stats.confidence) / 100
                    )
                }

                RiverDayRibbon(
                    date: selectedDate,
                    items: s.timeline.items,
                    now: isSelectedDateToday ? Date() : nil
                )
            }
        }
    }

    // MARK: Day brief

    private func dayBrief(_ s: Snapshot) -> some View {
        RiverPanel(
            title: isSelectedDateToday ? "今天发生了什么" : "\(selectedDateLabel)发生了什么",
            systemImage: "text.alignleft",
            accent: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                HStack(alignment: .top, spacing: density.spacing(AppSpacing.md)) {
                    VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                        if dailyReport == nil && !isBriefExpanded {
                            Text(s.localReport.headline)
                                .font(AppTypography.sectionTitle())
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(s.localReport.highlights, id: \.self) { highlight in
                                HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                                    Circle().fill(AppTheme.accent).frame(width: 5, height: 5)
                                    Text(highlight)
                                        .font(AppTypography.secondary())
                                        .foregroundStyle(Color.secondaryInk)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        } else {
                            Text(dailyReport ?? s.localReport.overview)
                                .font(AppTypography.primary())
                                .foregroundStyle(Color.ink)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: density.spacing(AppSpacing.sm))
                    StatusBadge(
                        dailyReport == nil ? s.localReport.kind.title : "AI 摘要",
                        tone: dailyReport == nil ? .neutral : .positive
                    )
                }

                Text(dailyReport == nil ? s.localReport.sourceLine : dailyReportSource)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Button {
                        if ai.isConfigured {
                            Task { await generateDailyReport() }
                        } else {
                            onOpenSettings()
                        }
                    } label: {
                        Label(reportButtonTitle, systemImage: dailyReport == nil ? "sparkles" : "arrow.clockwise")
                    }
                    .smallAction()
                    .disabled(dailyTaskState?.isLoading == true)

                    Button(isBriefExpanded ? "收起" : "展开完整摘要") {
                        isBriefExpanded.toggle()
                    }
                    .linkAction()
                    .font(AppTypography.secondary())

                    if let reportError {
                        Text(reportError)
                            .font(AppTypography.metadata())
                            .foregroundStyle(AppTheme.warning)
                            .lineLimit(1)
                    }
                }

                SettingsFootnote(text: "质量估算参考数据量、实时片段和来源一致性，不代表摘要正确率。")
            }
        }
    }

    @MainActor
    private func generateDailyReport() async {
        guard dailyTaskState?.isLoading != true else { return }
        reportError = nil
        let dayEntries = store.entries.filter { $0.date == dateKey }
        let sessions = activity.liveSessions(for: selectedDate)
        let success = await ai.runAnalysisDaily(
            entries: dayEntries,
            sessions: sessions,
            captures: captures,
            archiveStartDate: dateKey,
            archiveEndDate: dateKey,
            sourceSummary: "Today · \(sessions.count) 段实时片段 · \(captures.count) 条快记"
        )
        if !success {
            reportError = ai.state(for: .analysisDaily)?.error ?? "日报生成失败，请稍后重试。"
        }
    }

    // MARK: Insight row

    /// Time split on the left; the day's goal and remaining facts on the right.
    private func insightRow(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: density.spacing(AppSpacing.panelGap)) {
            timeBreakdown(s)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: density.spacing(AppSpacing.panelGap)) {
                goalPanel
                factsPanel(s)
            }
            .frame(width: AppLayout.todayAsideWidth)
        }
    }

    private func timeBreakdown(_ s: Snapshot) -> some View {
        RiverPanel(
            title: "时间分布",
            systemImage: "chart.bar",
            detail: "专注 \(ActivityFormatter.time(workDuration(s)))",
            accent: AppTheme.accent
        ) {
            if categorySlices(s).isEmpty {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(Color.tertiaryInk)
                    Text("\(dayName)还没有可分类的时间记录。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                }
            } else {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                    ForEach(categorySlices(s)) { slice in
                        TodayCategoryBar(
                            name: slice.name,
                            durationText: slice.durationText,
                            tint: slice.tint,
                            fraction: slice.fraction
                        )
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Button("打开时间线查看每个节点", action: onOpenTimeline)
                            .linkAction()
                            .font(AppTypography.secondary())
                        Spacer(minLength: density.spacing(AppSpacing.sm))
                        Text("管道汇总 \(s.stats.pipelineTotal > 0 ? ActivityFormatter.time(s.stats.pipelineTotal) : "未知")")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    .padding(.top, density.spacing(2))
                }
            }
        }
    }

    private var goalPanel: some View {
        RiverPanel(padding: AppSpacing.md) {
            DailyGoalControl(store: store, date: selectedDate)
        }
    }

    private func factsPanel(_ s: Snapshot) -> some View {
        RiverPanel(title: "更多事实", systemImage: "list.bullet", accent: AppTheme.neutral) {
            VStack(spacing: 0) {
                RiverValueRow(
                    title: "健康",
                    value: s.entry.health == nil ? "未知" : "部分",
                    detail: healthSummary(s)
                )
                RiverValueRow(
                    title: "娱乐与中断",
                    value: "事实",
                    detail: entertainmentDuration(s) > 0
                        ? "视频/娱乐 \(ActivityFormatter.time(entertainmentDuration(s)))"
                        : "\(dayName)没有可识别的娱乐片段"
                )
                RiverValueRow(
                    title: "足迹",
                    value: "未知",
                    detail: "连接位置来源后显示去过哪里、停留多久。",
                    showsDivider: false
                )
            }
        }
    }

    // MARK: Review queue

    private func evidenceInbox(_ s: Snapshot) -> some View {
        let items = Array(s.timeline.items.filter { item in
            item.annotation?.isReviewed != true && (item.kind == .gap || item.sessions.contains { session in
                let title = session.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return title.isEmpty
            })
        }.prefix(4))

        return RiverPanel(
            title: "需要你确认",
            systemImage: "questionmark.circle",
            detail: items.isEmpty ? "暂无待确认项" : "\(items.count) 条时间片缺少说明",
            accent: AppTheme.warning
        ) {
            if items.isEmpty {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppTheme.ok)
                    Text("\(dayName)暂时没有需要确认的时间片。")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                }
            } else {
                VStack(spacing: density.spacing(AppSpacing.xs)) {
                    ForEach(items) { item in
                        let focusID = "today-review:\(item.id)"
                        TodayReviewRow(item: item, focus: $inspectorSourceFocusID, focusID: focusID) {
                            inspectorSourceFocusID = focusID
                            onSelectTimelineItem(item, focusID)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

/// One row of the time-split list.
private struct TodayCategorySlice: Identifiable {
    let name: String
    let durationText: String
    let tint: Color
    let fraction: CGFloat

    var id: String { name }
}

/// One hero number: label above, value, then the caption that qualifies it.
private struct TodayHeroStat: View {
    @Environment(\.riverDensity) private var density

    let title: String
    let value: String
    let caption: String
    var valueFont: Font = AppTypography.metricSmall()
    /// Optional 0–1 fill shown as a quiet capsule bar under the value.
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(4)) {
            Text(title)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.secondaryInk)
            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let progress {
                Capsule()
                    .fill(Color.chip)
                    .frame(width: 80, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: 80 * min(max(progress, 0), 1))
                    }
                    .padding(.top, density.spacing(2))
            }
            Text(caption)
                .font(AppTypography.metadata())
                .foregroundStyle(Color.tertiaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Hairline between hero stats.
private struct TodayStatDivider: View {
    var body: some View {
        RiverRule(color: Color.separator)
            .frame(width: 1, height: 46)
            .padding(.horizontal, AppSpacing.lg)
    }
}

/// One category of the day: name and duration on top, one accent bar below.
private struct TodayCategoryBar: View {
    @Environment(\.riverDensity) private var density

    let name: String
    let durationText: String
    let tint: Color
    let fraction: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(5)) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(AppTypography.rowTitle())
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Spacer(minLength: density.spacing(AppSpacing.sm))
                Text(durationText)
                    .font(AppTypography.numeric())
                    .foregroundStyle(Color.secondaryInk)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.editor)
                    if fraction > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(proxy.size.width * fraction, 4))
                    }
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(durationText)")
    }
}

/// A queue row: warning well, title, timestamp, and a hover lift.
private struct TodayReviewRow: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: ActivityTimelineItem
    let focus: FocusState<String?>.Binding
    let focusID: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: density.spacing(AppSpacing.md)) {
                RiverIconWell(
                    systemImage: item.kind == .gap ? "questionmark.circle" : "ellipsis.circle",
                    tint: AppTheme.warning,
                    size: 28
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(AppTypography.rowTitle())
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text("\(item.start.formatted(date: .omitted, time: .shortened)) · 查看依据或补充说明")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer(minLength: density.spacing(AppSpacing.sm))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? AppTheme.accent : Color.tertiaryInk)
            }
            .padding(.horizontal, density.spacing(AppSpacing.sm))
            .padding(.vertical, density.spacing(9))
            .background(
                isHovered ? Color.chip : .clear,
                in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused(focus, equals: focusID)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isHovered)
    }
}
