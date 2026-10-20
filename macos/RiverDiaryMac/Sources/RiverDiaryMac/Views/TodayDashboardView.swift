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
    var onOpenTimelineItem: (String) -> Void
    var onOpenJournal: () -> Void
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onShowCapture: () -> Void
    var onOpenAsk: (String) -> Void
    var onOpenFootprints: () -> Void
    var onOpenHealth: () -> Void = {}
    var onOpenSettings: () -> Void
    var onStartTracking: () -> Void
    /// 习惯回顾入口：只在确有问题包时出现一条简洁入口。
    var habitReviewPendingCount: Int = 0
    var onOpenHabitReview: () -> Void = {}
    /// 宽窗口有常驻右侧队列，窄窗口把同一队列留在主列底部。
    var showsEmbeddedReviewQueue: Bool = true
    var excludedConfirmationTargetIDs: Set<String> = []
    /// 足迹一行的真实状态（与数据源页同一真相）；缺省保持旧行为。
    var locationStatusState: SourceHealthState? = nil
    var locationStatusDetail: String? = nil

    @State private var showsDayDetails = false
    @State private var reportError: String?
    @State private var isBriefExpanded = false
    @State private var showsCorrectionSheet = false
    @State private var correctionItemID = ""
    @State private var correctionDraft = ""
    @State private var correctionSaved = false

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
        let share = s.stats.focusTotal / s.timeline.totalDuration * 100
        if share > 0, share < 1 { return "占全部记录不足 1%" }
        return "占全部记录 \(Int(share.rounded()))%"
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
        guard !answer.hasPrefix(EvidenceReference.unverifiedAnswerPrefix) else { return nil }
        return EvidenceReference.displayText(from: answer)
    }

    private var dailyJudgment: String? {
        guard let answer = dailyTaskState?.answer, !answer.hasPrefix(EvidenceReference.unverifiedAnswerPrefix) else { return nil }
        let headline = AnalysisDigestParser.extract(from: answer).digest.headline
            .replacingOccurrences(of: #"^\**概览\**\s*[:：]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return headline.isEmpty ? nil : headline
    }

    private func annotatedPlaces(_ snapshot: Snapshot) -> [String] {
        let manualPlaces = snapshot.timeline.items.compactMap { item -> String? in
            let place = item.annotation?.normalized.placeName ?? ""
            return place.isEmpty ? nil : place
        }
        let citedPlaces = EvidenceReference.extract(from: dailyTaskState?.answer ?? "").compactMap { reference -> String? in
            guard let parsed = EvidenceReference.parse(reference), parsed.kind == .location,
                  let id = UUID(uuidString: parsed.value) else { return nil }
            return ai.locationEvidenceTitle(id: id, dayKey: dateKey)
        }
        return Array(Set(manualPlaces + citedPlaces)).sorted()
    }

    private var recordedTodayDuration: TimeInterval {
        activity.liveSessions(for: Date()).reduce(0) {
            $0 + max($1.duration, $1.end.timeIntervalSince($1.start))
        }
    }

    private var recordingStatusDetail: String {
        let appLine: String?
        if let active = activity.activeSession {
            appLine = "\(active.appName) · 已持续 \(ActivityFormatter.time(Date().timeIntervalSince(active.start)))"
        } else {
            appLine = nil
        }
        let saveLine = activity.lastSavedAt.map { "上次保存 \($0.formatted(date: .omitted, time: .shortened))" }
        return ([appLine, "今日已记录 \(ActivityFormatter.time(recordedTodayDuration))", saveLine]
            .compactMap { $0 }).joined(separator: " · ")
    }

    /// Option A: a compact, date-adjacent state label, not another dashboard card.
    @ViewBuilder
    private var recordingStatusControl: some View {
        if activity.isTracking && !activity.isCurrentlyPaused {
            HStack(spacing: density.spacing(AppSpacing.xs)) {
                Circle()
                    .fill(AppTheme.recording)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text("正在记录")
                    .font(AppTypography.micro().weight(.semibold))
                    .foregroundStyle(Color.ink)
            }
            .padding(.horizontal, density.spacing(AppSpacing.sm))
            .padding(.vertical, density.spacing(4))
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.border, lineWidth: 1))
            .help(recordingStatusDetail)
            .accessibilityLabel("正在记录。\(recordingStatusDetail)")
        } else {
            HStack(spacing: density.spacing(AppSpacing.xs)) {
                StatusBadge(activity.isCurrentlyPaused ? "按计划暂停" : "已暂停", tone: .neutral)
                if !activity.isTracking {
                    Button("开始记录", action: onStartTracking)
                        .smallAction()
                }
            }
            .accessibilityElement(children: .contain)
        }
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
            modernHeading
            if showsEmbeddedReviewQueue && habitReviewPendingCount > 0 { habitReviewEntry }
            modernBrief(s)
            modernMetrics(s)
            modernMoments(s)
            DisclosureGroup("更多当天信息", isExpanded: $showsDayDetails) {
                VStack(spacing: AppSpacing.panelGap) {
                    glanceHero(s)
                    timeBreakdown(s)
                    goalPanel
                    factsPanel(s)
                }.padding(.top, 16)
            }
            .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
            .padding(.top, 8)
            if showsEmbeddedReviewQueue {
                evidenceInbox(s)
            }
            VStack(spacing: 8) {
                Text("日子有迹可循，生活慢慢成河。")
                    .font(AppTypography.quietQuote()).tracking(2)
                Text("ONE ORDINARY DAY AT A TIME").font(AppTypography.micro()).tracking(2)
            }
            .foregroundStyle(Color.tertiaryInk).frame(maxWidth: .infinity).padding(.vertical, 28)
        }
        .task(id: dateKey) {
            ai.restoreAnalysisResults(startDate: dateKey, endDate: dateKey)
            if ingestion.enabled, ai.hasVerifiedConnection, ai.state(for: .analysisDaily)?.answer == nil {
                await generateDailyReport()
            }
        }
        .onChange(of: dateKey) { _, _ in
            reportError = nil
            isBriefExpanded = false
            correctionSaved = false
        }
        .sheet(isPresented: $showsCorrectionSheet) {
            correctionSheet(s)
        }
    }

    private var modernHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selectedDate.formatted(.dateTime.year().month().day().weekday(.wide)))
                .font(AppTypography.micro()).tracking(2).foregroundStyle(Color.secondaryInk)
            (Text(isSelectedDateToday ? "让今天，" : "回看这一天，").foregroundColor(Color.ink)
             + Text("慢慢清晰。").foregroundColor(Color.secondaryInk).fontWeight(.light))
                .font(AppTypography.pageTitleLarge())
            Text("发生过的片刻、写下的心情，都在这里。")
                .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
        }.padding(.bottom, 5)
    }

    private func modernBrief(_ s: Snapshot) -> some View {
        RiverPanel(title: "\(dayName)的轮廓", systemImage: "book", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .top, spacing: 16) {
                    Text(dailyJudgment ?? (s.timeline.recordedNodeCount > 0 ? s.localReport.headline : "这一天，等你慢慢写下。"))
                        .font(AppTypography.briefLead())
                        .foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    StatusBadge(dailyReport == nil ? "本机记录" : "AI 推断", tone: .neutral)
                }
                Text(dailyReport ?? (s.entry.displayOverview.isEmpty
                     ? (s.timeline.recordedNodeCount > 0 ? s.localReport.overview : "写下一点感受，或者从时间线开始。已有记录会在这里慢慢串起这一天。")
                     : s.entry.displayOverview))
                    .font(AppTypography.secondary()).foregroundStyle(Color.secondaryInk)
                    .lineSpacing(5).lineLimit(isBriefExpanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                ZStack {
                    RiverQuietFlow().stroke(AppTheme.accent.opacity(0.65), lineWidth: 1.1)
                    RiverQuietFlow().stroke(AppTheme.accent.opacity(0.23), lineWidth: 1).offset(y: 10)
                }.frame(height: 28).padding(.horizontal, -23).accessibilityHidden(true)
                HStack(spacing: 12) {
                    Text(dailyReport == nil ? s.localReport.sourceLine : "AI 解释 · 可以回到原始依据")
                        .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                    Spacer(minLength: 0)
                    Button("与 River 聊聊") { onOpenAsk("这一天做了什么？") }.linkAction()
                }
                if dailyReport != nil {
                    dailyEvidenceLinks(s)
                }
                HStack(spacing: 14) {
                    Button(reportButtonTitle) {
                        if ai.isConfigured { Task { await generateDailyReport() } }
                        else { onOpenSettings() }
                    }.smallAction().disabled(dailyTaskState?.isLoading == true)
                    if dailyReport != nil {
                        Button(isBriefExpanded ? "收起" : "阅读全文") { isBriefExpanded.toggle() }.linkAction()
                        Button("改一改") { openCorrection(for: s) }.linkAction()
                    }
                }
                if let reportError {
                    Text(reportError).font(AppTypography.metadata()).foregroundStyle(AppTheme.warning)
                }
            }
        }
    }

    private func modernMetrics(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 20) {
            RiverSoftMetric(
                title: "学习与创作",
                value: hasRecordedTime(s) ? ActivityFormatter.time(s.stats.focusTotal) : "—",
                detail: hasRecordedTime(s) ? focusShareText(s) : "还没有可计的活动时段",
                symbol: "clock", tint: Color(hex: "#8C62D9"), action: onOpenTimeline
            )
            RiverSoftMetric(
                title: isSelectedDateToday ? "今日步数" : "当天步数",
                value: s.entry.health?.steps.map { $0.formatted() } ?? "—",
                detail: s.entry.health?.steps == nil ? "等待 iPhone 健康摘要" : "来自已同步的健康摘要",
                symbol: "figure.walk", tint: AppTheme.ok, action: onOpenHealth
            )
            RiverSoftMetric(
                title: "生活片刻", value: String(s.timeline.recordedNodeCount),
                detail: "\(s.timeline.sessions.count) 段活动 · \(s.captures.count) 条快记",
                symbol: "archivebox", tint: AppTheme.warning, action: onOpenTimeline
            )
        }
    }

    private func modernMoments(_ s: Snapshot) -> some View {
        let items = Array(s.timeline.items.filter { $0.kind != .gap }.sorted { $0.start > $1.start }.prefix(4))
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dayName)，流经这些片刻").font(AppTypography.sectionTitle()).foregroundStyle(Color.ink)
                    Text("一些小事，串起了这一天").font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                }
                Spacer()
                Button("完整足迹 →", action: onOpenTimeline).linkAction()
            }
            if items.isEmpty {
                EmptyStateView(title: "给这一天留一个开始", message: "已有的活动与手记会按时间出现在这里。", symbol: "book",
                               actionTitle: "写一笔", action: onOpenJournal,
                               secondaryTitle: "查看数据源", secondaryAction: onOpenSettings)
                    .padding(23).riverSoftSurface()
            }
            ForEach(items) { item in
                Button {
                    onSelectTimelineItem(item, "today:\(item.id)")
                } label: {
                    HStack(alignment: .top, spacing: 15) {
                        Text(item.start.formatted(date: .omitted, time: .shortened))
                            .font(AppTypography.micro().monospacedDigit()).foregroundStyle(Color.tertiaryInk)
                            .frame(width: 41, alignment: .leading).padding(.top, 7)
                        Image(systemName: item.kind == .capture ? "square.and.pencil" : "circle.grid.2x2")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.accent)
                            .frame(width: 31, height: 31).riverSoftSurface(radius: 16, compact: true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title).font(AppTypography.rowTitle()).foregroundStyle(Color.ink)
                                .lineLimit(2)
                            Text(item.kind == .capture ? "手动记录" : ActivityFormatter.time(item.duration))
                                .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        StatusBadge(item.needsReview ? "待补充" : "已记录", tone: item.needsReview ? .attention : .positive)
                    }.padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($inspectorSourceFocusID, equals: "today:\(item.id)")
            }
        }.padding(.top, 10)
    }

    // MARK: Habit review entry

    /// 习惯回顾的安静入口：一行说明 + 预计耗时，不使用徽标或庆祝样式。
    private var habitReviewEntry: some View {
        Button(action: onOpenHabitReview) {
            HStack(alignment: .center, spacing: density.spacing(AppSpacing.md)) {
                RiverIconWell(systemImage: "checkmark.bubble", tint: AppTheme.accent, size: 32)
                VStack(alignment: .leading, spacing: density.spacing(2)) {
                    Text("待确认 · 有 \(habitReviewPendingCount) 项等你判断")
                        .font(AppTypography.rowTitle().weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Text("所有日期的时间线、地点与习惯线索")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer(minLength: density.spacing(AppSpacing.sm))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
            }
            .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
            .frame(minHeight: density.spacing(56))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开待确认中心，有 \(habitReviewPendingCount) 项需要你的判断")
    }

    // MARK: Header

    private var reportHeader: some View {
        HStack(alignment: .top, spacing: density.spacing(AppSpacing.md)) {
            VStack(alignment: .leading, spacing: density.spacing(3)) {
                HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                    Text(pageTitle)
                        .font(AppTypography.pageTitleLarge())
                        .foregroundStyle(Color.ink)
                    if isSelectedDateToday {
                        Text("今天")
                            .font(AppTypography.micro().weight(.semibold))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.horizontal, density.spacing(AppSpacing.sm))
                            .padding(.vertical, density.spacing(3))
                            .background(AppTheme.accentSoft, in: Capsule())
                        recordingStatusControl
                    }
                }
                Text("先读懂这一天，再回到每条记录")
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: density.spacing(AppSpacing.md))
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                Button("问问 River") { onOpenAsk("这一天做了什么？") }
                    .primaryCTA()
                Button("写日记", action: onOpenJournal)
                    .secondaryCTA()
                Button("写一句", action: onShowCapture)
                    .secondaryCTA()
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Glance hero

    /// The factual companion to the daily interpretation: recorded time, focus,
    /// places the user named, and the compact day band.
    private func glanceHero(_ s: Snapshot) -> some View {
        RiverPanel(level: .raised, padding: AppSpacing.panelPadding, tint: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.lg)) {
                HStack(alignment: .top, spacing: 0) {
                    TodayHeroStat(
                        title: "专注投入",
                        value: hasRecordedTime(s) ? ActivityFormatter.time(s.stats.focusTotal) : "—",
                        caption: hasRecordedTime(s)
                            ? focusShareText(s)
                            : "暂时没有可计的片段",
                        valueFont: AppTypography.metricDisplay()
                    )
                    TodayStatDivider()
                    TodayHeroStat(
                        title: "已记录",
                        value: hasRecordedTime(s) ? ActivityFormatter.time(s.timeline.totalDuration) : "—",
                        caption: "\(s.timeline.sessions.count) 段活动 · \(s.captures.count) 条快记"
                    )
                    TodayStatDivider()
                    TodayHeroStat(
                        title: "地点线索",
                        value: annotatedPlaces(s).isEmpty ? "未知" : "\(annotatedPlaces(s).count) 个",
                        caption: annotatedPlaces(s).isEmpty ? "还没有已标注地点" : annotatedPlaces(s).joined(separator: " · ")
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
            title: "AI 的今日判断",
            systemImage: "sparkles",
            accent: AppTheme.accent,
            level: .raised
        ) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                HStack(alignment: .top, spacing: density.spacing(AppSpacing.md)) {
                    VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                        if let dailyReport {
                            Text(dailyJudgment ?? s.localReport.headline)
                                .font(.editorial(25, weight: .regular))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(isBriefExpanded ? dailyReport : String(dailyReport.prefix(260)))
                                .font(AppTypography.primary())
                                .foregroundStyle(Color.secondaryInk)
                                .lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(s.localReport.headline)
                                .font(.editorial(23, weight: .regular))
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(ai.hasVerifiedConnection
                                 ? "我还没有生成对这一天的整体判断。可以结合已记录的活动、时间和可用地点线索，试着概括今天更像工作、学习还是休闲。"
                                 : "连接并验证 AI 模型后，我可以结合活动、时间和已有地点线索，尝试概括今天的生活节奏。")
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: density.spacing(AppSpacing.sm))
                    StatusBadge(
                        dailyReport == nil ? s.localReport.kind.title : "AI 推断",
                        tone: dailyReport == nil ? .neutral : .positive
                    )
                }

                Text(dailyReport == nil ? s.localReport.sourceLine : "AI 对记录的解释 · \(dailyReportSource)")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                    .fixedSize(horizontal: false, vertical: true)

                if dailyReport != nil {
                    dailyMoments(s)
                } else {
                    reportInsights(s.localReport.insights)
                }

                if let conflict = s.stats.conflicts.first {
                    Text("来源差异：\(conflict)")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if dailyReport != nil {
                    dailyEvidenceLinks(s)
                }

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

                    if dailyReport != nil {
                        Button(isBriefExpanded ? "收起" : "展开完整解释") {
                            isBriefExpanded.toggle()
                        }
                        .linkAction()
                        .font(AppTypography.secondary())

                        Button {
                            openCorrection(for: s)
                        } label: {
                            Label("改一改这个判断", systemImage: "pencil")
                        }
                        .secondaryCTA()
                    }

                    if let reportError {
                        Text(reportError)
                            .font(AppTypography.metadata())
                            .foregroundStyle(AppTheme.warning)
                            .lineLimit(1)
                    }
                }

                if correctionSaved {
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Text("已更新这条时间片；长期习惯需在习惯回顾中单独确认。")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                        Button("去习惯回顾", action: onOpenHabitReview)
                            .linkAction()
                            .font(AppTypography.metadata())
                    }
                }

                SettingsFootnote(text: "事实来自可核对记录；工作、学习或休闲是 AI 的推断。未记录的时间仍然未知。")
            }
        }
    }

    private func dailyMoments(_ snapshot: Snapshot) -> some View {
        let moments = snapshot.timeline.items
            .filter { $0.kind == .activity && $0.duration > 0 }
            .sorted { $0.duration > $1.duration }
            .prefix(3)
            .sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            Text("支持这个判断的片段")
                .font(AppTypography.metadata().weight(.medium))
                .foregroundStyle(Color.secondaryInk)
            ForEach(Array(moments)) { item in
                Button {
                    onOpenTimelineItem(item.id)
                } label: {
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Text(item.start.formatted(date: .omitted, time: .shortened))
                            .font(AppTypography.mono())
                            .foregroundStyle(Color.tertiaryInk)
                        Text(momentTitle(for: item))
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                        Spacer(minLength: density.spacing(AppSpacing.xs))
                        Text(ActivityFormatter.time(item.duration))
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看依据：\(item.title)，\(ActivityFormatter.timeRange(item.start, item.end))")
            }
        }
    }

    private func momentTitle(for item: ActivityTimelineItem) -> String {
        let annotated = item.annotation?.normalized.title ?? ""
        return annotated.isEmpty ? item.title : annotated
    }

    private func openCorrection(for snapshot: Snapshot) {
        let candidates = snapshot.timeline.items.filter { $0.kind == .activity && $0.isAnnotatable }
        correctionItemID = candidates.max(by: { $0.duration < $1.duration })?.id ?? ""
        correctionDraft = ""
        showsCorrectionSheet = true
    }

    private func correctionSheet(_ snapshot: Snapshot) -> some View {
        let candidates = snapshot.timeline.items.filter { $0.kind == .activity && $0.isAnnotatable }.sorted { $0.start < $1.start }
        return VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
            Text("纠正今天的理解")
                .font(AppTypography.sheetTitle())
                .foregroundStyle(Color.ink)
            Text("选择最相关的时间片，补充这段实际在做什么。保存后会更新这条时间片并重新理解当天；若要形成长期习惯，还需到习惯回顾中确认。")
                .font(AppTypography.secondary())
                .foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            if candidates.isEmpty {
                Text("今天还没有可标注的活动片段。")
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.tertiaryInk)
            } else {
                Picker("关联片段", selection: $correctionItemID) {
                    ForEach(candidates) { item in
                        Text("\(item.start.formatted(date: .omitted, time: .shortened)) · \(item.title)")
                            .tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                TextField("例如：这是个人项目，不是工作", text: $correctionDraft, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("取消") { showsCorrectionSheet = false }
                    .buttonStyle(.plain)
                Button("保存并重新理解") { saveCorrection(snapshot: snapshot) }
                    .primaryCTA()
                    .disabled(candidates.isEmpty || correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppSpacing.panelPadding)
        .frame(width: 480)
    }

    private func saveCorrection(snapshot: Snapshot) {
        guard let item = snapshot.timeline.items.first(where: { $0.id == correctionItemID }),
              let key = item.annotationKey else { return }
        let correction = correctionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty else { return }
        var annotation = store.timelineAnnotations[key] ?? TimelineAnnotation()
        let correctionNote = "今日理解更正：\(correction)"
        annotation.note = [annotation.note, correctionNote]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        annotation.isReviewed = true
        annotation.reviewedAt = Date()
        do {
            try store.saveTimelineAnnotation(annotation, for: key)
            showsCorrectionSheet = false
            correctionSaved = true
            Task { await generateDailyReport() }
        } catch {
            reportError = "纠正未能保存：\(UserFacingError.message(for: error))"
        }
    }

    private func reportInsights(_ insights: [TimelineAnalysisInsight]) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            ForEach(insights) { insight in
                Button {
                    onOpenTimelineItem(insight.itemID)
                } label: {
                    HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                        Circle()
                            .fill(insight.kind == .needsReview ? AppTheme.warning : AppTheme.accent)
                            .frame(width: 5, height: 5)
                            .padding(.top, 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                                Text(insight.timeRange)
                                    .font(AppTypography.mono())
                                    .foregroundStyle(Color.tertiaryInk)
                                Text(insight.title)
                                    .font(AppTypography.secondary().weight(.medium))
                                    .foregroundStyle(Color.ink)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(insight.kind.label)
                                    .font(AppTypography.micro())
                                    .foregroundStyle(Color.secondaryInk)
                                    .fixedSize()
                            }
                            if !insight.detail.isEmpty {
                                Text(insight.detail)
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.secondaryInk)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.tertiaryInk)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(insight.kind.label)，\(insight.timeRange)，\(insight.title)，查看依据")
                .help("打开时间线中的依据")
            }
        }
    }

    @ViewBuilder
    private func dailyEvidenceLinks(_ snapshot: Snapshot) -> some View {
        let targets = dailyEvidenceTargets(in: snapshot)
        if !targets.isEmpty {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                Text("AI 引用 \(targets.count) 条可核对记录")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                ChipFlow(spacing: AppSpacing.xs) {
                    ForEach(targets) { target in
                        FilterChip(title: target.title, isSelected: false) {
                            if let itemID = target.itemID {
                                onOpenTimelineItem(itemID)
                            } else if target.opensFootprints {
                                onOpenFootprints()
                            } else {
                                onOpenJournal()
                            }
                        }
                    }
                }
            }
        }
    }

    private func dailyEvidenceTargets(in snapshot: Snapshot) -> [DailyEvidenceTarget] {
        let refs = Array(Set(EvidenceReference.extract(from: dailyTaskState?.answer ?? ""))).sorted().prefix(6)
        let browserVisits = AppDatabase.shared.chromeVisits(for: dateKey)
        return refs.compactMap { reference in
            guard let parsed = EvidenceReference.parse(reference) else { return nil }
            switch parsed.kind {
            case .raw:
                guard let id = UUID(uuidString: parsed.value),
                      let item = snapshot.timeline.items.first(where: { $0.sessions.contains(where: { $0.id == id }) }) else { return nil }
                return DailyEvidenceTarget(
                    id: reference,
                    title: "活动 · \(item.start.formatted(date: .omitted, time: .shortened))",
                    itemID: item.id
                )
            case .capture:
                guard let id = UUID(uuidString: parsed.value),
                      let item = snapshot.timeline.items.first(where: { $0.capture?.id == id }) else { return nil }
                return DailyEvidenceTarget(
                    id: reference,
                    title: "快记 · \(item.start.formatted(date: .omitted, time: .shortened))",
                    itemID: item.id
                )
            case .browser:
                guard let id = UUID(uuidString: parsed.value),
                      let visit = browserVisits.first(where: { $0.evidenceID == id }) else { return nil }
                return DailyEvidenceTarget(
                    id: reference,
                    title: "Chrome · \(visit.title.isEmpty ? visit.domain : visit.title)",
                    itemID: nil,
                    opensFootprints: true
                )
            case .location:
                guard let id = UUID(uuidString: parsed.value),
                      let title = ai.locationEvidenceTitle(id: id, dayKey: dateKey) else { return nil }
                return DailyEvidenceTarget(
                    id: reference,
                    title: title,
                    itemID: nil,
                    opensFootprints: true
                )
            case .diary:
                return DailyEvidenceTarget(id: reference, title: "日记 · \(parsed.value)", itemID: nil)
            case .health, .episode:
                return nil
            }
        }
    }

    @MainActor
    private func generateDailyReport() async {
        guard dailyTaskState?.isLoading != true else { return }
        reportError = nil
        let dayEntries = store.entries.filter { $0.date == dateKey }
        let sessions = ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: captures,
            annotations: store.timelineAnnotations
        ).sessions
        let success = await ai.runAnalysisDaily(
            entries: dayEntries,
            sessions: sessions,
            captures: captures,
            browserVisits: AppDatabase.shared.chromeVisits(for: dateKey),
            annotations: store.timelineAnnotations,
            archiveStartDate: dateKey,
            archiveEndDate: dateKey,
            sourceSummary: "Today · \(sessions.count) 段实时片段 · \(captures.count) 条快记"
        )
        if !success {
            reportError = ai.state(for: .analysisDaily)?.error ?? "日报生成失败，请稍后重试。"
        } else if ai.state(for: .analysisDaily)?.answer?.hasPrefix(EvidenceReference.unverifiedAnswerPrefix) == true {
            reportError = "AI 总结没有提供可核对的证据；请先查看本地事实重点。"
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
                    value: locationStatusState?.label ?? "未知",
                    detail: locationStatusDetail ?? "连接位置来源后显示去过哪里、停留多久。",
                    showsDivider: false
                )
            }
        }
    }

    // MARK: Review queue

    private func evidenceInbox(_ s: Snapshot) -> some View {
        let digest = ai.storedTimelineDigest(for: dateKey)
        let currentFingerprint = ai.currentTimelineSourceFingerprint(
            day: selectedDate,
            entries: [s.entry],
            sessions: s.timeline.sessions,
            captures: s.captures,
            browserVisits: AppDatabase.shared.chromeVisits(for: dateKey),
            annotations: store.timelineAnnotations
        )
        let clarifications = Dictionary(
            (digest?.sourceFingerprint == currentFingerprint ? digest?.clarifications ?? [] : [])
                .filter { ai.isTimelineClarificationPending(candidateID: $0.candidateID) }
                .map { ($0.candidateID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let items = DayReviewQueue.items(in: s.timeline, clarificationIDs: Set(clarifications.keys),
                                         excluding: excludedConfirmationTargetIDs)

        return Group {
            if !items.isEmpty {
                RiverPanel(title: "当天还需补充的线索", systemImage: "questionmark.circle",
                           detail: "\(items.count) 段活动需要补充理解", accent: AppTheme.warning) {
                    VStack(spacing: density.spacing(AppSpacing.xs)) {
                        ForEach(items) { item in
                            let focusID = "today-review:\(item.id)"
                            TodayReviewRow(item: item, clarification: clarifications[item.id],
                                           focus: $inspectorSourceFocusID, focusID: focusID) {
                                inspectorSourceFocusID = focusID
                                onSelectTimelineItem(item, focusID)
                            }
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

private struct DailyEvidenceTarget: Identifiable {
    let id: String
    let title: String
    let itemID: String?
    var opensFootprints = false
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
    var clarification: TimelineDigestClarification?
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
                    Text("\(clarification?.opening ?? item.needsReviewReason ?? "待确认") · \(item.start.formatted(date: .omitted, time: .shortened))")
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
