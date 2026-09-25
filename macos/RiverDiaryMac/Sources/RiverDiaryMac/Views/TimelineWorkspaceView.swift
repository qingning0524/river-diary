import SwiftUI

/// The timeline workspace: one day, in order, with the evidence behind every
/// node. Its job is to answer "what happened today and when" in one scan, so the
/// page leads with a whole-day overview and then the rows.
struct TimelineWorkspaceView: View {
    @Environment(\.riverDensity) private var density
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
        let filteredItems = filteredTimelineItems(timeline)
        return RiverPage {
            PageHeader("时间线", context: subheadline(timeline)) { quickNoteButton }
                .riverAppear(index: 0)
            dayOverview(timeline)
                .riverAppear(index: 1)
            journalCard
                .riverAppear(index: 2)
            timelineCard(timeline, filtered: filteredItems)
                .frame(minHeight: 380)
                .riverAppear(index: 3)
        }
        .onAppear { openRequestedJournalEditor() }
        .onChange(of: shouldExpandJournalEditor) { _, requested in
            if requested { openRequestedJournalEditor() }
        }
        .onChange(of: selectedDate) { _, _ in
            journalError = nil
            isJournalExpanded = editor.buffer(for: entry).isDirty
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

    private func timelineCard(_ timeline: ActivityTimeline, filtered: [ActivityTimelineItem]) -> some View {
        RiverPanel(
            title: "时间线",
            systemImage: "list.bullet.indent",
            accent: AppTheme.accent,
            trailingText: "\(filtered.count) 个节点",
            padding: AppSpacing.sm
        ) {
            VStack(alignment: .leading, spacing: 0) {
                timelineToolbar(timeline)
                RiverRule()
                if filtered.isEmpty {
                    noMatches(timeline)
                } else {
                    RiverTimelineView(
                        items: filtered,
                        nowSession: nowSession,
                        selectedItemID: selectedItemID,
                        onSelect: selectTimelineItem,
                        onWriteNote: onShowCapture,
                        inspectorSourceFocusID: $inspectorSourceFocusID,
                        isScrollable: false
                    )
                }
            }
        }
    }

    private func selectTimelineItem(_ item: ActivityTimelineItem, focusID: String) {
        selectedItemID = item.id
        onSelectTimelineItem(item, focusID)
    }

    private var hasActiveFilter: Bool {
        timelineCategory != nil || timelineFavoritesOnly || timelineNeedsReviewOnly
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func filteredTimelineItems(_ timeline: ActivityTimeline) -> [ActivityTimelineItem] {
        timeline.items.filter { item in
            if timelineFavoritesOnly { return item.isFavorite && item.matches(query: query, category: nil) }
            if timelineNeedsReviewOnly { return needsReview(item) && item.matches(query: query, category: nil) }
            return item.matches(query: query, category: timelineCategory)
        }
    }

    private func needsReview(_ item: ActivityTimelineItem) -> Bool {
        guard item.annotation?.isReviewed != true else { return false }
        return item.kind == .gap || item.sessions.contains {
            ($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                if timeline.items.contains(where: needsReview) {
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
                : "换一个关键词，或清除筛选查看全部 \(timeline.items.count) 个节点。",
            symbol: timeline.items.isEmpty ? "clock" : "line.3.horizontal.decrease.circle"
        )
        .padding(.vertical, density.spacing(AppSpacing.lg))
    }
}

// MARK: - Day overview

/// Four facts and the shape of the day.
///
/// The ribbon is what makes the page readable without scrolling: a list of rows
/// can say what happened, but only a laid-out day can show where the recorded
/// evidence actually sits and how much of the day holds none.
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
            detail: recordedSpan,
            accent: AppTheme.accent,
            tint: AppTheme.accent
        ) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                HStack(alignment: .top, spacing: 0) {
                    RiverStat(
                        title: "已记录",
                        value: ActivityFormatter.time(timeline.totalDuration),
                        detail: "macOS 实时片段"
                    )
                    RiverStatDivider()
                    RiverStat(
                        title: "实时专注",
                        value: ActivityFormatter.time(timeline.focusDuration),
                        detail: "工作 · 学习 · 创作"
                    )
                    RiverStatDivider()
                    RiverStat(
                        title: "时间节点",
                        value: "\(timeline.items.count)",
                        detail: "含空档与快记"
                    )
                    RiverStatDivider()
                    RiverStat(
                        title: "日记",
                        value: hasWriting ? "已写" : "—",
                        detail: "本机加密保存"
                    )
                }

                RiverRule()

                RiverDayRibbon(date: date, items: timeline.items, now: isToday ? Date() : nil)

                SettingsFootnote(text: coverageNote)
            }
        }
    }

    /// Reads as the panel's trailing metadata: the recorded span, not the clock.
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
