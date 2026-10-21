import AppKit
import RiverDiaryCore
import SwiftUI

/// 设置窗口。
///
/// **为什么不用 SwiftUI 的 `Settings` 场景？**
/// 该场景会在它自己创建的窗口里额外保留 28pt 的标题栏空间：实测内容 frame 620 时
/// 窗口高 648，那 28pt 就是窗口顶部一条删不掉的空白栏。
/// `styleMask.remove(.titled)`、`titleVisibility = .hidden` 都改不掉它——
/// 28pt 是场景在 SwiftUI 层加进来的，不是 `NSWindow` 的标题栏。
///
/// 所以这里自己起一个**无边框窗口**（`styleMask` 不含 `.titled`）：
/// 实测标题栏高度为 0、内容铺满整窗、窗口尺寸就是内容尺寸。
/// 代价是要自己承担窗口控制，由左栏顶部的 `WindowControls` 负责。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    /// 供左栏顶部的 `WindowControls` 使用。
    ///
    /// 不要用 `NSApp.keyWindow`：设置窗口可能不是 key（例如主窗口刚被点击），
    /// 那时"关闭"会错误地作用于主窗口。
    var currentWindow: NSWindow? { window }

    /// 打开（或前置）设置窗口。
    func show(
        store: DiaryStore,
        activity: ActivityStore,
        ai: AIAssistantStore,
        ingestion: DataIngestionStore,
        account: RiverAccountSessionStore,
        feedback: FeedbackCenter,
        density: RiverDensity,
        prefersHighContrast: Bool,
        palette: RiverPalette,
        colorScheme: ColorScheme?,
        database: V2Store? = nil,
        selectedDate: Date = Date(),
        initialCategory: SettingsCategory? = nil,
        opensDatabase: Bool = false
    ) {
        if let window {
            NotificationCenter.default.post(name: .riverSettingsNavigate, object: nil, userInfo: [
                "category": initialCategory?.rawValue ?? "", "date": selectedDate, "database": opensDatabase
            ])
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = SettingsRedesignView(
            store: store,
            activity: activity,
            ai: ai,
            ingestion: ingestion,
            databaseStore: database,
            initialCategory: initialCategory ?? .recording,
            inspectionDate: selectedDate,
            initiallyShowsDatabase: opensDatabase
        )
        .environmentObject(account)
        .environmentObject(store)
        .environmentObject(feedback)
        .riverAppEnvironment(
            density: density,
            prefersHighContrast: prefersHighContrast,
            palette: palette,
            colorScheme: colorScheme
        )

        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = NSRect(
            x: 0,
            y: 0,
            width: AppLayout.settingsWindowWidth,
            height: AppLayout.settingsWindowHeight
        )

        // 必须带上 `.closable`：无边框窗口没有标题栏，也就没有标准关闭按钮，
        // 而 `performClose(_:)` 在没有关闭按钮时**什么也不做**（实测：调用后窗口依然可见）。
        // `.closable` 本身不会让红黄绿重新出现（无 `.titled` 就没有标题栏视图）。
        let window = SettingsPanel(
            contentRect: hosting.view.frame,
            styleMask: [.closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "设置"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(
            width: AppLayout.settingsWindowMinWidth,
            height: AppLayout.settingsWindowMinHeight
        )
        window.backgroundColor = NSColor(Color.workspace)
        window.isOpaque = true
        window.setFrameAutosaveName("RiverDiarySettingsWindow")
        // 每次打开都居中到主窗口，而不是记住上一处奇怪的位置。
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .riverSettingsWindowDidOpen, object: nil)

        // AppKit 层兜底压制原生滚动条：NSHostingController 的层级挂载时机
        // 不确定，视图内的压制器可能赶不上（实测设置窗口右缘残留原生条）。
        // 这里对整棵视图树做几轮深度扫描，无论 NSScrollView 何时出现都能关掉。
        for delay in [0.2, 0.6, 1.2, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window, window.isVisible else { return }
                Self.suppressNativeScrollers(in: window.contentView)
            }
        }
    }

    /// 递归关掉视图树里所有 NSScrollView 的原生滚动条。
    static func suppressNativeScrollers(in view: NSView?) {
        guard let view else { return }
        if let scrollView = view as? NSScrollView {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
        }
        for subview in view.subviews {
            suppressNativeScrollers(in: subview)
        }
    }
}

/// 无边框窗口默认不接受键盘输入，设置里的输入框、快捷键都需要它。
private final class SettingsPanel: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 无边框窗口没有标准关闭按钮，AppKit 的默认实现会直接放弃（实测无效）。
    /// 这里改成真正关窗；`isReleasedWhenClosed = false`，所以关掉之后还能再打开。
    override func performClose(_ sender: Any?) {
        close()
    }

    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else { super.cancelOperation(sender); return }
        close()
    }
}

extension Notification.Name {
    static let riverSettingsWindowDidOpen = Notification.Name("river.settingsWindowDidOpen")
}
