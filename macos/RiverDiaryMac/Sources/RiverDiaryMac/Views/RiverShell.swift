import AppKit
import SwiftUI

// MARK: - New River shell (Personal Memory OS)

struct RiverNavigationShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let label: String

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(key, modifiers: modifiers)
    }
}

enum RiverDestination: String, Hashable, CaseIterable, Identifiable {
    case today
    case timeline
    case dailyReview
    case health
    case footprints
    case workLearn
    case memory
    case ask
    case progress
    case database
    case sources

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今日"
        case .timeline: "时间线"
        case .dailyReview: "每日复盘"
        case .health: "健康"
        case .footprints: "足迹"
        case .workLearn: "学习与工作"
        case .memory: "记忆"
        case .ask: "询问"
        case .progress: "进展"
        case .database: "数据库"
        case .sources: "数据源"
        }
    }

    var navigationShortcut: RiverNavigationShortcut {
        switch self {
        case .today: RiverNavigationShortcut(key: "1", modifiers: .command, label: "⌘1")
        case .timeline: RiverNavigationShortcut(key: "4", modifiers: .command, label: "⌘4")
        case .dailyReview: RiverNavigationShortcut(key: "5", modifiers: .command, label: "⌘5")
        case .health: RiverNavigationShortcut(key: "6", modifiers: .command, label: "⌘6")
        case .footprints: RiverNavigationShortcut(key: "7", modifiers: .command, label: "⌘7")
        case .workLearn: RiverNavigationShortcut(key: "8", modifiers: .command, label: "⌘8")
        case .memory: RiverNavigationShortcut(key: "2", modifiers: .command, label: "⌘2")
        case .ask: RiverNavigationShortcut(key: "3", modifiers: .command, label: "⌘3")
        case .progress: RiverNavigationShortcut(key: "9", modifiers: .command, label: "⌘9")
        case .database: RiverNavigationShortcut(key: "0", modifiers: .command, label: "⌘0")
        case .sources: RiverNavigationShortcut(key: "d", modifiers: [.command, .shift], label: "⌘⇧D")
        }
    }

    var symbol: String {
        switch self {
        case .today: "book.closed"
        case .timeline: "timeline.selection"
        case .dailyReview: "checklist"
        case .health: "heart.text.square"
        case .footprints: "mappin.and.ellipse"
        case .workLearn: "hammer.fill"
        case .memory: "archivebox"
        case .ask: "questionmark.circle"
        case .progress: "chart.line.uptrend.xyaxis"
        case .database: "cylinder.split.1x2"
        case .sources: "antenna.radiowaves.left.and.right"
        }
    }
}

enum InspectorContent: Identifiable {
    case episode(ActivityTimelineItem)
    case evidence(title: String, items: [AskEvidence])
    case archiveDay(MemoryArchiveDay)
    case durableMemory(Memory)
    case reflection(MonthlyLetter)

    var title: String {
        switch self {
        case .episode(let item): item.title
        case .evidence(let title, _): title
        case .archiveDay(let day): day.entry.shortDate
        case .durableMemory(let memory): memory.title
        case .reflection(let letter): letter.title
        }
    }

    var id: String {
        switch self {
        case .episode(let item): "episode-\(item.id)"
        case .evidence(let title, _): "evidence-\(title)"
        case .archiveDay(let day): "archive-\(day.id)"
        case .durableMemory(let memory): "memory-\(memory.id.uuidString)"
        case .reflection(let letter): "reflection-\(letter.id)"
        }
    }
}

struct RiverShellView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 打开应用自建的设置窗口。
    ///
    /// 不再用 SwiftUI 的 `Settings` 场景 + `@Environment(\.openSettings)`：
    /// 那个场景会在窗口里额外保留 28pt 标题栏空间（实测内容 620 → 窗口 648），
    /// 顶部那条空白栏删不掉。现在统一走 `SettingsWindowController`。
    private func openSettings() {
        SettingsWindowController.shared.show(
            store: store,
            activity: activity,
            ai: ai,
            ingestion: ingestion,
            feedback: feedback,
            density: density,
            prefersHighContrast: prefersHighContrast,
            palette: paletteController.palette,
            colorScheme: appearanceMode.colorScheme
        )
    }
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @ObservedObject var dateContext: DateContextStore
    @ObservedObject var location: LocationSourceStore
    let v2Store: V2Store

    @State private var destination: RiverDestination = .today
    @State private var inspectorContent: InspectorContent?
    @State private var inspectorReturnFocusID: String?
    @FocusState private var inspectorSourceFocusID: String?
    @State private var showsCapture = false
    @State private var shouldExpandJournalEditor = false
    @State private var showsCommandPalette = false
    @State private var askQuery = "这周主要做了什么？"
    // 配色切换时触发整树重绘；颜色本身在绘制时从 PaletteStore 解析。
    @StateObject private var paletteController = PaletteController.shared
    @AppStorage("appearance.mode") private var appearanceModeRaw = RiverAppearance.system.rawValue
    @AppStorage("appearance.density") private var densityRaw = RiverDensity.standard.rawValue
    @AppStorage("appearance.prefersDark") private var legacyPrefersDark = false
    @State private var didMigrateAppearance = false
    @State private var prefersHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @StateObject private var memoryLibrary: MemoryLibraryStore
    @StateObject private var journalEditor = JournalEditorStore()
    @EnvironmentObject private var feedback: FeedbackCenter

    init(
        store: DiaryStore,
        activity: ActivityStore,
        ai: AIAssistantStore,
        ingestion: DataIngestionStore,
        dateContext: DateContextStore,
        location: LocationSourceStore,
        v2Store: V2Store
    ) {
        self.store = store
        self.activity = activity
        self.ai = ai
        self.ingestion = ingestion
        self.dateContext = dateContext
        self.location = location
        self.v2Store = v2Store
        // 记忆库与全进程共享同一条 V2 连接，不再自开一份 SQLCipher。
        _memoryLibrary = StateObject(wrappedValue: MemoryLibraryStore(v2Store: v2Store))
    }

    var body: some View {
        GeometryReader { geometry in
            let usesSideInspector = geometry.size.width >= AppLayout.sideInspectorBreakpoint

            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 208, ideal: AppLayout.sidebarWidth, max: 280)
            } detail: {
                HStack(spacing: 0) {
                    content
                    // 右栏静息态：宽窗且没有选中任何节点时，证据控制台占住右列；
                    // 选中节点后同一列交给 InspectorPanel（见下方 .inspector）。
                    if usesSideInspector && inspectorContent == nil {
                        EvidenceConsoleView(
                            store: store,
                            activity: activity,
                            ingestion: ingestion,
                            v2Store: v2Store,
                            selectedDate: dateContext.selectedDate,
                            onSelectTimelineItem: { item, focusID in
                                presentEpisode(item, returningFocusTo: focusID)
                            },
                            onStartTracking: { activity.startTracking() }
                        )
                        .frame(width: AppLayout.consoleWidth)
                    }
                }
                    .background(Color.workspace)
                    .environmentObject(feedback)
                    .inspector(isPresented: inspectorBinding(usesSideInspector: usesSideInspector)) {
                        InspectorPanel(content: inspectorContent, onClose: closeInspector, store: store, library: memoryLibrary)
                            .frame(minWidth: 300, idealWidth: AppLayout.inspectorWidth, maxWidth: 400)
                    }
                    .overlay(alignment: .trailing) {
                        compactInspectorOverlay(windowWidth: geometry.size.width)
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.standard), value: inspectorContent?.id)
                    .sheet(isPresented: $showsCapture) {
                        QuickNoteSheet(store: store, date: dateContext.selectedDate)
                    }
                    .sheet(isPresented: $showsCommandPalette) {
                        CommandPaletteView(
                            onNavigate: { dest in destination = dest },
                            onWriteNote: { showsCapture = true },
                            onRefresh: { ingestion.captureNow() },
                            onOpenSource: presentImportPanel
                        )
                    }
                    .overlay(
                        Button("命令面板") { showsCommandPalette = true }
                            .keyboardShortcut("k", modifiers: .command)
                            .opacity(0)
                            .accessibilityHidden(true)
                    )
                    .onKeyPress(.escape) {
                        guard inspectorContent != nil else { return .ignored }
                        closeInspector()
                        return .handled
                    }
                    .onKeyPress(.return) { activateFocusedTimelineItem() }
                    .onKeyPress(.space) { activateFocusedTimelineItem() }
                    // 这里原本挂着一个 `.toolbar { ToolbarItemGroup(placement: .primaryAction) }`。
                    // 窗口是隐藏标题栏的，那个 item group 会在详情列顶上撑出一条约 52pt 的空带，
                    // 两个小图标孤零零贴在左侧（像素验证：图标在 y≈25pt，标题被压到 y≈83pt），
                    // 而且"写一句"与今日页头部的按钮重复。
                    // 两个动作都已在菜单里（⌘K / ⌘N）与侧栏里（命令面板 / 写一句），
                    // 所以整条工具栏直接去掉，把顶部空间还给页面标题。
            }
            // 主窗口与原生设置窗口共用同一套外观环境（密度/高对比/配色身份/tint）。
            .riverAppEnvironment(
                density: density,
                prefersHighContrast: prefersHighContrast,
                palette: paletteController.palette,
                colorScheme: appearanceMode.colorScheme
            )
            .overlay {
                if appLockEnabled && isLocked {
                    AppLockGate(isLocked: isLocked, message: "River 已锁定。") {
                        AppLock.unlock { success, _ in isLocked = !success }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let message = feedback.message {
                    RiverFeedbackBanner(message: message)
                        .padding(.top, 10)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: message.id)
                }
            }
            // 换配色要重建这层颜色子树：SwiftUI 会缓存已解析的调色板颜色，
            // 只重绘或只注入环境值都不会重新解析（实测）。
            // 位置很关键 —— 必须放在 `.onAppear` **之前**：
            // 视图自身的 `@State`（当前页面、Inspector、编辑器草稿等）保存在父级身份上，
            // 不会因为这次重建丢失；而 `.onAppear` / `.onReceive` 留在外面，
            // 实测不会重新触发，所以不会重复启动采集、也不会把已解锁的应用重新锁上。
            .id(paletteController.palette.rawValue)
            .onAppear {
                migrateAppearancePreferenceIfNeeded()
                journalEditor.attach(to: store)
                ingestion.attach(to: store, activity: activity, ai: ai)
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                // No forced AI gate: River is usable without a model connection.
                // Ingestion and AI analysis have separate availability requirements:
                // the local timeline should keep collecting even before a model is
                // configured; DataIngestionStore gates only the automatic AI step.
                ingestion.start()
                if appLockEnabled { isLocked = true }
            }
            // 关闭窗口只是隐藏（`WindowClosePolicy` 让窗口 orderOut），应用仍在
            // 菜单栏常驻记录。此前在 `onDisappear` 里停掉定时采集，等于"关窗即停止
            // 采集"，与常驻意图相反。改为只在真正退出时停止。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ingestion.stop()
            }
            .onChange(of: destination) { oldValue, newValue in
                if oldValue != newValue {
                    inspectorReturnFocusID = nil
                    inspectorSourceFocusID = nil
                    inspectorContent = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.checkExternalSnapshotChanged()
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                if appLockEnabled && !isLocked { isLocked = true }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                prefersHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverAnalysisRunDidChange)) { _ in
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverCommand)) { note in
                guard let value = note.userInfo?["value"] as? String else { return }
                handleMenuCommand(value, userInfo: note.userInfo)
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverReopenMain)) { _ in
                if let window = WindowClosePolicy.mainWindow {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .background(WindowClosePolicy())
        }
    }

    @ViewBuilder
    private func compactInspectorOverlay(windowWidth: CGFloat) -> some View {
        if windowWidth < AppLayout.sideInspectorBreakpoint, let inspectorContent {
            InspectorPanel(content: inspectorContent, onClose: closeInspector, store: store, library: memoryLibrary)
                .frame(width: min(AppLayout.inspectorWidth, max(280, windowWidth - AppLayout.sidebarWidth - 24)))
                .frame(maxHeight: .infinity)
                .background(Color.strongSurface)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: AppRadius.floating,
                        bottomLeadingRadius: AppRadius.floating,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                )
                .overlay(alignment: .leading) { RiverRule(color: Color.border) }
                .shadow(color: .black.opacity(0.16), radius: 18, x: -8, y: 0)
                .transition(reduceMotion ? AnyTransition.identity : AnyTransition.move(edge: .trailing).combined(with: .opacity))
                .zIndex(4)
        }
    }

    @MainActor
    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 iOS 数据文件"
        panel.message = "选择后会作为新的采集数据源，并立即读取今日数据。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ingestion.connectSource(to: url)
    }

    private func handleMenuCommand(_ command: String, userInfo: [AnyHashable: Any]? = nil) {
        switch command {
        case "navigate":
            if let rawDestination = userInfo?["destination"] as? String,
               let selectedDestination = RiverDestination(rawValue: rawDestination) {
                destination = selectedDestination
            }
        case "openSettings":
            openSettings()
        case "goToday": destination = .today
        case "goDate":
            if let rawDate = userInfo?["date"] as? String, let date = DiaryEntry.dateFormatter.date(from: rawDate) {
                dateContext.setSelectedDate(date)
                destination = .today
            }
        case "goMemory": destination = .memory
        case "goAsk": destination = .ask
        case "writeNote": showsCapture = true
        case "openCommandPalette": showsCommandPalette = true
        default: break
        }
    }

    private func inspectorBinding(usesSideInspector: Bool) -> Binding<Bool> {
        Binding(
            get: { usesSideInspector && inspectorContent != nil },
            set: { show in if usesSideInspector && !show { closeInspector() } }
        )
    }

    private func presentEpisode(_ item: ActivityTimelineItem, returningFocusTo focusID: String? = nil) {
        inspectorReturnFocusID = focusID
        if let focusID { inspectorSourceFocusID = focusID }
        inspectorContent = .episode(item)
        announceInspector(item.title)
    }

    private func presentInspector(_ content: InspectorContent, returningFocusTo focusID: String? = nil) {
        inspectorReturnFocusID = focusID
        inspectorContent = content
        announceInspector(content.title)
    }

    /// VoiceOver：Inspector 打开时右侧凭空多出一块详情面板，需要显式播报，
    /// 否则旁白用户无从知道选择记录后发生了什么。
    private func announceInspector(_ title: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [
                .announcement: NSAttributedString(string: "已打开详情：\(title)"),
                .priority: NSNumber(value: 2),
            ]
        )
    }

    private func closeInspector() {
        let restoreFocusID = inspectorReturnFocusID
        inspectorReturnFocusID = nil
        guard inspectorContent != nil else { return }
        inspectorContent = nil
        if let restoreFocusID {
            DispatchQueue.main.async { inspectorSourceFocusID = restoreFocusID }
        }
    }

    private func activateFocusedTimelineItem() -> KeyPress.Result {
        guard inspectorContent == nil,
              let focusID = inspectorSourceFocusID,
              let item = timelineItem(forFocusID: focusID) else { return .ignored }
        presentEpisode(item, returningFocusTo: focusID)
        return .handled
    }

    private func timelineItem(forFocusID focusID: String) -> ActivityTimelineItem? {
        guard let separator = focusID.firstIndex(of: ":") else { return nil }
        let itemID = String(focusID[focusID.index(after: separator)...])
        let date = dateContext.selectedDate
        let entry = store.entry(for: date)
        let timeline = ActivityTimelineEngine.build(
            for: date,
            sessions: activity.liveSessions(for: date),
            captures: store.captures(for: entry),
            annotations: store.timelineAnnotations
        )
        return timeline.items.first { $0.id == itemID }
    }

    private var appearanceMode: RiverAppearance {
        RiverAppearance(rawValue: appearanceModeRaw) ?? .system
    }

    private var density: RiverDensity {
        RiverDensity(rawValue: densityRaw) ?? .standard
    }

    private func migrateAppearancePreferenceIfNeeded() {
        guard !didMigrateAppearance else { return }
        didMigrateAppearance = true
        guard UserDefaults.standard.object(forKey: "appearance.mode") == nil,
              UserDefaults.standard.object(forKey: "appearance.prefersDark") != nil else { return }
        appearanceModeRaw = legacyPrefersDark ? RiverAppearance.dark.rawValue : RiverAppearance.light.rawValue
    }

    private func openAsk(_ query: String) {
        askQuery = query
        destination = .ask
    }

    // MARK: Sidebar
    // Custom sidebar: app identity, grouped modules, rich hover + selection.

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarIdentity()
            SidebarDateNavigator(context: dateContext)
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 10)
            RiverRule()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarSection("一天", items: [.today, .timeline, .dailyReview])
                    sidebarSection("生活", items: [.health, .footprints, .workLearn])
                    sidebarSection("记忆", items: [.memory, .ask, .progress])
                    sidebarSection("系统", items: [.database, .sources])
                    // 顶部工具栏去掉后，这两个全局动作在这里保留可发现的入口
                    // （菜单里的 ⌘K / ⌘N 仍然有效）。
                    SidebarGroup(title: "快捷") {
                        SidebarNavRow(
                            title: "命令面板",
                            symbol: "command",
                            shortcut: "⌘K",
                            badge: nil,
                            isSelected: false
                        ) {
                            showsCommandPalette = true
                        }
                        SidebarNavRow(
                            title: "写一句",
                            symbol: "square.and.pencil",
                            shortcut: "⌘N",
                            badge: nil,
                            isSelected: false
                        ) {
                            showsCapture = true
                        }
                    }
                    SidebarGroup(title: "设置") {
                        // 走和其它侧栏行**完全相同**的 Button 路径，只把 action 换成
                        // `openSettings()`。之前用 SettingsLink 包住这个内含 Button 的
                        // 组件，形成按钮嵌套：内层空 action 的 Button 吃掉点击，
                        // SettingsLink 从不触发——这就是"点了没反应"。
                        SidebarNavRow(
                            title: "设置",
                            symbol: "gearshape",
                            shortcut: "⌘,",
                            badge: nil,
                            isSelected: false
                        ) {
                            openSettings()
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            .riverScrollIndicators()
            .scrollIndicators(.hidden)

            RiverRule()
            SidebarFooter(
                statusLines: sidebarStatusLines,
                onOpenSettings: { openSettings() }
            )
        }
        .frame(minWidth: AppLayout.sidebarMinWidth)
        .background(Color.sidebarSurface)
        .overlay(alignment: .trailing) { RiverRule().frame(width: 1) }
    }

    /// Glanceable source health for the pinned footer: tracking, location, and
    /// the first pipeline signal — at most three quiet lines.
    private var sidebarStatusLines: [SidebarFooter.StatusLine] {
        var lines: [SidebarFooter.StatusLine] = [
            .init(
                color: activity.isTracking ? AppTheme.recording : Color.tertiaryInk,
                text: activity.isTracking ? "生活记录 · 采集中" : "生活记录 · 已暂停"
            ),
            .init(color: location.statusState.color, text: "地点足迹 · \(location.statusState.label)"),
        ]
        if let pipeline = sidebarStatusItems.first(where: { $0.id == "project-pipeline" }) {
            lines.append(.init(color: pipeline.state.color, text: "\(pipeline.title) · \(pipeline.state.label)"))
        }
        return Array(lines.prefix(3))
    }

    private func sidebarSection(_ title: String, items: [RiverDestination]) -> some View {
        SidebarGroup(title: title) {
            ForEach(items) { item in
                SidebarNavRow(
                    title: item.title,
                    symbol: item.symbol,
                    shortcut: item.navigationShortcut.label,
                    badge: item == .timeline && journalEditor.hasUnsavedChanges ? "未保存" : nil,
                    isSelected: item == destination
                ) {
                    destination = item
                }
                .accessibilityLabel(
                    item == .timeline && journalEditor.hasUnsavedChanges
                        ? "时间线，有未保存的日记草稿"
                        : item.title
                )
            }
        }
    }

    private var sidebarStatusItems: [SourceHealthItem] {
        SourceHealthBuilder.make(
            pipelineEnabled: ingestion.enabled,
            pipelineRunning: ingestion.isRunning,
            pipelineError: ingestion.lastError,
            lastIngestedAt: ingestion.lastIngestedAt,
            lastStatus: ingestion.lastStatus,
            liveTracking: activity.isTracking,
            liveSessionCount: activity.sessions.count,
            healthAvailable: store.entry(for: dateContext.selectedDate).health != nil,
            locationAvailable: store.timelineAnnotations.values.contains { !$0.normalized.placeName.isEmpty }
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .today:
            TodayDashboardView(
                store: store,
                activity: activity,
                ai: ai,
                ingestion: ingestion,
                selectedDate: dateContext.selectedDate,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onOpenTimeline: { destination = .timeline },
                onOpenJournal: {
                    shouldExpandJournalEditor = true
                    destination = .timeline
                },
                onSelectTimelineItem: { item, focusID in
                    presentEpisode(item, returningFocusTo: focusID)
                },
                onShowCapture: { showsCapture = true },
                onOpenAsk: openAsk,
                onOpenFootprints: { destination = .footprints },
                onOpenSettings: { openSettings() }
            )
        case .timeline:
            TimelineWorkspaceView(
                store: store,
                activity: activity,
                ingestion: ingestion,
                selectedDate: Binding(
                    get: { dateContext.selectedDate },
                    set: { dateContext.setSelectedDate($0) }
                ),
                editor: journalEditor,
                shouldExpandJournalEditor: $shouldExpandJournalEditor,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) },
                onShowCapture: { showsCapture = true },
                onOpenAsk: openAsk,
                onOpenSettings: { openSettings() }
            )
        case .dailyReview:
            ReviewRedesignView(
                store: store,
                activity: activity,
                ai: ai,
                library: memoryLibrary,
                selectedDate: dateContext.selectedDate,
                onRevealEvidence: { title, items in
                    inspectorContent = .evidence(title: title, items: items)
                }
            )
        case .database:
            DatabaseOverviewView(
                store: v2Store,
                selectedDate: dateContext.selectedDate,
                dailyGoal: store.dailyGoal(for: dateContext.selectedDate)
            )
        case .sources:
            SourcesOverviewView(
                activity: activity,
                ingestion: ingestion,
                location: location,
                entry: store.entry(for: dateContext.selectedDate),
                onOpenSettings: { openSettings() }
            )
        case .health:
            HealthWorkspaceView(
                store: store,
                activity: activity,
                ingestion: ingestion,
                location: location,
                entry: store.entry(for: dateContext.selectedDate),
                onOpenSources: { destination = .sources }
            )
        case .footprints:
            FootprintsWorkspaceView(
                activity: activity,
                entries: store.entries,
                selectedDate: dateContext.selectedDate,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) },
                onOpenTimeline: { destination = .timeline },
                onConnectLocation: { location.connect() },
                location: location,
                onOpenSources: { destination = .sources }
            )
        case .workLearn:
            WorkLearnWorkspaceView(
                activity: activity,
                entries: store.entries,
                selectedDate: dateContext.selectedDate,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) }
            )
        case .progress:
            ProgressWorkspaceView(
                store: store,
                activity: activity,
                selectedDate: dateContext.selectedDate
            )
        case .memory:
            MemoryRedesignView(
                store: store,
                activity: activity,
                ai: ai,
                library: memoryLibrary,
                selectedDate: dateContext.selectedDate,
                onInspectArchive: { inspectorContent = .archiveDay($0) },
                onInspectMemory: { inspectorContent = .durableMemory($0) },
                onInspectReflection: { inspectorContent = .reflection($0) }
            )
        case .ask:
            AskRedesignView(
                store: store,
                activity: activity,
                ai: ai,
                library: memoryLibrary,
                location: location,
                query: $askQuery,
                selectedDate: dateContext.selectedDate,
                savedQueries: store.savedQueries,
                onOpenFootprints: { destination = .footprints },
                onShowEvidence: { title, items in
                    inspectorContent = .evidence(title: title, items: items)
                }
            )
        }
    }
}

/// Installed on the shell's hosting window so that clicking the close button
/// *hides* it instead of destroying it. This keeps the menu-bar resident app
/// able to reactivate that same window; otherwise the window is gone and the
/// process stays alive as an unreopenable "ghost". The window is remembered so
/// the app can bring it back on Dock/reactivation.
struct WindowClosePolicy: NSViewRepresentable {
    /// The app's main window, kept alive by `isReleasedWhenClosed = false`.
    static weak var mainWindow: NSWindow?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator: NSObject, NSWindowDelegate {
        func attach(to window: NSWindow?) {
            guard let window else { return }
            window.identifier = NSUserInterfaceItemIdentifier("river-main")
            window.isReleasedWhenClosed = false
            window.delegate = self
            WindowClosePolicy.mainWindow = window
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            return false
        }
    }
}

// MARK: - Quick note sheet

struct QuickNoteSheet: View {
    @ObservedObject var store: DiaryStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var feedbackCenter: FeedbackCenter
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            HStack(alignment: .center) {
                HStack(spacing: AppSpacing.sm) {
                    RiverIconWell(systemImage: "square.and.pencil", tint: AppTheme.accent, size: 26)
                    RiverSectionHeading(
                        title: "写一句",
                        detail: date.formatted(.dateTime.year().month().day())
                    )
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .linkAction()
            }
            TextEditor(text: $text)
                .font(AppTypography.primary())
                .frame(minWidth: 400, minHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.sm)
                .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
            HStack {
                Text("会保留到所选日期 · ⌘↩ 立即保存")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                Spacer()
                Button("留下这句") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    if store.addQuickCapture(trimmed, for: date) {
                        feedbackCenter.show("已留下这句快记", kind: .success)
                        dismiss()
                    } else if case .failed(let message) = store.saveState {
                        feedbackCenter.show("保存失败：\(message)", kind: .error)
                    }
                }
                .primaryCTA()
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppSpacing.xl)
        .background(Color.strongSurface)
    }
}
