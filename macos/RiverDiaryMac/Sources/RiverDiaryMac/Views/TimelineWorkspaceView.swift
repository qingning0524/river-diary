import SwiftUI

/// The timeline workspace: one day, in order, with the evidence behind every
/// node. Its job is to answer "what happened today and when" in one scan, so the
/// page leads with the day's numbers, keeps the shape of the day pinned in the
/// header, and then lays out the rows.
struct TimelineWorkspaceView: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    @Binding var selectedDate: Date
    @ObservedObject var editor: JournalEditorStore
    @Binding var shouldExpandJournalEditor: Bool
    @FocusState.Binding var inspectorSourceFocusID: String?
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onShowCapture: () -> Void
    var onOpenAsk: (String) -> Void
    var onOpenSettings: () -> Void

    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    @State private var selectedItemID: String?
    @State private var timelineCategory: String?
    @State private var timelineFavoritesOnly = false
    @State private var timelineNeedsReviewOnly = false
    @State private var query = ""
    @State private var journalError: String?
    @State private var showsDiscardConfirmation = false
    @State private var isJournalExpanded = false
    /// 已展开的碎片带。折叠状态属于页面：切一天、换筛选都不该记住另一天的展开。
    @State private var expandedRunIDs: Set<String> = []
    /// 时间带拖到哪里，页面就滚到哪一行；`.row(nil)` 表示停下来。用 `Equatable`
    /// 的枚举而不是一个可选 String，是为了让"再点同一条"也能再次触发滚动。
    @State private var scrollTarget: ScrollTarget?
    /// 标题权限的说明关掉之后不再出现（设置里的"问题"清单仍会一直列着它）。
    @AppStorage("timeline.titleNoticeDismissed") private var titleCaptureNoticeDismissed = false

    private enum ScrollTarget: Hashable {
        case row(String)
        case journal
    }

    private var entry: DiaryEntry { store.entry(for: selectedDate) }
    private var captures: [QuickCapture] { store.captures(for: entry) }
    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var nowSession: ActivitySession? { isToday ? activity.activeSession : nil }

    /// 每次求值只构建一次：日记编辑的每一次击键都会重渲染本页，
    /// 引擎若在多个计算属性里重复运行，一天数百个节点的融合会被放大数倍。
    private func buildTimeline() -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: captures,
            annotations: store.timelineAnnotations
        )
    }

    var body: some View {
        let timeline = buildTimeline()
        let displayed = displayedItems(timeline)
        return VStack(spacing: 0) {
            pinnedHeader(timeline, displayed: displayed)
            pageBody(timeline, displayed: displayed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { openRequestedJournalEditor() }
        .onChange(of: shouldExpandJournalEditor) { _, requested in
            if requested { openRequestedJournalEditor() }
        }
        .onChange(of: selectedDate) { _, _ in
            journalError = nil
            isJournalExpanded = editor.buffer(for: entry).isDirty
            expandedRunIDs = []
        }
        .confirmationDialog(
            "丢弃未保存的日记？",
            isPresented: $showsDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("丢弃草稿", role: .destructive) {
                editor.discarded(entry.date)
                journalError = nil
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("尚未保存的文字会被丢弃；已保存的日记不会改变。")
        }
    }

    // MARK: Scaffold

    /// 页头钉住：标题 + 一天的时间带。
    ///
    /// 时间带本来躺在"今天"面板里，滚到第三行就看不见了——而它回答的正是
    /// 列表回答不了的那个问题（"我现在看的这段在一天里的哪里"）。钉住之后它
    /// 同时是一条定位尺：悬停读时刻，拖动跳到那一刻所在的行。
    private func pinnedHeader(_ timeline: ActivityTimeline, displayed: [ActivityTimelineItem]) -> some View {
        RiverHeaderBand {
            PageHeader("时间线", context: subheadline(timeline)) { quickNoteButton }
                .riverAppear(index: 0)
            RiverDayRibbon(
                date: selectedDate,
                items: timeline.items,
                now: isToday ? Date() : nil,
                onScrub: { moment in scrub(to: moment, timeline: timeline, displayed: displayed, commit: false) },
                onScrubCommit: { moment in scrub(to: moment, timeline: timeline, displayed: displayed, commit: true) }
            )
            .riverAppear(index: 1)
        }
    }

    private func pageBody(_ timeline: ActivityTimeline, displayed: [ActivityTimelineItem]) -> some View {
        RiverPageBody(lazy: false) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                    dayOverview(timeline)
                        .riverAppear(index: 0)
                    journalCard
                        .id(ScrollTarget.journal)
                        .riverAppear(index: 1)
                    timelineCard(timeline, displayed: displayed)
                        .frame(minHeight: 380)
                        .riverAppear(index: 2)
                }
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: AppMotion.calm)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollTarget = nil
                }
            }
        }
    }

    // MARK: Day overview

    private func dayOverview(_ timeline: ActivityTimeline) -> some View {
        TimelineDayOverview(
            date: selectedDate,
            isToday: isToday,
            timeline: timeline,
            hasWriting: !entry.displayOverview.isEmpty
        )
    }

    private var quickNoteButton: some View {
        Button(action: onShowCapture) {
            Label("写一句", systemImage: "square.and.pencil")
        }
        .buttonStyle(.plain)
        .smallAction()
        .help("写下一句快记 (⌘N)")
    }

    private func subheadline(_ timeline: ActivityTimeline) -> String {
        let dateText = selectedDate.formatted(.dateTime.month().day())
        if isToday {
            if timeline.totalDuration > 0 {
                return "\(dateText) · 已记录 \(ActivityFormatter.time(timeline.totalDuration))"
            }
            return "\(dateText) · 正在记录，时间线会随着今天展开"
        }
        return "\(dateText) · \(selectedDate.formatted(.dateTime.weekday(.wide)))"
    }

    // MARK: Journal

    private var journalCard: some View {
        let buffer = editor.buffer(for: entry)
        let prompt = isToday
            ? "今天想留下什么？"
            : "\(selectedDate.formatted(.dateTime.month().day()))想留下什么？"

        return RiverPanel(
            title: prompt,
            systemImage: "square.and.pencil",
            detail: buffer.isDirty ? "草稿未保存" : (buffer.text.isEmpty ? nil : "已保存 \(buffer.text.count) 字"),
            accent: buffer.isDirty ? AppTheme.warning : AppTheme.neutral
        ) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                if isJournalExpanded || buffer.isDirty {
                    journalEditorView
                    editorFooter(buffer)
                } else {
                    if buffer.text.isEmpty {
                        Text("这一天还没有手记。写下一点值得回看的内容。")
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.secondaryInk)
                    } else {
                        Text(buffer.text)
                            .font(AppTypography.primary())
                            .foregroundStyle(Color.ink)
                            .lineSpacing(5)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(buffer.text.isEmpty ? "写日记" : "编辑日记") { isJournalExpanded = true }
                        .buttonStyle(.plain)
                        .smallAction()
                }

                if let journalError {
                    Text(journalError)
                        .font(AppTypography.metadata())
                        .foregroundStyle(AppTheme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var journalEditorView: some View {
        ZStack(alignment: .topLeading) {
            if editor.buffer(for: entry).text.isEmpty {
                Text("写下一点值得回看的东西…")
                    .font(AppTypography.primary())
                    .foregroundStyle(Color.tertiaryInk)
                    .padding(density.spacing(AppSpacing.sm))
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(
                get: { editor.buffer(for: entry).text },
                set: { editor.edit(entry, text: $0) }
            ))
            .font(AppTypography.primary())
            .scrollIndicators(.hidden)
            .frame(minHeight: 110, maxHeight: 180)
            .scrollContentBackground(.hidden)
            .padding(density.spacing(AppSpacing.xs))
        }
        .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                .strokeBorder(Color.border, lineWidth: 1)
        )
    }

    private func editorFooter(_ buffer: JournalEditingBuffer) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
                Text("\(buffer.text.count) 字")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                if buffer.isDirty {
                    let status = editor.persistenceStatus[entry.date] ?? "停止输入后自动加密保存"
                    Text(status)
                        .font(AppTypography.metadata())
                        .foregroundStyle(status.contains("失败") ? AppTheme.error : Color.tertiaryInk)
                        .accessibilityLabel(status)
                }
            }
            Spacer(minLength: density.spacing(AppSpacing.sm))
            if buffer.isDirty {
                Button("丢弃草稿") { showsDiscardConfirmation = true }
                    .buttonStyle(.plain)
                    .smallAction()
                Button("保存") { saveJournal() }
                    .primaryCTA()
            } else {
                Button("完成") { isJournalExpanded = false }
                    .buttonStyle(.plain)
                    .smallAction()
            }
        }
    }

    private func openRequestedJournalEditor() {
        guard shouldExpandJournalEditor else { return }
        isJournalExpanded = true
        shouldExpandJournalEditor = false
        // 编辑器在行列表上方，展开之后要能看见它：不滚过去等于什么都没发生。
        scrollTarget = .journal
    }

    private func saveJournal() {
        let buffer = editor.buffer(for: entry)
        do {
            try store.saveWriting(entry: entry, text: buffer.text, mood: buffer.mood)
            editor.saved(entry.date)
            journalError = nil
            feedbackCenter.show(
                isToday ? "已保存今天的记录" : "已保存\(selectedDate.formatted(.dateTime.month().day()))的记录",
                kind: .success
            )
        } catch {
            let message = UserFacingError.message(for: error)
            journalError = message
            feedbackCenter.show("保存失败：\(message)", kind: .error)
        }
    }

    // MARK: Timeline

    private func timelineCard(_ timeline: ActivityTimeline, displayed: [ActivityTimelineItem]) -> some View {
        RiverPanel(
            title: "时间线",
            systemImage: "list.bullet.indent",
            accent: AppTheme.accent,
            trailingText: "\(timeline.recordedNodeCount) 个节点",
            padding: AppSpacing.sm
        ) {
            VStack(alignment: .leading, spacing: 0) {
                timelineToolbar(timeline)
                RiverRule()
                if displayed.isEmpty {
                    noMatches(timeline)
                } else {
                    if let notice = titleCaptureNotice {
                        RiverInlineNotice(
                            systemImage: "text.magnifyingglass",
                            text: notice,
                            tint: AppTheme.warning,
                            actionTitle: "打开权限",
                            action: { activity.requestAccessibility() },
                            onDismiss: { titleCaptureNoticeDismissed = true }
                        )
                        .padding(.top, density.spacing(AppSpacing.sm))
                    }
                    RiverTimelineView(
                        items: displayed,
                        nowSession: nowSession,
                        selectedItemID: selectedItemID,
                        onSelect: selectTimelineItem,
                        onWriteNote: onShowCapture,
                        inspectorSourceFocusID: $inspectorSourceFocusID,
                        isScrollable: false,
                        expandedRunIDs: expandedRunIDs,
                        onToggleRun: toggleRun
                    )
                    if let foldingNote = foldingNote(timeline) {
                        RiverRule()
                        SettingsFootnote(text: foldingNote)
                            .padding(.top, density.spacing(AppSpacing.sm))
                    }
                }
            }
        }
    }

    /// "行数比节点少"必须有个能读到的解释，否则折叠看起来像丢数据。
    private func foldingNote(_ timeline: ActivityTimeline) -> String? {
        let folded = timeline.fragmentNodeCount
        guard folded > 0, !hasActiveFilter else { return nil }
        let runs = timeline.foldedItems.filter(\.isFragmentRun).count
        return "另有 \(folded) 段不足 3 分钟的碎片折进 \(runs) 条碎片带，逐条证据仍在导出、搜索和证据库里。"
    }

    /// 开了标题采集却没有辅助功能权限：证据只能到应用名，而"这一段时间在做什么"
    /// 恰恰是标题回答的。这件事原来只写进设置里的"问题"清单——用户看不到后果，
    /// 只看到一行行"没有记录的时间"。说一次，可以关掉；关掉之后它还留在设置里。
    private var titleCaptureNotice: String? {
        guard activity.capturesTitles, !activity.accessibilityGranted, !titleCaptureNoticeDismissed else { return nil }
        return "窗口标题没有采集到：辅助功能权限未授予。这一天的证据只能记到应用名。"
    }

    private func selectTimelineItem(_ item: ActivityTimelineItem, focusID: String) {
        selectedItemID = item.id
        onSelectTimelineItem(item, focusID)
    }

    private func toggleRun(_ item: ActivityTimelineItem) {
        if expandedRunIDs.contains(item.id) {
            expandedRunIDs.remove(item.id)
        } else {
            expandedRunIDs.insert(item.id)
        }
    }

    /// 把时间带上的一点翻译成页面上的一行。落在折叠的碎片带上时先展开它——
    /// 拖到 14:20 却只看到"12 段碎片"，等于没告诉用户那一刻是什么。
    private func scrub(
        to moment: Date,
        timeline: ActivityTimeline,
        displayed: [ActivityTimelineItem],
        commit: Bool
    ) {
        let rows = TimelineDisplayList.rows(
            items: displayed,
            expandedRunIDs: expandedRunIDs,
            hasNowRow: nowSession != nil
        )
        guard let target = TimelineDisplayList.scrubTarget(for: moment, rows: rows) else { return }
        if let runID = target.expandsRunID { expandedRunIDs.insert(runID) }
        scrollTarget = .row(target.rowID)
        if commit { selectTimelineItem(target.item, focusID: "timeline:\(target.item.id)") }
    }

    private var hasActiveFilter: Bool {
        timelineCategory != nil || timelineFavoritesOnly || timelineNeedsReviewOnly
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 列表默认读**折叠后**的展示列表；一旦有筛选就摊平。
    ///
    /// 一个查询不该命中一条"碎片带"却看不见命中的是哪一段：筛选与搜索永远
    /// 作用在真实节点上，聚合只是无筛选时的阅读方式。
    private func displayedItems(_ timeline: ActivityTimeline) -> [ActivityTimelineItem] {
        guard hasActiveFilter else { return timeline.foldedItems }
        return ActivityTimelineEngine.flattenFragments(timeline.foldedItems).filter(matches)
    }

    private func matches(_ item: ActivityTimelineItem) -> Bool {
        if timelineFavoritesOnly { return item.isFavorite && item.matches(query: query, category: nil) }
        if timelineNeedsReviewOnly { return item.needsReview && item.matches(query: query, category: nil) }
        return item.matches(query: query, category: timelineCategory)
    }

    private func timelineToolbar(_ timeline: ActivityTimeline) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            HStack(spacing: density.spacing(AppSpacing.sm)) {
                RiverSearchField(placeholder: "搜索节点、应用或窗口…", text: $query, symbol: "magnifyingglass")
                    .frame(maxWidth: 280)
                Spacer(minLength: 0)
                if hasActiveFilter {
                    Button("清除筛选", action: clearFilters)
                        .buttonStyle(.plain)
                        .smallAction()
                }
            }

            ChipFlow(spacing: AppSpacing.xs) {
                FilterChip(title: "全部", isSelected: !hasActiveFilter) { clearFilters() }
                ForEach(timeline.categories, id: \.self) { category in
                    FilterChip(title: category, isSelected: timelineCategory == category) {
                        applyCategory(category)
                    }
                }
                if timeline.items.contains(where: \.isFavorite) {
                    FilterChip(title: "收藏", isSelected: timelineFavoritesOnly) {
                        timelineFavoritesOnly.toggle()
                        timelineCategory = nil
                        timelineNeedsReviewOnly = false
                    }
                }
                if timeline.items.contains(where: \.needsReview) {
                    FilterChip(title: "待确认", isSelected: timelineNeedsReviewOnly) {
                        timelineNeedsReviewOnly.toggle()
                        timelineCategory = nil
                        timelineFavoritesOnly = false
                    }
                }
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .padding(.top, density.spacing(AppSpacing.xs))
        .padding(.bottom, density.spacing(AppSpacing.sm))
    }

    private func applyCategory(_ category: String) {
        if timelineCategory == category {
            timelineCategory = nil
        } else {
            timelineCategory = category
            timelineFavoritesOnly = false
            timelineNeedsReviewOnly = false
        }
    }

    private func clearFilters() {
        timelineCategory = nil
        timelineFavoritesOnly = false
        timelineNeedsReviewOnly = false
        query = ""
    }

    /// An empty list must explain itself: "nothing matched" is not the same as
    /// "nothing was recorded".
    private func noMatches(_ timeline: ActivityTimeline) -> some View {
        EmptyStateView(
            title: timeline.items.isEmpty ? "这一天还没有记录。" : "没有符合条件的节点。",
            message: timeline.items.isEmpty
                ? "使用身边的应用后，带来源的事实会在这里出现。"
                : "换一个关键词，或清除筛选查看全部 \(timeline.recordedNodeCount) 个节点。",
            symbol: timeline.items.isEmpty ? "clock" : "line.3.horizontal.decrease.circle"
        )
        .padding(.vertical, density.spacing(AppSpacing.lg))
    }
}

// MARK: - Day overview

/// The day's numbers, in one compact strip.
///
/// 这一块曾经同时装着四个大统计、一天的时间带和一段说明，光它自己就占掉一屏；
/// 时间带搬到页头钉住之后，这里只留下数字本身。四个数字各回答一个问题：
/// 记了多久、其中多少是专注、最长的一段有多长、有多少碎片被折起。
struct TimelineDayOverview: View {
    @Environment(\.riverDensity) private var density

    let date: Date
    let isToday: Bool
    let timeline: ActivityTimeline
    let hasWriting: Bool

    var body: some View {
        RiverPanel(
            title: isToday ? "今天" : date.formatted(.dateTime.month().day()),
            systemImage: "calendar.day.timeline.left",
            detail: panelDetail,
            accent: AppTheme.accent,
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                HStack(alignment: .top, spacing: 0) {
                    metric("已记录", ActivityFormatter.time(timeline.totalDuration), "macOS 实时片段")
                    RiverStatDivider()
                    metric("专注", ActivityFormatter.time(timeline.focusDuration), "工作 · 学习 · 创作")
                    RiverStatDivider()
                    metric(
                        "最长专注",
                        timeline.longestFocusSpan > 0 ? ActivityFormatter.time(timeline.longestFocusSpan) : "—",
                        "单段最长的一次"
                    )
                    RiverStatDivider()
                    metric(
                        "碎片",
                        timeline.fragmentNodeCount > 0 ? "\(timeline.fragmentNodeCount) 段" : "—",
                        "不足 3 分钟，已折进碎片带"
                    )
                }

                SettingsFootnote(text: coverageNote)
            }
        }
    }

    /// 一个数字，一行说明。统计的解释用 `help` 挂在悬停上，不再各占一行——
    /// 四行小字叠起来正好把面板撑高一层，而它们只在第一次看的时候有用。
    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        RiverStat(title: title, value: value, detail: nil, valueFont: AppTypography.metricSmall())
            .help("\(title)：\(detail)")
    }

    /// Reads as the panel's trailing metadata: the recorded span, plus whether the
    /// day has been written. 日记 曾经独占一个大统计位，而它只有一个比特的信息量。
    private var panelDetail: String? {
        var parts: [String] = []
        if let span = recordedSpan { parts.append(span) }
        parts.append(hasWriting ? "已写日记" : "未写日记")
        return parts.joined(separator: " · ")
    }

    /// The recorded span, not the clock.
    private var recordedSpan: String? {
        let recorded = timeline.items.filter { $0.kind != .gap }
        guard let first = recorded.map(\.start).min(), let last = recorded.map(\.end).max() else { return nil }
        return "\(first.formatted(date: .omitted, time: .shortened)) – \(last.formatted(date: .omitted, time: .shortened))"
    }

    /// Most of a day is unknown, and the page should say so rather than let a
    /// half-empty band imply the rest was idle. Unrecorded is never counted as zero.
    private var coverageNote: String {
        let recorded = timeline.sessions.reduce(0.0) { $0 + $1.duration }
        let span = timeline.items
            .filter { $0.kind != .gap }
            .reduce(0.0) { $0 + max($1.duration, $1.end.timeIntervalSince($1.start)) }
        guard span > 0 else {
            return "这一天还没有实时足迹。未记录不等于没有发生，也不按零计算。"
        }
        let unrecorded = max(86_400 - recorded, 0)
        return "灰色区间没有实时足迹：这一天有 \(ActivityFormatter.time(unrecorded)) 未被记录，不按零计算。"
    }
}
