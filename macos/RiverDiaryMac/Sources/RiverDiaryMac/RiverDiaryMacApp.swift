import AppKit
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
    @StateObject private var restoreRecovery = RestoreRecoveryBootstrap()
    @StateObject private var ingestion = DataIngestionStore()
    @StateObject private var store = DiaryStore()
    @StateObject private var activity = ActivityStore()
    @StateObject private var ai = AIAssistantStore()
    @StateObject private var dateContext = DateContextStore()
    @StateObject private var location = LocationSourceStore()

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
                        location: location
                    )
                }
            }
            .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            if restoreRecovery.error == nil {
                AppCommands(ingestion: ingestion)
            } else {
                CommandMenu("恢复") {
                    Button("重新尝试恢复") { restoreRecovery.retry() }
                }
            }
        }

        MenuBarExtra("River 快记", systemImage: "leaf.fill") {
            if restoreRecovery.error == nil {
                QuickCaptureView(store: store)
            } else {
                VStack(spacing: 12) {
                    Text("本地恢复尚未完成")
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

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { postCommand(.riverCommand, "openSettings") }
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
            Button("打开采集数据源…", action: presentImport)
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
