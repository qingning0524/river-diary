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
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    @ObservedObject var editor: JournalEditorStore
    @Binding var shouldExpandJournalEditor: Bool
    @Binding var requestedFocusItemID: String?
    @FocusState.Binding var inspectorSourceFocusID: String?
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onShowCapture: () -> Void
    var onOpenAsk: (String) -> Void
    var onOpenSettings: () -> Void
    var pendingConfirmationTargets: Set<String> = []
    var onOpenPlaces: () -> Void = {}

    @EnvironmentObject private var feedbackCenter: FeedbackCenter

    @State private var showsMoments = true
    @State private var momentScope: FootprintMomentScope = .all
    @State private var showsDayOverview = false
    @State private var selectedItemID: String?
    @State private var pendingFocusItemID: String?
    @State private var pendingFocusID: String?
    @State private var materializeTimelineForFocus = false
    @State private var timelineCategory: String?
    @State private var timelineFavoritesOnly = false
    @State private var timelineNeedsReviewOnly = false
    @State private var query = ""
    @State private var journalError: String?
    @State private var showsDiscardConfirmation = false
    @State private var isJournalExpanded = false
    /// 已展开的碎片带。折叠状态属于页面：切一天、换筛选都不该记住另一天的展开。
    @State private var expandedRunIDs: Set<String> = []
    @State private var showsRawTimeline = false
    @State private var digestDebounceTask: Task<Void, Never>?
    @State private var isDigestStale = false
    /// 时间带拖到哪里，页面就滚到哪一行；`.row(nil)` 表示停下来。用 `Equatable`
    /// 的枚举而不是一个可选 String，是为了让"再点同一条"也能再次触发滚动。
    @State private var scrollTarget: ScrollTarget?
    @State private var pendingFocusRowID: String?
    /// 标题权限的说明关掉之后不再出现（设置里的"问题"清单仍会一直列着它）。
    @AppStorage("timeline.titleNoticeDismissed") private var titleCaptureNoticeDismissed = false

    private enum ScrollTarget: Hashable {
        case row(String)
        case journal
        case timelinePanel
    }

    private var entry: DiaryEntry { store.entry(for: selectedDate) }
    private var captures: [QuickCapture] { store.captures(for: entry) }
    private var dateKey: String { DiaryEntry.dateFormatter.string(from: selectedDate) }
    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var nowSession: ActivitySession? { isToday ? activity.activeSession : nil }

    /// 每次求值只构建一次：日记编辑的每一次击键都会重渲染本页，
    /// 引擎若在多个计算属性里重复运行，一天数百个节点的融合会被放大数倍。
    private func buildTimeline() -> ActivityTimeline {
        ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: captures,
            placeMarkers: activity.locationMarkers(for: selectedDate),
            annotations: store.timelineAnnotations
        )
    }

    var body: some View {
        let timeline = buildTimeline()
        let displayed = displayedItems(timeline)
        return GeometryReader { geometry in
            VStack(spacing: 0) {
                if showsMoments {
                    momentsHeader(timeline)
                    momentsBody(timeline, showsPlacesRail: geometry.size.width >= 1040)
                } else {
                    pinnedHeader(timeline, displayed: displayed)
                    pageBody(timeline, displayed: displayed)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            openRequestedJournalEditor()
            restoreAndRefreshDigest()
            if requestedFocusItemID != nil {
                openRequestedTimelineItem(in: timeline)
            } else {
                materializeTimelineForFocus = false
            }
        }
        .onChange(of: requestedFocusItemID) { _, itemID in
            if itemID != nil { openRequestedTimelineItem(in: timeline) }
        }
        .onChange(of: shouldExpandJournalEditor) { _, requested in
            if requested { openRequestedJournalEditor() }
        }
        .onDisappear {
            // 防抖任务比页面活得久：离开页面就取消，不能在后台再发起付费请求。
            digestDebounceTask?.cancel()
        }
        .onChange(of: selectedDate) { _, _ in
            journalError = nil
            isJournalExpanded = editor.buffer(for: entry).isDirty
            expandedRunIDs = []
            materializeTimelineForFocus = false
            restoreAndRefreshDigest()
        }
        .onChange(of: activity.sessions.count) { _, _ in
            scheduleDigestRefresh()
        }
        .onChange(of: activity.lastSavedAt) { _, _ in
            scheduleDigestRefresh()
        }
        .onChange(of: store.quickCaptures[dateKey]?.count ?? 0) { _, _ in
            scheduleDigestRefresh()
        }
        .onChange(of: store.entry(for: selectedDate).displayOverview) { _, _ in
            scheduleDigestRefresh()
        }
        .onChange(of: store.timelineAnnotations.values.map(\.updatedAt).max()) { _, _ in
            scheduleDigestRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .riverAnalysisRunDidChange)) { _ in
            guard !showsRawTimeline, ai.timelineDigest(for: dateKey) == nil else { return }
            restoreAndRefreshDigest()
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

    // MARK: Sample-style footprints

    private func showMomentCards() {
        digestDebounceTask?.cancel()
        showsMoments = true
    }

    private var momentViewMenu: some View {
        Menu {
            Button("片刻卡片", systemImage: "rectangle.stack", action: showMomentCards)
            Button("AI 整理", systemImage: "sparkles") {
                showsMoments = false
                showsRawTimeline = false
                restoreAndRefreshDigest()
            }
            Button("原始时间线", systemImage: "list.bullet") {
                digestDebounceTask?.cancel()
                showsMoments = false
                showsRawTimeline = true
            }
        } label: {
            Label("片刻卡片", systemImage: "rectangle.stack")
                .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .riverSoftSurface(radius: AppRadius.control, compact: true)
        }.menuStyle(.borderlessButton).fixedSize().help("切换片刻卡片、AI 整理或原始时间线")
    }

    private func visibleMoments(_ timeline: ActivityTimeline) -> [ActivityTimelineItem] {
        FootprintMoments.items(in: timeline, scope: momentScope, query: query,
                              favoritesOnly: timelineFavoritesOnly, pendingOnly: timelineNeedsReviewOnly,
                              pendingTargets: pendingConfirmationTargets)
    }

    private func momentsHeader(_ timeline: ActivityTimeline) -> some View {
        let items = visibleMoments(timeline)
        return RiverHeaderBand(spacing: 16) {
            HStack {
                Text("把时间线拉开，看见这一天是怎样度过的。")
                    .font(AppTypography.secondary()).foregroundStyle(Color.secondaryInk)
                Spacer(minLength: 12)
                momentViewMenu
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    momentScopePicker.fixedSize()
                    Spacer(minLength: 8)
                    momentSearch.frame(width: 230)
                    momentExtraFilters
                }
                VStack(alignment: .leading, spacing: 12) {
                    momentScopePicker
                    HStack(spacing: 12) { momentSearch; momentExtraFilters }
                }
            }
            Text("\(items.count) 个片刻 · 按时间倒序" + (timelineFavoritesOnly ? " · 仅收藏" : "") + (timelineNeedsReviewOnly ? " · 仅待确认" : ""))
                .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
        }
    }

    private var momentScopePicker: some View {
        RiverSegmentedPicker(title: "按记录类型筛选", selection: $momentScope,
                             options: FootprintMomentScope.allCases, label: { $0.title })
    }

    private var momentSearch: some View {
        RiverSearchField(placeholder: "搜索片刻、文字或应用…", text: $query)
    }

    private var momentExtraFilters: some View {
        Menu {
            Toggle("只看收藏", isOn: $timelineFavoritesOnly)
            Toggle("只看待确认", isOn: $timelineNeedsReviewOnly)
            Divider()
            Button("清除全部筛选") {
                momentScope = .all
                clearFilters()
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13)).foregroundStyle(AppTheme.accent)
                .frame(width: 28, height: 30)
        }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("更多片刻筛选")
    }

    private func momentsBody(_ timeline: ActivityTimeline, showsPlacesRail: Bool) -> some View {
        let items = visibleMoments(timeline)
        let stops = FootprintMoments.places(in: timeline)
        return HStack(alignment: .top, spacing: 0) {
            RiverPageBody(spacing: 22, topPadding: 8, lazy: false, scrollContent: { proxy in
                LazyVStack(alignment: .leading, spacing: 22) {
                if isJournalExpanded || editor.buffer(for: entry).isDirty {
                    journalCard.id(ScrollTarget.journal)
                }
                HStack(spacing: 14) {
                    Text(selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                        .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                    RiverRule()
                }
                if items.isEmpty {
                    EmptyStateView(
                        title: momentScope == .movement ? "还没有标为运动的片刻" : "没有符合条件的片刻",
                        message: timeline.recordedNodeCount == 0
                            ? "当天已有的活动、地点与快记会出现在这里。你也可以先写下一句。"
                            : momentScope == .movement ? "明确分类为运动的记录、活动标注或快记标签会显示在这里。" : "换个关键词或清除筛选，看看这一天的其他记录。",
                        symbol: momentScope == .movement ? "figure.walk" : "rectangle.stack",
                        actionTitle: timeline.recordedNodeCount == 0 ? "写一句" : "清除筛选",
                        action: {
                            if timeline.recordedNodeCount == 0 { onShowCapture() }
                            else { momentScope = .all; clearFilters() }
                        }
                    ).padding(23).frame(maxWidth: .infinity, alignment: .leading).riverSoftSurface()
                }
                ForEach(items) { item in
                    let focusID = "moment:\(item.id)"
                    FootprintMomentCard(item: item,
                                        pending: FootprintMoments.isPending(item, targets: pendingConfirmationTargets),
                                        selected: selectedItemID == item.id) {
                        selectTimelineItem(item, focusID: focusID)
                    }
                    .focused($inspectorSourceFocusID, equals: focusID)
                    .id(item.id)
                }
                retrospectiveCapturesCard(timeline)
                if !showsPlacesRail {
                    DisclosureGroup("当天地点 · \(stops.count) 条记录") {
                        FootprintPlacesOverview(stops: stops,
                                                onSelect: { selectTimelineItem($0, focusID: "moment-place:\($0.id)") },
                                                onOpenPlaces: onOpenPlaces).padding(.top, 12)
                    }.font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                }
                }
                .onChange(of: scrollTarget) { _, target in
                    guard target == .journal else { return }
                    proxy.scrollTo(ScrollTarget.journal, anchor: .top)
                    scrollTarget = nil
                }
            })
            if showsPlacesRail {
                ScrollView {
                    FootprintPlacesOverview(stops: stops,
                                            onSelect: { selectTimelineItem($0, focusID: "moment-place:\($0.id)") },
                                            onOpenPlaces: onOpenPlaces)
                        .padding(.top, 8).padding(.bottom, 30)
                }
                .riverScrollIndicators().frame(width: 260).padding(.trailing, AppSpacing.page)
            }
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
            PageHeader("生活有迹，回头可见。", context: subheadline(timeline)) { quickNoteButton }
                .riverAppear(index: 0)
            RiverDayRibbon(
                date: selectedDate,
                items: timeline.items,
                now: isToday ? Date() : nil,
                onScrub: { moment in scrub(to: moment, timeline: timeline, displayed: displayed, commit: false) },
                onScrubCommit: { moment in scrub(to: moment, timeline: timeline, displayed: displayed, commit: true) },
                composedWorkItemIDs: composedWorkItemIDs(timeline)
            )
            .riverAppear(index: 1)
        }
    }

    /// 组合工作带的成员 id：日带把它们画成普通活动的高度与浓度。
    /// 碎片带的成员与 `timeline.items` 是同一批节点（折叠只发生在展示层），id 直接对得上。
    private func composedWorkItemIDs(_ timeline: ActivityTimeline) -> Set<String> {
        var ids: Set<String> = []
        for run in timeline.foldedItems where run.isFragmentRun {
            if FragmentRunShape.classify(run).isComposedWork {
                ids.formUnion(run.fragments.map(\.id))
            }
        }
        return ids
    }

    private func pageBody(_ timeline: ActivityTimeline, displayed: [ActivityTimelineItem]) -> some View {
        RiverPageBody(lazy: false, scrollContent: { proxy in
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                DisclosureGroup(
                    "已记录 \(ActivityFormatter.time(timeline.totalDuration)) · 专注 \(ActivityFormatter.time(timeline.focusDuration))",
                    isExpanded: $showsDayOverview
                ) { dayOverview(timeline).padding(.top, 12) }
                .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                .riverAppear(index: 0)
                journalCard
                    .id(ScrollTarget.journal)
                    .riverAppear(index: 1)
                timelineCard(timeline, displayed: displayed)
                    .frame(minHeight: 380)
                    .id(ScrollTarget.timelinePanel)
                    .riverAppear(index: 2)
                retrospectiveCapturesCard(timeline)
                    .riverAppear(index: 3)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                switch target {
                case .journal:
                    withAnimation(reduceMotion ? nil : .easeOut(duration: AppMotion.calm)) {
                        proxy.scrollTo(ScrollTarget.journal, anchor: .center)
                    }
                case .row(let rowID):
                    withAnimation(reduceMotion ? nil : .easeOut(duration: AppMotion.calm)) {
                        proxy.scrollTo(rowID, anchor: .center)
                    }
                case .timelinePanel:
                    proxy.scrollTo(ScrollTarget.timelinePanel, anchor: .top)
                    guard let rowID = pendingFocusRowID else {
                        scrollTarget = nil
                        return
                    }
                    Task { @MainActor in
                        await Task.yield()
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        withAnimation(reduceMotion ? nil : .easeOut(duration: AppMotion.calm)) {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                        if let itemID = pendingFocusItemID,
                           let item = timeline.items.first(where: { $0.id == itemID }) {
                            let focusID = pendingFocusID ?? "timeline:\(item.id)"
                            selectedItemID = item.id
                            inspectorSourceFocusID = focusID
                            onSelectTimelineItem(item, focusID)
                        }
                        pendingFocusItemID = nil
                        pendingFocusID = nil
                        pendingFocusRowID = nil
                        scrollTarget = nil
                    }
                    return
                }
                scrollTarget = nil
            }
        })
    }

    @ViewBuilder
    private func retrospectiveCapturesCard(_ timeline: ActivityTimeline) -> some View {
        if !timeline.retrospectiveCaptures.isEmpty {
            RiverPanel(title: "为这一天补记", systemImage: "text.badge.plus", accent: AppTheme.neutral) {
                VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                    Text("以下内容写于其他日期，未指定当天的发生时间。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                    ForEach(timeline.retrospectiveCaptures) { capture in
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                            Text(capture.text)
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("补记于 \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.tertiaryInk)
                        }
                        .padding(.vertical, density.spacing(AppSpacing.xs))
                    }
                }
            }
        }
    }

    private func openRequestedTimelineItem(in timeline: ActivityTimeline) {
        guard let requestedID = requestedFocusItemID else { return }
        showsMoments = false
        showsRawTimeline = true
        guard let item = timeline.items.first(where: { $0.id == requestedID }) else {
            requestedFocusItemID = nil
            return
        }

        materializeTimelineForFocus = true
        timelineCategory = nil
        timelineFavoritesOnly = false
        timelineNeedsReviewOnly = false
        query = ""

        let containingRun = timeline.foldedItems.first { run in
            run.id == item.id || run.fragments.contains(where: { $0.id == item.id })
        }
        let rowID: String
        if let run = containingRun, run.isFragmentRun, run.id != item.id {
            expandedRunIDs.insert(run.id)
            rowID = "fragment-\(item.id)"
        } else {
            rowID = item.id
        }
        let focusID = "timeline:\(item.id)"
        pendingFocusItemID = item.id
        pendingFocusID = focusID
        pendingFocusRowID = rowID
        scrollTarget = .timelinePanel
        requestedFocusItemID = nil
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

    @ViewBuilder
    private var journalCard: some View {
        let buffer = editor.buffer(for: entry)
        if isJournalExpanded || buffer.isDirty {
            expandedJournalCard
        } else {
            Button { isJournalExpanded = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.pencil").font(.system(size: 17)).foregroundStyle(AppTheme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(buffer.text.isEmpty ? "为这一天留几句话" : "这一天的手记")
                            .font(AppTypography.rowTitle().weight(.semibold)).foregroundStyle(Color.ink)
                        Text(buffer.text.isEmpty ? "写下感受，和时间线一起保存。" : buffer.text)
                            .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(buffer.text.isEmpty ? "开始写" : "编辑").font(AppTypography.metadata()).foregroundStyle(AppTheme.accent)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Color.tertiaryInk)
                }.padding(18).riverSoftSurface(radius: AppRadius.row).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(buffer.text.isEmpty ? "写日记" : "编辑日记，\(buffer.text)")
        }
    }

    private var expandedJournalCard: some View {
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
            title: "这一天",
            systemImage: "list.bullet.indent",
            accent: AppTheme.accent,
            trailingText: showsRawTimeline ? "\(timeline.recordedNodeCount) 条原始记录" : nil,
            padding: AppSpacing.sm
        ) {
            VStack(alignment: .leading, spacing: 0) {
                timelineModePicker
                RiverRule()
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
                if showsRawTimeline {
                    timelineToolbar(timeline)
                    if displayed.isEmpty {
                        noMatches(timeline)
                    } else {
                        RiverTimelineView(
                            items: displayed,
                            nowSession: nowSession,
                            selectedItemID: selectedItemID,
                            onSelect: selectTimelineItem,
                            onWriteNote: onShowCapture,
                            inspectorSourceFocusID: $inspectorSourceFocusID,
                            isScrollable: false,
                            materializeAllRows: materializeTimelineForFocus,
                            expandedRunIDs: expandedRunIDs,
                            onToggleRun: toggleRun
                        )
                        if let foldingNote = foldingNote(timeline) {
                            RiverRule()
                            SettingsFootnote(text: foldingNote)
                                .padding(.top, density.spacing(AppSpacing.sm))
                        }
                    }
                } else {
                    TimelineAIDigestView(
                        digest: ai.timelineDigest(for: dateKey),
                        timeline: timeline,
                        isStale: isDigestStale,
                        isGenerating: ai.state(for: .timelineDigest)?.isLoading == true,
                        automaticAnalysisEnabled: ingestion.enabled,
                        hasVerifiedConnection: ai.hasVerifiedConnection,
                        lastUpdated: ai.state(for: .timelineDigest)?.updatedAt,
                        errorMessage: ai.state(for: .timelineDigest)?.error,
                        onSelectItem: { item in selectTimelineItem(item, focusID: "timeline:\(item.id)") },
                        onOpenSettings: onOpenSettings,
                        onOpenJournal: {
                            shouldExpandJournalEditor = true
                            openRequestedJournalEditor()
                        }
                    )
                }
            }
        }
    }

    private var timelineModePicker: some View {
        HStack(spacing: density.spacing(AppSpacing.xs)) {
            FilterChip(title: "片刻卡片", isSelected: false) { showMomentCards() }
            FilterChip(title: "AI 整理", isSelected: !showsRawTimeline) {
                showsRawTimeline = false
                restoreAndRefreshDigest()
            }
            FilterChip(title: "原始记录", isSelected: showsRawTimeline) {
                showsRawTimeline = true
            }
            Spacer(minLength: 0)
            if !showsRawTimeline, ingestion.enabled, ai.hasVerifiedConnection,
               ai.timelineDigest(for: dateKey) == nil,
               ai.state(for: .timelineDigest)?.isLoading != true {
                Text("待自动整理")
                    .font(AppTypography.micro())
                    .foregroundStyle(Color.tertiaryInk)
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .padding(.vertical, density.spacing(AppSpacing.sm))
    }

    private func restoreAndRefreshDigest() {
        let date = selectedDate
        let dayKey = DiaryEntry.dateFormatter.string(from: date)
        ai.restoreAnalysisResults(startDate: dayKey, endDate: dayKey)
        guard !showsMoments, ingestion.enabled, ai.hasVerifiedConnection else { return }
        let dayEntry = store.entry(for: date)
        let sessions = activity.liveSessions(for: date)
        let dayCaptures = store.captures(for: dayEntry)
        let browserVisits = AppDatabase.shared.chromeVisits(for: dayKey)
        let entries = store.entries.filter { $0.date == dayKey }
        let annotations = store.timelineAnnotations
        let existingDigest = ai.timelineDigest(for: dayKey)
        let fingerprint = ai.currentTimelineSourceFingerprint(
            day: date,
            entries: entries,
                sessions: sessions,
                captures: dayCaptures,
                browserVisits: browserVisits,
                annotations: annotations
        )
        isDigestStale = existingDigest.map { $0.sourceFingerprint != fingerprint } ?? false
        let targetDayKey = dayKey
        digestDebounceTask?.cancel()
        digestDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            guard DiaryEntry.dateFormatter.string(from: selectedDate) == targetDayKey else { return }
            let succeeded = await ai.organizeTimeline(
                day: date,
                entries: entries,
                sessions: sessions,
                captures: dayCaptures,
                browserVisits: browserVisits,
                annotations: annotations,
                sourceSummary: "时间线自动整理 · \(sessions.count) 段活动 · \(dayCaptures.count) 条快记"
            )
            if succeeded { isDigestStale = false }
        }
    }

    private func scheduleDigestRefresh() {
        guard !showsMoments, !showsRawTimeline, ingestion.enabled, ai.hasVerifiedConnection else { return }
        digestDebounceTask?.cancel()
        let date = selectedDate
        let dayKey = DiaryEntry.dateFormatter.string(from: date)
        let dayEntry = store.entry(for: date)
        let sessions = activity.liveSessions(for: date)
        let dayCaptures = store.captures(for: dayEntry)
        let browserVisits = AppDatabase.shared.chromeVisits(for: dayKey)
        let entries = store.entries.filter { $0.date == dayKey }
        let annotations = store.timelineAnnotations
        let existingDigest = ai.timelineDigest(for: dayKey)
        let fingerprint = ai.currentTimelineSourceFingerprint(
            day: date,
            entries: entries,
            sessions: sessions,
            captures: dayCaptures,
            browserVisits: browserVisits,
            annotations: annotations
        )
        isDigestStale = existingDigest.map { $0.sourceFingerprint != fingerprint } ?? false
        let targetDayKey = dayKey
        digestDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            // 任务比页面活得久：离开本页或切到别的日期后，这 90 秒的定时器
            // 不能再发起付费请求，也不能改写别的日子的"记录有更新"标记。
            guard DiaryEntry.dateFormatter.string(from: selectedDate) == targetDayKey else { return }
            let succeeded = await ai.organizeTimeline(
                day: date,
                entries: entries,
                sessions: sessions,
                captures: dayCaptures,
                browserVisits: browserVisits,
                annotations: annotations,
                sourceSummary: "活动更新后自动整理 · \(sessions.count) 段活动"
            )
            if succeeded { isDigestStale = false }
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
        let expandsRun = target.expandsRunID
        if let runID = expandsRun { expandedRunIDs.insert(runID) }
        // 碎片带刚展开时成员行尚未被 LazyVStack 物化，同帧 scrollTo 是静默
        // 无效的；且拖拽路径上 scrollTarget 常与上次相等，onChange 不会重发。
        // 与洞察跳转同款处理：先物化整列，再延迟补一次滚动。
        if expandsRun != nil { materializeTimelineForFocus = true }
        if scrollTarget == .row(target.rowID) {
            // 同值再触发：先置 nil 让 onChange 能再次 fires。
            scrollTarget = nil
        }
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
                    metric("短切换", switchMetricValue, switchMetricDetail)
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

    /// "短切换"而不是"碎片"：切屏是中性的，多数短切换是多工具组合工作。
    /// 只有真散的才叫碎片（见 `FragmentRunShape`）。
    private var switchMetricValue: String {
        timeline.fragmentNodeCount > 0 ? "\(timeline.fragmentNodeCount) 段" : "—"
    }

    /// 悬停说明：先说折叠这件事；当天组合工作**严格过半**时才说"多为"——
    /// 恰好一半也说"多为"是不诚实的措辞。
    private var switchMetricDetail: String {
        guard timeline.fragmentNodeCount > 0 else { return "不足 3 分钟的切屏折进碎片带；这一天没有" }
        let runs = timeline.foldedItems.filter(\.isFragmentRun)
        let base = "不足 3 分钟，折进 \(runs.count) 条碎片带"
        let shapes = runs.map(FragmentRunShape.classify)
        if shapes.filter(\.isComposedWork).count * 2 > runs.count {
            return base + "，多为多工具组合工作"
        }
        if shapes.contains(where: \.isWandering) {
            return base + "，部分分散在多个应用之间"
        }
        return base
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
        guard recorded > 0 else {
            return "这一天还没有实时足迹。未记录不等于没有发生，也不按零计算。"
        }
        let unrecorded = max(timeline.dayInterval.duration - recorded, 0)
        return "灰色区间没有实时足迹：这一天有 \(ActivityFormatter.time(unrecorded)) 未被记录，不按零计算。"
    }
}
