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

    /// Dock 右键菜单：应用常驻设计下，用户不应该只能靠点图标找回主窗口。
    /// 写入/采集只在已登录时出现，退出登录后同一门禁立即生效。
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(Self.menuItem("打开河流日记", command: "reopenMain"))
        if AccountMenuPresence.isSignedIn {
            menu.addItem(Self.menuItem("写一句…", command: "writeNote"))
            menu.addItem(Self.menuItem("立即采集一次", command: "captureNow"))
        }
        return menu
    }

    private static func menuItem(_ title: String, command: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(DockCommandTarget.dockAction(_:)), keyEquivalent: "")
        item.target = DockCommandTarget.shared
        item.representedObject = command
        return item
    }
}

/// 菜单与 Dock 共用的登录态快照：AppKit 的 Dock 菜单拿不到 SwiftUI 环境，
/// 用同一份状态保证“没登录就不出现写入/采集入口”。
@MainActor
enum AccountMenuPresence {
    static var isSignedIn = false
}

/// Dock 菜单的 action 落点：统一走 riverCommand 总线，由 shell 执行。
@MainActor
final class DockCommandTarget: NSObject {
    static let shared = DockCommandTarget()

    @objc func dockAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        if command == "reopenMain" {
            NotificationCenter.default.post(name: .riverReopenMain, object: nil)
        } else {
            NotificationCenter.default.post(name: .riverCommand, object: nil, userInfo: ["value": command])
        }
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
    @StateObject private var accountSession: RiverAccountSessionStore
    /// 主窗口与原生设置窗口共用同一个反馈中心，设置页的保存/失败提示
    /// 才会走到用户看得见的地方。
    @StateObject private var feedback = FeedbackCenter()
    @State private var pendingDailyRebuild: Task<Void, Never>?
    /// 全进程共享一条 V2 事实库连接：否则每个 store 各开一次 SQLCipher
    /// 并在主线程重复建表 DDL；恢复快照时也只需重开这一条连接。
    private let v2Store: V2Store

    init() {
        if let isolationError = MacQAStorageIsolation.startupError(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            applicationSupportDirectory: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first,
            temporaryDirectory: FileManager.default.temporaryDirectory
        ) {
            preconditionFailure(isolationError)
        }

        let account = RiverAccountSessionStore(platform: .macos, deviceName: ProcessInfo.processInfo.hostName, loadPersistedSession: !MacSoftVisualSession.isActive)
        _accountSession = StateObject(wrappedValue: account)

        // 资料生命周期：首次未绑定账号时不创建正式库。已有库、旧安装的救援资料
        // 或已登录时才打开；否则等登录（或显式认领）后由 openIfNeeded() 建库。
        let shouldOpenLibrary = LibraryOpenPolicy.shouldOpenLocalLibrary(
            hasDatabaseFile: LocalLibraryPresence.databaseFileExists(),
            hasLegacyLocalState: LocalLibraryPresence.legacyStateExists(),
            isSignedIn: account.isSignedIn
        )
        #if DEBUG
        let sharedV2 = MacSoftVisualSession.isActive
            ? V2Store(testDeviceID: RiverDeviceID(rawValue: "mac_isolated_visual_preview"), opensImmediately: true)
            : V2Store(opensImmediately: shouldOpenLibrary)
        #else
        let sharedV2 = V2Store(opensImmediately: shouldOpenLibrary)
        #endif
        v2Store = sharedV2
        _restoreRecovery = StateObject(wrappedValue: RestoreRecoveryBootstrap())
        _ingestion = StateObject(wrappedValue: DataIngestionStore(v2Store: sharedV2))
        let diaryStore = DiaryStore()
        let activityStore = ActivityStore(v2Store: sharedV2, startsAutomatically: account.isSignedIn)
        #if DEBUG
        if MacSoftVisualSession.isActive {
            let previewTimeline = ActivityTimelineEngine.build(for: MacSoftVisualSession.date, sessions: MacSoftVisualSession.sessions)
            if let item = previewTimeline.items.first(where: { $0.kind == .activity }),
               let record = RiverSharedStateRecord.timelineClarification(
                    candidateID: "soft-qa-timeline", annotationKey: item.annotationKey,
                    observation: "隔离预览：这一段记录是否属于桌面设计？",
                    opening: "这段时间，你在推进桌面设计吗？",
                    evidenceRefs: item.evidenceRef.map { [$0] } ?? [],
                    createdAt: MacSoftVisualSession.date) {
                _ = sharedV2.saveSharedUserRecord(record)
            }
        }
        #endif
        diaryStore.onQuickCaptureSaved = { activityStore.replicateQuickCapture($0) }
        diaryStore.onQuickCaptureRemoved = { activityStore.tombstoneQuickCapture($0) }
        diaryStore.onQuickCaptureMetadataChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.loadSharedQuickCaptureMetadata = {
            Dictionary(uniqueKeysWithValues: sharedV2.sharedUserRecords().compactMap { record in
                guard record.kind == .quickCaptureMetadata, record.status == "current",
                      let metadata = record.quickCaptureMetadata else { return nil }
                return (metadata.eventID, metadata)
            })
        }
        diaryStore.onSharedJournalEntryChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.onSharedMonthlyLetterChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.onSharedMonthlyLetterDraftChanged = { sharedV2.saveSharedUserRecord($0) }
        diaryStore.loadSharedMonthlyLetterDrafts = {
            Dictionary(uniqueKeysWithValues: sharedV2.sharedUserRecords().compactMap { record in
                guard record.kind == .monthlyLetterDraft,
                      let draft = record.monthlyLetterDraftContent else { return nil }
                return (draft.monthKey, draft)
            })
        }
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
            guard sharedV2.resolvePendingTimelineConfirmation(annotationKey: key, annotation: annotation) else {
                throw RiverSyncStoreError.persistence(sharedV2.lastError ?? "待确认决定尚未加入共享队列")
            }
        }
        diaryStore.loadSharedTimelineAnnotations = { sharedV2.timelineAnnotationsFromOperations() }
        diaryStore.reloadSharedTimelineAnnotations()
        _ = diaryStore.migrateLocalQuickCapturesToCanonicalEvents()
        _store = StateObject(wrappedValue: diaryStore)
        _activity = StateObject(wrappedValue: activityStore)
        _ai = StateObject(wrappedValue: AIAssistantStore(v2Store: sharedV2))
        _dateContext = StateObject(wrappedValue: DateContextStore())
        let locationStore = LocationSourceStore(v2Store: sharedV2)
        _location = StateObject(wrappedValue: locationStore)
        // 诊断报告/设置页里的"位置授权"行由这里注入真实状态；
        // 之前写死"Mac 位置采集器尚未实现"，与已上线的位置采集相矛盾。
        activityStore.syncSettingsStore.locationAuthorizationProvider = { [weak locationStore] in
            guard let locationStore else { return "未接入" }
            return locationStore.statusState.label
        }
    }

    @AppStorage("appearance.mode") private var settingsAppearanceRaw = RiverAppearance.system.rawValue
    /// 必须用 @AppStorage 观察：直接用 UserDefaults 读取的话，用户在设置里改密度时
    /// 这个 scene 不会重算，密度要等下次启动才生效。
    @AppStorage("appearance.density") private var settingsDensityRaw = RiverDensity.standard.rawValue

    private var appearanceModeForSettings: RiverAppearance {
        RiverAppearance(rawValue: settingsAppearanceRaw) ?? .system
    }

    /// 登录完成后才打开此前被延迟的正式库，并让已存在的 store 重新读一次共享状态。
    /// 已有库的用户在启动时就已经打开，这里只是幂等确认。
    private func activateSignedInLibrary() {
        AccountMenuPresence.isSignedIn = true
        ai.setAccountActive(true)
        v2Store.openIfNeeded()
        store.reloadSharedTimelineAnnotations()
        store.applySharedDiaryRecords(v2Store.sharedUserRecords())
        startSignedInServices()
    }

    private func startSignedInServices() {
        activity.setAccountServicesActive(true)
        Task {
            await ai.resumeRecoverableAnalysisJobs()
            _ = ai.reconcilePendingTimelineConfirmations()
        }
        // 晚间提醒的排定自愈：开关是开的但系统里排定丢失时补排。
        Task { await EveningReminderStore().reinstateIfEnabled() }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let message = restoreRecovery.error {
                    RestoreRecoveryGateView(message: message) {
                        restoreRecovery.retry()
                    }
                } else if accountSession.isSignedIn || MacSoftVisualSession.isActive {
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
                    .ignoresSafeArea(.container, edges: .top)
                } else {
                    MacAccountLoginView()
                }
            }
            .environmentObject(accountSession)
            .task { await accountSession.retryPendingSignOuts() }
            .frame(minWidth: 960, minHeight: 640)
            .onAppear {
                #if DEBUG
                if MacSoftVisualSession.isActive {
                    activity.installSoftVisualSession()
                    dateContext.setSelectedDate(MacSoftVisualSession.date)
                }
                #endif
                if accountSession.isSignedIn { activateSignedInLibrary() }
            }
            .onChange(of: accountSession.isSignedIn) { _, signedIn in
                if signedIn { activateSignedInLibrary() }
                else {
                    AccountMenuPresence.isSignedIn = false
                    ai.setAccountActive(false)
                    pendingDailyRebuild?.cancel()
                    pendingDailyRebuild = nil
                    activity.setAccountServicesActive(false)
                    ingestion.stop()
                    location.disconnect()
                    // 主动退出后关闭数据库上下文：登录页面上不再有可用的本机事实库。
                    v2Store.close()
                    // 已排定的晚间提醒在退出后不再弹给一个未登录的应用。
                    EveningReminderStore().cancelScheduled()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .riverCanonicalSyncDidChange)) { notification in
                guard accountSession.isSignedIn else { return }
                let report = notification.object as? SyncRunReport
                if (report?.importedEventBatches ?? 0) > 0 || (report?.importedOperationBatches ?? 0) > 0 {
                    ingestion.captureNow(runsAIAnalysis: false)
                }
                _ = ai.reconcilePendingTimelineConfirmations()
                store.reloadSharedTimelineAnnotations()
                let operationFrontierBeforeMigration = try? v2Store.currentInputFrontier()
                _ = store.migrateLocalJournalStateToSharedOperations()
                store.applySharedDiaryRecords(v2Store.sharedUserRecords())
                let operationFrontierAfterMigration = try? v2Store.currentInputFrontier()
                let migratedLegacyAnnotations = store.migrateLegacyTimelineAnnotationsToOperations()
                if operationFrontierBeforeMigration != operationFrontierAfterMigration || migratedLegacyAnnotations {
                    DispatchQueue.main.async { activity.syncSettingsStore.synchronize() }
                }

                let today = DiaryEntry.dateFormatter.string(from: Date())
                if ai.needsCurrentDayRebuild(dayKey: today) && ai.canRunAutomaticAnalysis {
                    pendingDailyRebuild?.cancel()
                    pendingDailyRebuild = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 900_000_000) } catch { return }
                        while !Task.isCancelled && ai.isDailyAnalysisPipelineRunning {
                            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        }
                        guard !Task.isCancelled, ai.canRunAutomaticAnalysis,
                              ai.needsCurrentDayRebuild(dayKey: today) else { return }
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
                ai.restoreAnalysisResults(startDate: today, endDate: today)
            }
        }
        .defaultSize(width: 1400, height: 940)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            if restoreRecovery.error == nil {
                AppCommands(
                    ingestion: ingestion,
                    store: store,
                    activity: activity,
                    ai: ai,
                    feedback: feedback,
                    account: accountSession,
                    database: v2Store
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
            if restoreRecovery.error == nil && accountSession.isSignedIn {
                // 关窗=常驻的设计下，弹层必须有一条回到主窗口的路，
                // 否则用户只能靠点 Dock 图标找回界面。
                Button("打开河流日记") {
                    NotificationCenter.default.post(name: .riverReopenMain, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
                Divider()
                QuickCaptureView(store: store)
            } else if restoreRecovery.error == nil {
                VStack(spacing: 12) {
                    Button("打开河流日记") {
                        NotificationCenter.default.post(name: .riverReopenMain, object: nil)
                    }
                    Text("请先在 River Diary 主窗口登录账号。")
                        .font(AppTypography.secondary())
                }
                .padding()
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
    @ObservedObject var account: RiverAccountSessionStore
    var database: V2Store? = nil

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
            account: account,
            feedback: feedback,
            density: RiverDensity(
                rawValue: UserDefaults.standard.string(forKey: "appearance.density") ?? ""
            ) ?? .standard,
            prefersHighContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            palette: PaletteController.shared.palette,
            colorScheme: RiverAppearance(
                rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? ""
            )?.colorScheme,
            database: database
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
            .disabled(!account.isSignedIn)
                .keyboardShortcut("n", modifiers: .command)
            Button("命令面板…") { postCommand(.riverCommand, "openCommandPalette") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandMenu("前往") {
            Button("返回上一页面") { postCommand(.riverCommand, "navigationBack") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("前往下一页面") { postCommand(.riverCommand, "navigationForward") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("展开或收起侧栏") { postCommand(.riverCommand, "toggleSidebar") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            ForEach(RiverNavigationGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.destinations) { destination in
                        Button(destination.title) { postNavigation(destination) }
                            .keyboardShortcut(destination.navigationShortcut.keyboardShortcut)
                    }
                }
            }
            Divider()
            Menu("足迹分区") {
                ForEach([RiverDestination.footprints, .health]) { item in
                    Button(item.title) { postNavigation(item) }.keyboardShortcut(item.navigationShortcut.keyboardShortcut)
                }
                Button("学习与工作记录") { postNavigation(.timeline) }
                    .keyboardShortcut(RiverDestination.workLearn.navigationShortcut.keyboardShortcut)
            }
            Menu("回顾分区") {
                ForEach([RiverDestination.confirmations, .habitReview, .progress]) { item in
                    Button(item.sectionTitle) { postNavigation(item) }.keyboardShortcut(item.navigationShortcut.keyboardShortcut)
                }
            }
            Menu("设置与数据工具") {
                Button("数据源与采集") { postNavigation(.sources) }.keyboardShortcut(RiverDestination.sources.navigationShortcut.keyboardShortcut)
                Button("本地数据库") { postNavigation(.database) }.keyboardShortcut(RiverDestination.database.navigationShortcut.keyboardShortcut)
            }
            Divider()
            // Existing date shortcuts remain independent from page history.
            Button("上一天") { postCommand(.riverCommand, "previousDay") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("[", modifiers: .command)
            Button("下一天") { postCommand(.riverCommand, "nextDay") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("]", modifiers: .command)
            Button("回到今天") { postCommand(.riverCommand, "backToToday") }
            .disabled(!account.isSignedIn)
        }
        CommandMenu("数据") {
            Button("立即采集一次") { postCommand(.riverCommand, "captureNow") }
            .disabled(!account.isSignedIn)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!ingestion.enabled)
            Button("打开数据源页") { postNavigation(.sources) }
            Divider()
            // 导入面板只有 shell 里一份实现（非模态）；这里只负责发指令。
            Button("导入 iOS 数据…") { postCommand(.riverCommand, "importSource") }
            .disabled(!account.isSignedIn)
        }
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
