import AppKit
import RiverDiaryCore
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Internal command bus so the macOS menu bar can steer the shell.
    static let riverCommand = Notification.Name("river.menuCommand")
    /// Posted by the AppDelegate when the app is reactivated but has no visible
    /// window, so the shell can bring the hidden main window back.
    static let riverReopenMain = Notification.Name("river.reopenMain")
    /// Posted after an AI result is written to V2 so the shared Memory library
    /// can refresh without relying on a view reappearing.
    static let riverAnalysisRunDidChange = Notification.Name("river.analysisRunDidChange")
}

/// Keeps the app resident in the menu bar while the main window is closed, and
/// reopens that window when the user reactivates (e.g. clicks the Dock icon).
/// Without this, closing the window turns the app into an unreopenable ghost:
/// the `MenuBarExtra` keeps the process alive but nothing brings the window back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay resident so the menu bar quick capture keeps working.
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NotificationCenter.default.post(name: .riverReopenMain, object: nil)
        }
        return true
    }
}

@main
struct RiverDiaryMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var restoreRecovery: RestoreRecoveryBootstrap
    @StateObject private var ingestion: DataIngestionStore
    @StateObject private var store: DiaryStore
    @StateObject private var activity: ActivityStore
    @StateObject private var ai: AIAssistantStore
    @StateObject private var dateContext: DateContextStore
    @StateObject private var location: LocationSourceStore
    /// 主窗口与原生设置窗口共用同一个反馈中心，设置页的保存/失败提示
    /// 才会走到用户看得见的地方。
    @StateObject private var feedback = FeedbackCenter()
    /// 全进程共享一条 V2 事实库连接：否则每个 store 各开一次 SQLCipher
    /// 并在主线程重复建表 DDL；恢复快照时也只需重开这一条连接。
    private let v2Store: V2Store

    init() {
        let sharedV2 = V2Store()
        v2Store = sharedV2
        _restoreRecovery = StateObject(wrappedValue: RestoreRecoveryBootstrap())
        _ingestion = StateObject(wrappedValue: DataIngestionStore(v2Store: sharedV2))
        let diaryStore = DiaryStore()
        let activityStore = ActivityStore(v2Store: sharedV2)
        diaryStore.onQuickCaptureSaved = { activityStore.replicateQuickCapture($0) }
        diaryStore.onQuickCaptureRemoved = { activityStore.tombstoneQuickCapture($0) }
        diaryStore.onSharedJournalEntryChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.onSharedMonthlyLetterChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.onMoodScoreChanged = { day, score, updatedAt in
            sharedV2.setMoodScore(dayKey: day, score: score, updatedAt: updatedAt)
        }
        diaryStore.onMoodScoreReset = { day, updatedAt in
            sharedV2.resetMoodScore(dayKey: day, updatedAt: updatedAt)
        }
        diaryStore.onDiaryDataReady = { [weak diaryStore] in
            guard let diaryStore else { return }
            _ = diaryStore.migrateLocalJournalStateToSharedOperations()
            diaryStore.applySharedDiaryRecords(sharedV2.sharedUserRecords())
        }
        diaryStore.onTimelineAnnotationChanged = { annotation, key in
            let payload = try JSONEncoder().encode(annotation)
            guard sharedV2.appendStateOperation(
                targetID: key,
                fieldKey: "annotation",
                operationType: "timeline.annotation.set",
                payload: payload
            ) != nil else {
                throw RiverSyncStoreError.persistence(sharedV2.lastError ?? "同步用户修改失败")
            }
        }
        diaryStore.loadSharedTimelineAnnotations = { sharedV2.timelineAnnotationsFromOperations() }
        diaryStore.reloadSharedTimelineAnnotations()
        _ = diaryStore.migrateLocalQuickCapturesToCanonicalEvents()
        _store = StateObject(wrappedValue: diaryStore)
        _activity = StateObject(wrappedValue: activityStore)
        _ai = StateObject(wrappedValue: AIAssistantStore(v2Store: sharedV2))
        _dateContext = StateObject(wrappedValue: DateContextStore())
        _location = StateObject(wrappedValue: LocationSourceStore(v2Store: sharedV2))
    }

    @AppStorage("appearance.mode") private var settingsAppearanceRaw = RiverAppearance.system.rawValue
    /// 必须用 @AppStorage 观察：直接用 UserDefaults 读取的话，用户在设置里改密度时
    /// 这个 scene 不会重算，密度要等下次启动才生效。
    @AppStorage("appearance.density") private var settingsDensityRaw = RiverDensity.standard.rawValue

    private var appearanceModeForSettings: RiverAppearance {
        RiverAppearance(rawValue: settingsAppearanceRaw) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let message = restoreRecovery.error {
                    RestoreRecoveryGateView(message: message) {
                        restoreRecovery.retry()
                    }
                } else {
                    RiverShellView(
                        store: store,
                        activity: activity,
                        ai: ai,
                        ingestion: ingestion,
                        dateContext: dateContext,
                        location: location,
                        v2Store: v2Store
                    )
                    .environmentObject(feedback)
                }
            }
            .frame(minWidth: 960, minHeight: 640)
            .onAppear { activity.startAutomaticSync() }
            .onReceive(NotificationCenter.default.publisher(for: .riverCanonicalSyncDidChange)) { notification in
                let report = notification.object as? SyncRunReport
                if (report?.importedEventBatches ?? 0) > 0 || (report?.importedOperationBatches ?? 0) > 0 {
                    ingestion.captureNow(runsAIAnalysis: false)
                }
                let today = DiaryEntry.dateFormatter.string(from: Date())
                let analysisStore = activity.replicationDatabase()
                let staleReview = analysisStore.canonicalArtifactRevision(
                    logicalKey: RiverCanonicalArtifactKey.dailyReview(dayKey: today), kind: .dailyReview
                )?.status == .stale
                let currentFrontier = try? analysisStore.currentInputFrontier()
                let queuedReview = analysisStore.analysisJobs().contains {
                    $0.logicalKey == RiverCanonicalArtifactKey.dailyReview(dayKey: today) && $0.artifactType == .dailyReview
                        && $0.inputFrontier == currentFrontier
                        && ($0.status == .queued || $0.status == .running)
                }
                if (staleReview || queuedReview) && ai.canRunAutomaticAnalysis {
                    Task { @MainActor in
                        await Task.yield()
                        guard let date = DiaryEntry.dateFormatter.date(from: today),
                              let interval = Calendar.current.dateInterval(of: .day, for: date) else { return }
                        let sessions = activity.sessions(from: interval.start, to: interval.end)
                        let entries = store.entries.filter { $0.date == today }
                        let captures = store.quickCaptures[today] ?? []
                        _ = await ai.runAnalysisDaily(
                            entries: entries,
                            sessions: sessions,
                            captures: captures,
                            annotations: store.timelineAnnotations,
                            archiveStartDate: today,
                            archiveEndDate: today,
                            sourceSummary: "同步到较新的 Event 后自动更新今日回顾"
                        )
                    }
                }
                store.reloadSharedTimelineAnnotations()
                store.applySharedDiaryRecords(v2Store.sharedUserRecords())
                if store.migrateLegacyTimelineAnnotationsToOperations() {
                    DispatchQueue.main.async { activity.syncSettingsStore.synchronize() }
                }
                ai.restoreAnalysisResults(startDate: today, endDate: today)
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            if restoreRecovery.error == nil {
                AppCommands(
                    ingestion: ingestion,
                    store: store,
                    activity: activity,
                    ai: ai,
                    feedback: feedback
                )
            } else {
                CommandMenu("恢复") {
                    Button("重新尝试恢复") { restoreRecovery.retry() }
                }
            }
        }

        // 设置窗口不用 SwiftUI 的 `Settings` 场景：那个场景会在窗口里额外保留
        // 28pt 标题栏空间（实测内容 620 → 窗口 648），删不掉。
        // 改由 `SettingsWindowController` 自建无边框窗口，标题栏高度为 0。

        MenuBarExtra("River 快记", systemImage: "leaf.fill") {
            if restoreRecovery.error == nil {
                QuickCaptureView(store: store)
            } else {
                VStack(spacing: 12) {
                    Text("本地恢复尚未完成")
                    .font(AppTypography.secondary())
                    Button("重新尝试恢复") { restoreRecovery.retry() }
                }
                .padding()
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar commands wired to the real shell actions.
@MainActor
struct AppCommands: Commands {
    var ingestion: DataIngestionStore
    var store: DiaryStore
    var activity: ActivityStore
    var ai: AIAssistantStore
    var feedback: FeedbackCenter

    /// 打开应用自建的设置窗口。
    ///
    /// 这里必须能拿到各个 store —— 设置页要读写它们，而窗口是 AppKit 侧新建的，
    /// 不会自动继承主窗口的 environment。
    private func openSettings() {
        SettingsWindowController.shared.show(
            store: store,
            activity: activity,
            ai: ai,
            ingestion: ingestion,
            feedback: feedback,
            density: RiverDensity(
                rawValue: UserDefaults.standard.string(forKey: "appearance.density") ?? ""
            ) ?? .standard,
            prefersHighContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            palette: PaletteController.shared.palette,
            colorScheme: RiverAppearance(
                rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? ""
            )?.colorScheme
        )
    }

    var body: some Commands {
        // 已经没有 Settings 场景了，所以 ⌘, 这条菜单项由应用自己提供。
        // 注意用真正的 SwiftUI action（而不是之前那个 NSApp.sendAction 的 selector 方案，
        // 那个在纯 SwiftUI 应用里根本触发不了）。
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {
            Button("写一句…") { postCommand(.riverCommand, "writeNote") }
                .keyboardShortcut("n", modifiers: .command)
            Button("命令面板…") { postCommand(.riverCommand, "openCommandPalette") }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("前往") {
            Button(RiverDestination.today.title) { postNavigation(.today) }
                .keyboardShortcut(RiverDestination.today.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.memory.title) { postNavigation(.memory) }
                .keyboardShortcut(RiverDestination.memory.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.ask.title) { postNavigation(.ask) }
                .keyboardShortcut(RiverDestination.ask.navigationShortcut.keyboardShortcut)
            Divider()
            Button(RiverDestination.timeline.title) { postNavigation(.timeline) }
                .keyboardShortcut(RiverDestination.timeline.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.dailyReview.title) { postNavigation(.dailyReview) }
                .keyboardShortcut(RiverDestination.dailyReview.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.habitReview.title) { postNavigation(.habitReview) }
                .keyboardShortcut(RiverDestination.habitReview.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.health.title) { postNavigation(.health) }
                .keyboardShortcut(RiverDestination.health.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.footprints.title) { postNavigation(.footprints) }
                .keyboardShortcut(RiverDestination.footprints.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.workLearn.title) { postNavigation(.workLearn) }
                .keyboardShortcut(RiverDestination.workLearn.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.progress.title) { postNavigation(.progress) }
                .keyboardShortcut(RiverDestination.progress.navigationShortcut.keyboardShortcut)
            Divider()
            Button(RiverDestination.database.title) { postNavigation(.database) }
                .keyboardShortcut(RiverDestination.database.navigationShortcut.keyboardShortcut)
            Button(RiverDestination.sources.title) { postNavigation(.sources) }
                .keyboardShortcut(RiverDestination.sources.navigationShortcut.keyboardShortcut)
        }
        CommandMenu("数据") {
            Button("立即采集一次") { ingestion.captureNow() }
                .disabled(!ingestion.enabled)
            Button("打开数据源页") { postNavigation(.sources) }
            Divider()
            Button("导入 iOS 数据…", action: presentImport)
        }
        CommandMenu("窗口大小") {
            Button("紧凑 · 960 × 640") { resizeMainWindow(width: 960, height: 640) }
            Button("标准 · 1280 × 800") { resizeMainWindow(width: 1280, height: 800) }
            Button("宽屏 · 1440 × 900") { resizeMainWindow(width: 1440, height: 900) }
        }
    }

    private func resizeMainWindow(width: CGFloat, height: CGFloat) {
        guard let window = WindowClosePolicy.mainWindow else { return }
        window.setContentSize(NSSize(width: width, height: height))
        window.center()
    }

    private func presentImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 iOS 数据文件（river-diary-user-data.json）"
        panel.message = "选择后会作为新的采集数据源，并立即读取今日数据。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ingestion.connectSource(to: url)
    }
}

private func postCommand(_ name: Notification.Name, _ value: String) {
    NotificationCenter.default.post(name: name, object: nil, userInfo: ["value": value])
}

private func postNavigation(_ destination: RiverDestination) {
    NotificationCenter.default.post(
        name: .riverCommand,
        object: nil,
        userInfo: ["value": "navigate", "destination": destination.rawValue]
    )
}
