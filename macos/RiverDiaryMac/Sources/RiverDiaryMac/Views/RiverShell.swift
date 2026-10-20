import AppKit
import RiverDiaryCore
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
    case confirmations
    case dailyReview
    case habitReview
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
        case .today: "今天"
        case .timeline: "足迹"
        case .confirmations: "待确认"
        case .dailyReview: "回顾"
        case .habitReview: "习惯回顾"
        case .health: "健康"
        case .footprints: "地点"
        case .workLearn: "学习与工作"
        case .memory: "记忆"
        case .ask: "River"
        case .progress: "进展"
        case .database: "数据库"
        case .sources: "数据源"
        }
    }

    var navigationShortcut: RiverNavigationShortcut {
        switch self {
        case .today: RiverNavigationShortcut(key: "1", modifiers: .command, label: "⌘1")
        case .timeline: RiverNavigationShortcut(key: "2", modifiers: .command, label: "⌘2")
        case .confirmations: RiverNavigationShortcut(key: "3", modifiers: .command, label: "⌘3")
        case .dailyReview: RiverNavigationShortcut(key: "5", modifiers: [.command, .shift], label: "⌘⇧5")
        case .habitReview: RiverNavigationShortcut(key: "r", modifiers: [.command, .shift], label: "⌘⇧R")
        case .health: RiverNavigationShortcut(key: "6", modifiers: .command, label: "⌘6")
        case .footprints: RiverNavigationShortcut(key: "7", modifiers: .command, label: "⌘7")
        case .workLearn: RiverNavigationShortcut(key: "8", modifiers: .command, label: "⌘8")
        case .memory: RiverNavigationShortcut(key: "5", modifiers: .command, label: "⌘5")
        case .ask: RiverNavigationShortcut(key: "4", modifiers: .command, label: "⌘4")
        case .progress: RiverNavigationShortcut(key: "9", modifiers: .command, label: "⌘9")
        case .database: RiverNavigationShortcut(key: "0", modifiers: .command, label: "⌘0")
        case .sources: RiverNavigationShortcut(key: "s", modifiers: [.command, .shift], label: "⌘⇧S")
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .timeline: "point.topleft.down.to.point.bottomright.curvepath"
        case .confirmations: "checkmark.bubble"
        case .dailyReview: "book.pages"
        case .habitReview: "repeat"
        case .health: "heart"
        case .footprints: "mappin.and.ellipse"
        case .workLearn: "book.and.wrench"
        case .memory: "square.stack"
        case .ask: "bubble.left.and.bubble.right"
        case .progress: "chart.line.uptrend.xyaxis"
        case .database: "externaldrive"
        case .sources: "point.3.connected.trianglepath.dotted"
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
    @EnvironmentObject private var accountSession: RiverAccountSessionStore
    /// 打开应用自建的设置窗口。
    ///
    /// 不再用 SwiftUI 的 `Settings` 场景 + `@Environment(\.openSettings)`：
    /// 那个场景会在窗口里额外保留 28pt 标题栏空间（实测内容 620 → 窗口 648），
    /// 顶部那条空白栏删不掉。现在统一走 `SettingsWindowController`。
    private func openSettings(section: SettingsCategory? = nil, opensDatabase: Bool = false) {
        SettingsWindowController.shared.show(
            store: store,
            activity: activity,
            ai: ai,
            ingestion: ingestion,
            account: accountSession,
            feedback: feedback,
            density: density,
            prefersHighContrast: prefersHighContrast,
            palette: paletteController.palette,
            colorScheme: appearanceMode.colorScheme,
            database: v2Store,
            selectedDate: dateContext.selectedDate,
            initialCategory: section,
            opensDatabase: opensDatabase
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
    @State private var navigationHistory = RiverNavigationHistory()
    @State private var lastTimelineSection: RiverDestination = .timeline
    @State private var lastReviewSection: RiverDestination = .dailyReview
    @AppStorage("navigation.compactSidebar") private var compactSidebar = false
    @Environment(\.colorScheme) private var systemScheme
    @State private var requestedTimelineItemID: String?
    @State private var inspectorContent: InspectorContent?
    @State private var inspectorReturnFocusID: String?
    @FocusState private var inspectorSourceFocusID: String?
    @State private var showsCapture = false
    @State private var shouldExpandJournalEditor = false
    @State private var showsCommandPalette = false
    @State private var askQuery = "这周主要做了什么？"
    @State private var automaticAnalysisTask: Task<Void, Never>?
    @AppStorage("ai.footprint.lastAutomaticRealtimeRunAt") private var lastAutomaticRealtimeRunAt = 0.0
    @AppStorage("ai.footprint.lastAutomaticRealtimeAttemptKey") private var lastAutomaticRealtimeAttemptKey = ""
    // 配色切换时触发整树重绘；颜色本身在绘制时从 PaletteStore 解析。
    @StateObject private var paletteController = PaletteController.shared
    @AppStorage("appearance.mode") private var appearanceModeRaw = RiverAppearance.system.rawValue
    @AppStorage("appearance.density") private var densityRaw = RiverDensity.standard.rawValue
    @AppStorage("appearance.prefersDark") private var legacyPrefersDark = false
    @State private var didMigrateAppearance = false
    @State private var prefersHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @State private var lockMessage = "River 已锁定。"
    @StateObject private var memoryLibrary: MemoryLibraryStore
    @StateObject private var journalEditor = JournalEditorStore()
    @StateObject private var habitReview: HabitReviewStore
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
        // 习惯回顾与个人规则也走同一条 V2 连接；调度在应用激活时进行，
        // 不依赖用户停在时间线页面。
        _habitReview = StateObject(wrappedValue: HabitReviewStore(v2Store: v2Store))
    }

    var body: some View {
        GeometryReader { geometry in
            let usesSideInspector = geometry.size.width >= AppLayout.sideInspectorBreakpoint

            HStack(spacing: 0) {
                sidebar.frame(width: navigationWidth)
                VStack(spacing: 0) {
                    desktopToolbar
                    HStack(alignment: .top, spacing: 0) {
                        content(usesSideInspector: usesSideInspector)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if usesSideInspector {
                            if inspectorContent != nil {
                                InspectorPanel(content: inspectorContent, onClose: closeInspector, store: store, library: memoryLibrary)
                                    .frame(width: AppLayout.inspectorWidth)
                            } else if destination == .today {
                                EvidenceConsoleView(
                                    store: store, activity: activity, ai: ai, habitReview: habitReview,
                                    selectedDate: dateContext.selectedDate,
                                    pendingConfirmationCount: pendingConfirmationCount,
                                    excludedConfirmationTargetIDs: Set(habitReview.pendingConfirmations.compactMap {
                                        $0.pendingConfirmationContent?.targetID
                                    }),
                                    onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) },
                                    onOpenJournal: { shouldExpandJournalEditor = true; destination = .timeline },
                                    onOpenConfirmations: { destination = .confirmations }
                                )
                                .frame(width: AppLayout.consoleWidth)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        compactInspectorOverlay(windowWidth: geometry.size.width)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color.workspace)
            .environmentObject(feedback)
            .sheet(isPresented: $showsCapture) {
                QuickNoteSheet(store: store, date: dateContext.selectedDate)
            }
            .sheet(isPresented: $showsCommandPalette) {
                CommandPaletteView(
                    onNavigate: { destination = $0 },
                    onWriteNote: { showsCapture = true },
                    onRefresh: { ingestion.captureNow() },
                    onImport: presentImportPanel,
                    onOpenSettings: { openSettings() },
                    entries: store.entries,
                    onOpenDay: { entry in
                        if let date = entry.entryDate { dateContext.setSelectedDate(date) }
                        shouldExpandJournalEditor = true
                        destination = .timeline
                    }
                )
            }
            .onKeyPress(.escape) {
                guard inspectorContent != nil else { return .ignored }
                closeInspector()
                return .handled
            }
            .onKeyPress(.return) { activateFocusedTimelineItem() }
            .onKeyPress(.space) { activateFocusedTimelineItem() }
            // 主窗口与原生设置窗口共用同一套外观环境（密度/高对比/配色身份/tint）。
            .riverAppEnvironment(
                density: density,
                prefersHighContrast: prefersHighContrast,
                palette: paletteController.palette,
                colorScheme: appearanceMode.colorScheme
            )
            .overlay {
                if appLockEnabled && isLocked {
                    AppLockGate(isLocked: isLocked, message: lockMessage) {
                        AppLock.unlock { success, failureText in
                            if success {
                                lock()
                            } else {
                                // 解锁失败的原因（密码错/策略不可用）必须显示出来，
                                // 否则用户被锁在门外却不知道发生了什么。
                                lockMessage = failureText.isEmpty ? "解锁未完成，请再试一次。" : failureText
                            }
                        }
                    }
                }
            }
            .overlay(alignment: .top) {
                if let message = feedback.message {
                    RiverFeedbackBanner(message: message, onClose: { feedback.clear() })
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
                if MacSoftVisualSession.isActive {
                    memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                    return
                }
                ingestion.attach(to: store, activity: activity, ai: ai)
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                // No forced AI gate: River is usable without a model connection.
                // Ingestion and AI analysis have separate availability requirements:
                // the local timeline should keep collecting even before a model is
                // configured; DataIngestionStore gates only the automatic AI step.
                ingestion.start()
                scheduleAutomaticDailyUpdate()
                if appLockEnabled { lock() }
                updateDockBadge(count: pendingConfirmationCount)
            }
            // 关闭窗口只是隐藏（`WindowClosePolicy` 让窗口 orderOut），应用仍在
            // 菜单栏常驻记录。此前在 `onDisappear` 里停掉定时采集，等于"关窗即停止
            // 采集"，与常驻意图相反。改为只在真正退出时停止。
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                ingestion.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverAIAutomationShouldEvaluate)) { _ in
                lastAutomaticRealtimeAttemptKey = ""
                scheduleAutomaticDailyUpdate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverLocalCanonicalStateDidChange)) { _ in
                scheduleAutomaticDailyUpdate()
            }
            .onChange(of: destination) { oldValue, newValue in
                if oldValue != newValue {
                    if newValue == .workLearn { destination = .timeline; return }
                    if newValue == .sources || newValue == .database {
                        openSettings(section: .recording, opensDatabase: newValue == .database)
                        destination = oldValue
                        return
                    }
                    if newValue.workspaceRoot == .timeline { lastTimelineSection = newValue }
                    if newValue.workspaceRoot == .dailyReview { lastReviewSection = newValue }
                    navigationHistory.visit(newValue)
                    inspectorReturnFocusID = nil
                    inspectorSourceFocusID = nil
                    inspectorContent = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.checkExternalSnapshotChanged()
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                // 习惯回顾是应用级调度：激活时检查当前周期是否到期，
                // 不依赖用户停在时间线页面；手动节奏只在打开回顾页时生成。
                Task { await habitReview.evaluateWithAIIfNeeded(ai: ai) }
                if appLockEnabled && !isLocked { lock() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
                prefersHighContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverAnalysisRunDidChange)) { _ in
                memoryLibrary.refresh(entries: store.entries, captures: store.quickCaptures, letters: store.monthlyLetters)
                scheduleAutomaticDailyUpdate()
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverCommand)) { note in
                guard let value = note.userInfo?["value"] as? String else { return }
                handleMenuCommand(value, userInfo: note.userInfo)
            }
            .onChange(of: pendingConfirmationCount) { _, count in
                updateDockBadge(count: count)
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

    @MainActor
    private func scheduleAutomaticDailyUpdate() {
        guard ai.hasVerifiedConnection, ai.canRunAutomaticAnalysis,
              !ai.isDailyAnalysisPipelineRunning else { return }
        let today = DiaryEntry.dateFormatter.string(from: Date())
        guard ai.needsCurrentDayRebuild(dayKey: today),
              let date = DiaryEntry.dateFormatter.date(from: today),
              let interval = Calendar.current.dateInterval(of: .day, for: date) else { return }
        let hasEvents = !v2Store.rawEvents(between: interval.start, end: interval.end).isEmpty
        let hasEntries = store.entries.contains { $0.date == today }
        let hasSessions = !activity.sessions(from: interval.start, to: interval.end).isEmpty
        let hasCaptures = !(store.quickCaptures[today] ?? []).isEmpty
        guard hasEvents || hasEntries || hasSessions || hasCaptures else { return }
        guard let frontier = try? v2Store.currentInputFrontier() else { return }
        let attemptKey = SHA256Hex.hash(Data([
            frontier.stableKey, ai.provider.rawValue, ai.model, ai.endpoint
        ].joined(separator: "|").utf8))
        guard attemptKey != lastAutomaticRealtimeAttemptKey else { return }

        automaticAnalysisTask?.cancel()
        automaticAnalysisTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
            while ai.isDailyAnalysisPipelineRunning {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
            let cooldown = max(0, lastAutomaticRealtimeRunAt + 300 - Date().timeIntervalSince1970)
            if cooldown > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000)) } catch { return }
            }
            guard !Task.isCancelled, ai.hasVerifiedConnection, ai.canRunAutomaticAnalysis,
                  ai.needsCurrentDayRebuild(dayKey: today) else { return }
            lastAutomaticRealtimeAttemptKey = attemptKey

            let sessions = activity.sessions(from: interval.start, to: interval.end)
            let entries = store.entries.filter { $0.date == today }
            let captures = store.quickCaptures[today] ?? []
            let source = "本机记录更新后自动整理今日活动"
            let timelineOK = await ai.organizeTimeline(
                day: date, entries: entries, sessions: sessions, captures: captures,
                annotations: store.timelineAnnotations, sourceSummary: source
            )
            guard timelineOK, !Task.isCancelled else { return }
            let dailyOK = await ai.runAnalysisDaily(
                entries: entries, sessions: sessions, captures: captures,
                annotations: store.timelineAnnotations,
                archiveStartDate: today, archiveEndDate: today, sourceSummary: source
            )
            if dailyOK { lastAutomaticRealtimeRunAt = Date().timeIntervalSince1970 }
        }
    }

    @ViewBuilder
    private func compactInspectorOverlay(windowWidth: CGFloat) -> some View {
        if windowWidth < AppLayout.sideInspectorBreakpoint, let inspectorContent {
            InspectorPanel(content: inspectorContent, onClose: closeInspector, store: store, library: memoryLibrary)
                .frame(width: min(AppLayout.inspectorWidth, max(280, windowWidth - navigationWidth - 24)))
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
        // 非模态：runModal 会把整个进程卡在面板上，主窗口完全无响应。
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            ingestion.connectSource(to: url)
        }
    }

    private func handleMenuCommand(_ command: String, userInfo: [AnyHashable: Any]? = nil) {
        switch command {
        case "navigate":
            if let rawDestination = userInfo?["destination"] as? String,
               let selectedDestination = RiverDestination(rawValue: rawDestination) {
                destination = selectedDestination
            }
        case "navigationBack": navigateBack()
        case "navigationForward": navigateForward()
        case "toggleSidebar": compactSidebar.toggle()
        case "openSettings":
            openSettings()
        case "goToday": destination = .today
        case "goDate":
            if let rawDate = userInfo?["date"] as? String, let date = DiaryEntry.dateFormatter.date(from: rawDate) {
                dateContext.setSelectedDate(date)
                destination = .today
            }
        case "previousDay": dateContext.moveDay(-1)
        case "nextDay": dateContext.moveDay(1)
        case "backToToday":
            dateContext.goToday()
            destination = .today
        case "captureNow": ingestion.captureNow()
        case "importSource": presentImportPanel()
        case "goMemory": destination = .memory
        case "goAsk": destination = .ask
        case "writeNote": showsCapture = true
        case "openCommandPalette": showsCommandPalette = true
        default: break
        }
    }

    private func lock() {
        lockMessage = "River 已锁定。"
        isLocked = true
    }

    /// 共享确认与习惯问题共用 Dock 角标，和侧栏待确认徽标口径一致。
    private func updateDockBadge(count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private var pendingConfirmationCount: Int {
        habitReview.pendingCount + habitReview.pendingConfirmations.count
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

    private func revealConfirmationEvidence(_ record: RiverSharedStateRecord) {
        guard let content = record.pendingConfirmationContent else { return }
        if content.targetType == "place" {
            let candidates = (content.choices ?? []).map { choice in
                let distance = choice.distanceMeters.isFinite && choice.distanceMeters >= 0
                    ? " · 距定位点约 \(Int(choice.distanceMeters.rounded())) 米"
                    : ""
                return "\(choice.name)\(distance)\(choice.address.map { " · \($0)" } ?? "")"
            }
            let detail = ([content.detail] + candidates).filter { !$0.isEmpty }.joined(separator: "\n")
            let evidence = AskEvidence(
                id: "confirmation-\(record.id.uuidString)",
                kind: .location,
                title: content.title,
                detail: detail,
                date: record.createdAt,
                episodes: []
            )
            presentInspector(.evidence(title: "地点候选依据", items: [evidence]))
            return
        }

        let referencedSessionIDs = Set((content.evidenceRefs ?? []).compactMap { reference -> UUID? in
            guard let parsed = EvidenceReference.parse(reference), parsed.kind == .raw else { return nil }
            return UUID(uuidString: parsed.value)
        })
        let relevantSessions = activity.sessions.filter { referencedSessionIDs.contains($0.id) }
        let sessionDates = Set(relevantSessions.map { Calendar.current.startOfDay(for: $0.start) })
        let candidateDates = sessionDates.isEmpty
            ? Set(activity.sessions.map { Calendar.current.startOfDay(for: $0.start) })
            : sessionDates

        for date in candidateDates.sorted() {
            let timeline = ActivityTimelineEngine.build(
                for: date,
                sessions: activity.liveSessions(for: date),
                captures: store.captures(for: store.entry(for: date)),
                annotations: store.timelineAnnotations
            )
            if let item = timeline.items.first(where: { item in
                item.annotationKey == content.targetID
                    || item.sessions.contains(where: { referencedSessionIDs.contains($0.id) })
            }) {
                dateContext.setSelectedDate(date)
                destination = .confirmations
                presentEpisode(item)
                return
            }
        }

        destination = .timeline
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
            placeMarkers: activity.locationMarkers(for: date),
            annotations: store.timelineAnnotations
        )
        return timeline.items.first { $0.id == itemID } ?? timeline.foldedItems.first { $0.id == itemID }
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

    private var navigationWidth: CGFloat { compactSidebar ? 64 : AppLayout.sidebarWidth }

    private func navigateBack() {
        if let previous = navigationHistory.back() { destination = previous }
    }

    private func navigateForward() {
        if let next = navigationHistory.forward() { destination = next }
    }

    private var desktopToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                RiverNavigationButton(symbol: "sidebar.left", label: compactSidebar ? "展开侧栏 (⌃⌘S)" : "收起侧栏 (⌃⌘S)") {
                    compactSidebar.toggle()
                }
                Rectangle().fill(Color.separator).frame(width: 1, height: 16).padding(.horizontal, 7)
                RiverNavigationButton(symbol: "chevron.left", label: "返回上一页面 (⌥⌘[)", action: navigateBack)
                    .disabled(!navigationHistory.canGoBack)
                RiverNavigationButton(symbol: "chevron.right", label: "前往下一页面 (⌥⌘])", action: navigateForward)
                    .disabled(!navigationHistory.canGoForward)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    Text(destination.isPrimaryWorkspace && destination.sections.isEmpty ? "我的河流" : destination.workspaceRoot.title).foregroundStyle(Color.secondaryInk)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.tertiaryInk)
                    Text(destination.sectionTitle).foregroundStyle(Color.ink).fontWeight(.semibold)
                }.fixedSize()
                Text(destination.workspaceRoot.title).foregroundStyle(Color.ink).fontWeight(.semibold).fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(destination.sections.isEmpty
                ? "当前位置，\(destination.title)"
                : "当前位置，\(destination.workspaceRoot.title)，\(destination.sectionTitle)")
            .layoutPriority(1)
            Spacer(minLength: 0)
            if destination != .memory {
                SidebarDateNavigator(context: dateContext).padding(.horizontal, 7).padding(.vertical, 3)
                    .fixedSize().riverSoftSurface(radius: 24, compact: true)
            }
            Button {
                if destination == .memory { dateContext.goToday() }
                shouldExpandJournalEditor = true
                destination = .timeline
            } label: {
                Label(destination == .memory ? "写今天" : "记一笔", systemImage: "plus")
            }.primaryCTA().fixedSize()
            RiverNavigationButton(symbol: (appearanceMode.colorScheme ?? systemScheme) == .dark ? "sun.max" : "moon", label: "切换明暗外观") {
                let dark = appearanceMode.colorScheme.map { $0 == .dark } ?? (systemScheme == .dark)
                appearanceModeRaw = dark ? RiverAppearance.light.rawValue : RiverAppearance.dark.rawValue
            }
        }
        .font(AppTypography.metadata())
        .padding(.horizontal, 22)
        .frame(height: 66)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.separator).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            if compactSidebar {
                RiverSignatureMark().stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .frame(width: 19, height: 31).frame(maxWidth: .infinity).padding(.top, 35).padding(.bottom, 20)
                    .accessibilityLabel("River 河流日记")
            } else {
                SidebarIdentity().padding(.top, 22)
            }
            sidebarSearch
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: compactSidebar ? 10 : 17) {
                        ForEach(RiverNavigationGroup.allCases) { group in
                            navigationSection(group)
                        }
                    }.padding(.vertical, 8)
                        .frame(width: navigationWidth, alignment: .leading)
                        .background(NativeScrollbarSuppressor())
                }
                .riverScrollIndicators()
                .task(id: destination) {
                        await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(destination.workspaceRoot)
                }
                .onChange(of: compactSidebar) { _, _ in
                        proxy.scrollTo(destination.workspaceRoot)
                }
            }
            sidebarUtilities
        }
        .background(Color.sidebarSurface)
        .overlay(alignment: .trailing) { Rectangle().fill(Color.separator.opacity(0.65)).frame(width: 1) }
    }

    private var sidebarSearch: some View {
        Button { showsCommandPalette = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                if !compactSidebar {
                    Text("搜索与前往")
                    Spacer(minLength: 0)
                    Text("⌘K").font(AppTypography.micro()).foregroundStyle(Color.tertiaryInk)
                }
            }
            .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, compactSidebar ? 0 : 12).riverSoftInset(radius: 12)
        }
        .buttonStyle(.plain).padding(.horizontal, compactSidebar ? 12 : 20)
        .padding(.top, compactSidebar ? 0 : 17).padding(.bottom, 16)
        .accessibilityLabel("搜索记忆与功能").help("搜索记忆与功能 (⌘K)")
    }

    private func navigationSection(_ group: RiverNavigationGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compactSidebar {
                Text(group.title).font(AppTypography.micro().weight(.semibold)).tracking(0.7)
                    .foregroundStyle(Color.secondaryInk).padding(.horizontal, 24).padding(.bottom, 5)
            } else if group != .everyday {
                Rectangle().fill(Color.separator).frame(height: 1).padding(.horizontal, 22).padding(.bottom, 7)
            }
            ForEach(group.destinations) { item in navigationRow(item).id(item) }
        }
    }

    private func navigationRow(_ item: RiverDestination) -> some View {
        let count = item == .dailyReview ? pendingConfirmationCount : 0
        return SidebarNavRow(
            title: item.title, symbol: item.symbol, shortcut: item.navigationShortcut.label,
            badge: count > 0 ? String(count) : item == .timeline && journalEditor.hasUnsavedChanges ? "未保存" : nil,
            badgeIsCount: item == .dailyReview, compact: compactSidebar,
            isSelected: item == destination.workspaceRoot
        ) {
            destination = item == .timeline ? lastTimelineSection : item == .dailyReview ? lastReviewSection : item
        }
        .help("\(item.title) (\(item.navigationShortcut.label))")
        .accessibilityLabel(item == .timeline && journalEditor.hasUnsavedChanges
            ? "足迹，有未保存的日记草稿"
            : item == .dailyReview && count > 0 ? "回顾，有 \(count) 项待确认" : item.title)
    }

    private var sidebarUtilities: some View {
        VStack(spacing: 4) {
            Rectangle().fill(Color.separator).frame(height: 1).padding(.horizontal, compactSidebar ? 16 : 20).padding(.bottom, 8)
            SidebarNavRow(title: "写一句快记", symbol: "square.and.pencil", shortcut: "⌘N", compact: compactSidebar, isSelected: false) { showsCapture = true }
                .help("写一句快记 (⌘N)")
            SidebarNavRow(title: "偏好设置", symbol: "gearshape", shortcut: "⌘,", compact: compactSidebar, isSelected: false) { openSettings() }
                .help("偏好设置 (⌘,)")
            if !compactSidebar {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 10))
                    Text("我的私人河流").font(AppTypography.micro())
                    Spacer(minLength: 0)
                }.foregroundStyle(Color.secondaryInk).padding(.horizontal, 24).padding(.top, 9)
            }
        }.padding(.top, 8).padding(.bottom, 20)
    }

    /// Glanceable source health for the pinned footer. Live capture is shown on
    /// Today beside the day's facts so its state has one clear home.
    private var sidebarStatusLines: [SidebarFooter.StatusLine] {
        var lines: [SidebarFooter.StatusLine] = [
            .init(color: location.statusState.color, text: "地点足迹 · \(location.statusState.label)"),
        ]
        if let pipeline = sidebarStatusItems.first(where: { $0.id == "project-pipeline" }) {
            lines.append(.init(color: pipeline.state.color, text: "\(pipeline.title) · \(pipeline.state.label)"))
        }
        return Array(lines.prefix(3))
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
            // 与数据源页/健康页同一真相（CLLocationManager 实时状态）；
            // 之前用"时间线标注里是否有地名"推导，会和数据源页一绿一灰。
            locationAvailable: location.statusState == .healthy || location.statusState == .collecting
        )
    }

    // MARK: Content

    @ViewBuilder
    private func content(usesSideInspector: Bool) -> some View {
        VStack(spacing: 0) {
            if !destination.sections.isEmpty {
                RiverWorkspaceHeader(destination: destination, pendingCount: pendingConfirmationCount) { destination = $0 }
            }
            contentPage(usesSideInspector: usesSideInspector)
                .environment(\.riverWorkspaceEmbedded, !destination.sections.isEmpty)
        }
    }

    @ViewBuilder
    private func contentPage(usesSideInspector: Bool) -> some View {
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
                onOpenTimelineItem: { itemID in
                    requestedTimelineItemID = itemID
                    destination = .timeline
                },
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
                onOpenHealth: { destination = .health },
                onOpenSettings: { openSettings() },
                onStartTracking: { activity.startTracking() },
                habitReviewPendingCount: pendingConfirmationCount,
                onOpenHabitReview: { destination = .confirmations },
                showsEmbeddedReviewQueue: !usesSideInspector,
                excludedConfirmationTargetIDs: Set(habitReview.pendingConfirmations.compactMap { $0.pendingConfirmationContent?.targetID }),
                locationStatusState: location.statusState,
                locationStatusDetail: location.statusDetail
            )
        case .timeline:
            TimelineWorkspaceView(
                store: store,
                activity: activity,
                ingestion: ingestion,
                ai: ai,
                selectedDate: Binding(
                    get: { dateContext.selectedDate },
                    set: { dateContext.setSelectedDate($0) }
                ),
                editor: journalEditor,
                shouldExpandJournalEditor: $shouldExpandJournalEditor,
                requestedFocusItemID: $requestedTimelineItemID,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) },
                onShowCapture: { showsCapture = true },
                onOpenAsk: openAsk,
                onOpenSettings: { openSettings() },
                pendingConfirmationTargets: Set(habitReview.pendingConfirmations.compactMap { $0.pendingConfirmationContent?.targetID }),
                onOpenPlaces: { destination = .footprints }
            )
        case .confirmations:
            HabitReviewView(
                habit: habitReview,
                activity: activity,
                ai: ai,
                onOpenTimeline: { destination = .timeline },
                onRevealConfirmation: revealConfirmationEvidence,
                presentation: .confirmations
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
        case .habitReview:
            HabitReviewView(
                habit: habitReview,
                activity: activity,
                ai: ai,
                onOpenTimeline: { destination = .timeline },
                onOpenConfirmations: { destination = .confirmations }
            )
        case .database, .sources:
            EmptyView() // Legacy commands are redirected to native settings above.
        case .health:
            HealthWorkspaceView(
                store: store,
                activity: activity,
                ingestion: ingestion,
                location: location,
                entry: store.entry(for: dateContext.selectedDate),
                onOpenSources: { openSettings(section: .recording) }
            )
        case .footprints:
            FootprintsWorkspaceView(
                store: store,
                activity: activity,
                entries: store.entries,
                selectedDate: dateContext.selectedDate,
                inspectorSourceFocusID: $inspectorSourceFocusID,
                onSelectTimelineItem: { item, focusID in presentEpisode(item, returningFocusTo: focusID) },
                onOpenTimeline: { destination = .timeline },
                onConnectLocation: { location.connect() },
                location: location,
                onOpenSources: { openSettings(section: .recording) }
            )
        case .workLearn:
            EmptyView() // The former duplicate summary now opens the timeline.
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
                onInspectReflection: { inspectorContent = .reflection($0) },
                onRevealEvidence: { title, items in
                    inspectorContent = .evidence(title: title, items: items)
                },
                onOpenReview: { destination = .dailyReview },
                onWriteNote: {
                    dateContext.goToday()
                    shouldExpandJournalEditor = true
                    destination = .timeline
                }
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
    @FocusState private var editorFocused: Bool

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
                .focused($editorFocused)
                .frame(minWidth: 400, minHeight: 130)
                .scrollContentBackground(.hidden)
                .padding(AppSpacing.sm)
                .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
            HStack {
                Text("会保留到所选日期 · ↩ 立即保存")
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
        // ⌘N 唤起后光标必须已经在输入框里，不能让用户再去拿鼠标。
        .onAppear { editorFocused = true }
    }
}
