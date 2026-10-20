import AppKit
import SwiftUI

/// 设置页——**整页式**布局，供无边框设置窗口使用。
///
/// 与主窗口共用同一套设计语言，不做"设置专用"外观。左栏刻意与主侧栏同构：
/// 窗口控制 → `SidebarIdentity`（品牌）→ 发丝线 → 分组标签 → 分类行 → 发丝线 →
/// 状态行；分类行的 anatomy 与 `SidebarNavRow` 完全一致
/// （18pt 图标列、`rowTitle` 字重随选中变化、选中态 `accentSoft` 底 + 2.5pt 左侧色条）。
///
/// 右栏是 `RiverHeaderBand` + `PageHeader`（标题为**当前分类名**）+ 各分区的
/// `SettingsPage` 滚动列。标题与内容列共用同一个版心上限与 `AppSpacing.page` 内边距，
/// 保证标题和下面的面板在同一条左基线上。
struct SettingsRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    var databaseStore: V2Store? = nil
    var initialCategory: SettingsCategory = .recording
    var inspectionDate = Date()
    var initiallyShowsDatabase = false
    @State private var databaseDate = Date()
    @State private var databaseInspection: DatabaseInspectionRequest?
    @State private var didApplyInitialNavigation = false

    @State private var settingsSection: SettingsCategory = .recording
    @AppStorage("appearance.mode") private var appearanceModeRaw = RiverAppearance.system.rawValue
    /// 密度必须从 `@AppStorage` 读，而不是用环境注入进来的那份：
    /// 窗口是 AppKit 侧一次性创建的，环境值在开窗那一刻就固定了，
    /// 用它的话"在设置里改密度"要重开窗口才生效。
    @AppStorage("appearance.density") private var densityRaw = RiverDensity.standard.rawValue
    /// 观察配色：切换配色时设置页自己重绘，并把窗口底色同步成新的画布色。
    @ObservedObject private var paletteController = PaletteController.shared

    /// 视图自身与所有子页都用这一份密度，改完立刻生效。
    private var density: RiverDensity {
        RiverDensity(rawValue: densityRaw) ?? .standard
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            settingsRail
                .frame(width: AppLayout.settingsRailWidth)
                .riverAppear(index: 0)

            // 左栏与内容之间用一档更实的发丝线：主题里 sidebar 和 canvas 只差几个
            // 色阶（浅色 #F7FAFD vs #F0F3F8），只靠底色分不出两栏，会显得"一片平"。
            RiverRule(color: Color.strongSeparator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            settingsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .riverAppear(index: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.workspace)
        .onAppear {
            guard !didApplyInitialNavigation else { return }
            didApplyInitialNavigation = true
            settingsSection = initialCategory
            databaseDate = inspectionDate
            if initiallyShowsDatabase && databaseStore != nil {
                databaseInspection = DatabaseInspectionRequest(date: inspectionDate)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .riverSettingsNavigate)) { note in
            if let raw = note.userInfo?["category"] as? String, let category = SettingsCategory(rawValue: raw) {
                settingsSection = category
            }
            let date = note.userInfo?["date"] as? Date ?? databaseDate
            databaseDate = date
            if note.userInfo?["database"] as? Bool == true, databaseStore != nil {
                databaseInspection = DatabaseInspectionRequest(date: date)
            }
        }
        .sheet(item: $databaseInspection) { request in
            if let databaseStore {
                DatabaseInspectionSheet(store: databaseStore, date: request.date, dailyGoal: store.dailyGoal(for: request.date))
            }
        }
        .background(WindowSurfaceColor(paletteID: paletteController.palette.rawValue))
        // 密度与显示模式由本视图自己派生并往下传，而不是沿用开窗时注入的那一份：
        // 否则"在设置里改密度/切深色"要关掉重开才看得到。
        .environment(\.riverDensity, density)
        .preferredColorScheme(appearanceMode.colorScheme)
        // 换配色必须重建这层颜色子树：SwiftUI 会把已解析的调色板颜色缓存住，
        // 单纯重绘（needsDisplay / layer setNeedsDisplay / 注入新环境值）都不会
        // 重新解析 —— 实测只有改变视图身份才行。
        // `.id` 放在 body 内部，`SettingsRedesignView` 自己的 `@State`（当前分类）
        // 保存在父级身份上不会丢，所以切换配色不会再把页面跳回第一个分类。
        .id(paletteController.palette.rawValue)
          // 无边框窗口没有系统关闭按钮，Esc 是键盘用户的关闭路径。
        .onExitCommand {
            SettingsWindowController.shared.currentWindow?.close()
        }
    }

    // MARK: - 左栏

    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部这一行取代原生标题栏。窗口是彻底无边框的（`styleMask` 不含 `.titled`），
            // 系统红黄绿根本不存在，所以这里是唯一的窗口控制。
            WindowControls()
                .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
                .padding(.top, density.spacing(AppSpacing.md))
                .padding(.bottom, density.spacing(AppSpacing.xxs))

            // 品牌身份直接用主侧栏那一个组件：设置窗口不是"另一个应用"，
            // 顶上不该只有光秃秃的"设置"两个字。
            SidebarIdentity(compact: true)

            RiverRule()

            RiverGroupLabel(text: "设置")
                .padding(.horizontal, density.spacing(AppSpacing.panelPadding))
                .padding(.top, density.spacing(10))
                .padding(.bottom, density.spacing(AppSpacing.xxs))

            VStack(alignment: .leading, spacing: density.spacing(1)) {
                ForEach(SettingsCategory.allCases) { item in
                    SettingsRailRow(
                        item: item,
                        isSelected: settingsSection == item
                    ) {
                        settingsSection = item
                    }
                }
            }
            .padding(.horizontal, density.spacing(AppSpacing.sm))

            Spacer(minLength: 0)

            RiverRule()
            railFooter
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 比内容明确低一档的左栏底（见 Theme.swift 的 railSurfaceNSColor）；
        // 直接铺 sidebarSurface 会和 canvas 差不到 4 个色阶，两栏分不出来。
        .background(Color(nsColor: railSurfaceNSColor))
    }

    /// 左栏底部的状态行：和主侧栏 `SidebarFooter` 同一 anatomy（圆点 + 一行小字），
    /// 只是内容换成"设置现在长什么样"——改完立刻能在这里看到结果。
    private var railFooter: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            ForEach(Array(railStatusLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: density.spacing(5)) {
                    Circle()
                        .fill(line.color)
                        .frame(width: 5, height: 5)
                    Text(line.text)
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, density.spacing(AppSpacing.reading))
        .padding(.vertical, density.spacing(9))
    }

    private var railStatusLines: [(color: Color, text: String)] {
        [
            (AppTheme.accent, "配色 · \(paletteController.palette.title)"),
            (Color.tertiaryInk, "外观 · \(appearanceMode.title)"),
            (Color.tertiaryInk, "密度 · \(density.title)")
        ]
    }

    private var appearanceMode: RiverAppearance {
        RiverAppearance(rawValue: appearanceModeRaw) ?? .system
    }

    /// 与主侧栏 `SidebarNavRow` 完全同构的分类行：18pt 图标列、字重随选中
    /// 变化、accentSoft 选中底 + 2.5pt 左侧色条，外加同一档悬停反馈
    /// （`ink.opacity(0.05)`）——两个窗口的导航手感必须一致。
    private struct SettingsRailRow: View {
        @Environment(\.riverDensity) private var density
        let item: SettingsCategory
        let isSelected: Bool
        let action: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button {
                action()
            } label: {
                HStack(spacing: density.spacing(9)) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? AppTheme.accent : Color.secondaryInk)
                        .frame(width: 18)

                    Text(item.rawValue)
                        .font(AppTypography.rowTitle().weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, density.spacing(10))
                .frame(minHeight: AppSpacing.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    isSelected ? AppTheme.accentSoft : (isHovered ? Color.ink.opacity(0.05) : Color.clear),
                    in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                )
                .overlay(alignment: .leading) {
                    if isSelected {
                        Capsule()
                            .fill(AppTheme.accent)
                            .frame(width: 2.5)
                            .padding(.vertical, density.spacing(6))
                            .padding(.leading, density.spacing(1))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel(item.rawValue)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    // MARK: - 右栏

    private var settingsColumn: some View {
        VStack(spacing: 0) {
            // 标题用**当前分类名**，不用"设置"：左栏的分组标签已经是"设置"，
            // 同一个词在 40pt 之内出现两次是纯噪音。
            // 版心与下面的滚动列必须完全对齐（同一个 maxWidth + 同一个 page 内边距），
            // 否则标题贴在左边缘、面板却缩在中间——这是设置页看起来"散"的主因。
            RiverHeaderBand(
                maxWidth: AppLayout.settingsColumnMaxWidth,
                spacing: AppSpacing.sm,
                showsRule: true
            ) {
                PageHeader(settingsSection.rawValue, context: settingsSection.detail)
            }

            settingsContent
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch settingsSection {
        case .account:
            MacAccountSettingsView()
        case .ai:
            AISettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        case .privacy:
            PrivacyBackupSettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        case .appearance:
            AppearanceSettingsView(appearanceModeRaw: $appearanceModeRaw)
        case .recording:
            RecordingSettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion,
                                  onInspectDatabase: databaseStore == nil ? nil : { databaseInspection = DatabaseInspectionRequest(date: databaseDate) })
        }
    }
}

// MARK: - 窗口框体

/// 让设置窗口**没有原生标题栏**。
///
/// 原生标题栏跟着系统材质走，跟应用配色没有关系：浅色下就是一整条白框横在窗口顶上，
/// 和内容完全不是一套颜色（这就是"一整个白框完全出戏"）。把它漆成内容色只是权宜之计——
/// 那条 28pt 的横带依然是系统结构，仍然把窗口切成两段。
///
/// 这里直接不要标题栏：
///
/// 1. `styleMask.remove(.titled)` + `.fullSizeContentView` 移除标题栏结构。
/// 2. **连标准窗口按钮一起隐藏**：只去标题栏时，红黄绿三个按钮仍会浮在内容上方
///    （像素验证：窗口顶部 0–7pt、x=32–143px 有一组暗块就是它们），
///    那正是用户看到的"标题框"。窗口控制改由 `WindowControls` 在左栏顶部承担。
/// 3. `isMovableByWindowBackground = true`：没有标题栏后，拖动窗口靠内容空白处
///    （左栏、内容区留白）完成，这是系统认可的拖动路径。
/// 4. `.resizable` + `minSize`：固定尺寸会让缩放失效，看起来像坏的。
/// 5. `backgroundColor` 与 `isOpaque` 同步成内容画布色，四角不留系统底色。
private struct WindowSurfaceColor: NSViewRepresentable {
    /// 传入配色身份只是为了在换配色时触发一次 `updateNSView`：
    /// 窗口的 `backgroundColor` 是 AppKit 侧的静态颜色，不会随动态色自动重算。
    var paletteID: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { sync(for: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { sync(for: nsView) }
    }

    private func sync(for view: NSView) {
        guard let window = view.window else { return }

        // 单独把标题栏那一条从 styleMask 里摘掉，得到"无标题栏"窗口；
        // `.hiddenTitleBar` 这个 Scene 修饰符在这里用不上（Settings scene 在 App 层声明），
        // 所以直接在 NSWindow 上配置。
        window.styleMask.remove(.titled)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(Color.workspace)
        window.isOpaque = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(
            width: AppLayout.settingsWindowMinWidth,
            height: AppLayout.settingsWindowMinHeight
        )
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        // 窗口尺寸在这里定，而不是靠 SwiftUI 的 `.frame`：
        // Settings 场景会在内容 frame 之外再加 28pt 标题栏空间，那段空白正是
        // 窗口顶部那条删不掉的栏。内容铺满窗口时，窗口多大内容就多大。
        let target = NSSize(
            width: AppLayout.settingsWindowWidth,
            height: AppLayout.settingsWindowHeight
        )
        if window.contentLayoutRect.size != target {
            window.setContentSize(target)
        }

        // 隐藏系统窗口按钮：它们的样式、位置、配色都由系统决定，
        // 放在这个自定义框体里就是"没被设计过的一块"，正是"标题框"的来源。
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }

        window.appearance = view.effectiveAppearance
    }
}

// MARK: - 窗口控制

/// 应用自己的窗口控制，放在左栏顶部，取代被隐藏的系统红黄绿按钮。
///
/// 用系统语义（`performClose` / `miniaturize` / `zoom`）而不是自己关窗口，
/// 这样关闭动画、最小化、缩放的系统行为都还在。
private struct WindowControls: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: Control?

    private enum Control: Hashable { case close, minimize, zoom }

    var body: some View {
        HStack(spacing: 6) {
            dot(.close, color: Color(red: 1.0, green: 0.37, blue: 0.34), symbol: "xmark")
            dot(.minimize, color: Color(red: 1.0, green: 0.74, blue: 0.25), symbol: "minus")
            dot(.zoom, color: Color(red: 0.27, green: 0.79, blue: 0.33), symbol: "arrow.up.left.and.arrow.down.right")
        }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: hovered)
    }

    private func dot(_ control: Control, color: Color, symbol: String) -> some View {
        Button {
            perform(control)
        } label: {
            ZStack {
                Circle().fill(color)
                if hovered != nil {
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 12, height: 12)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? control : (hovered == control ? nil : hovered) }
        .accessibilityLabel(label(for: control))
    }

    private func label(for control: Control) -> String {
        switch control {
        case .close: "关闭窗口"
        case .minimize: "最小化"
        case .zoom: "缩放"
        }
    }

    private func perform(_ control: Control) {
        // 用控制器记住的那扇窗口，而不是 `NSApp.keyWindow`：设置窗口可能不是 key，
        // 那样"关闭"会错误地打在主窗口上。
        guard let window = SettingsWindowController.shared.currentWindow else { return }
        switch control {
        // 无边框窗口没有标准关闭按钮，`performClose` 在 AppKit 里什么也不做，
        // 必须直接 `close()`（`isReleasedWhenClosed = false`，关掉之后还能再打开）。
        case .close: window.close()
        case .minimize: window.miniaturize(nil)
        case .zoom: window.zoom(nil)
        }
    }
}

extension Notification.Name {
    static let riverSettingsNavigate = Notification.Name("river.settings.navigate")
}

private struct DatabaseInspectionSheet: View {
    let store: V2Store
    let date: Date
    let dailyGoal: DailyGoal?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("本地数据检查").font(AppTypography.rowTitle()).foregroundStyle(Color.ink)
                Spacer()
                Button("完成") { dismiss() }.secondaryCTA().keyboardShortcut(.cancelAction)
            }.padding(.horizontal, AppSpacing.page).padding(.vertical, 16)
            RiverRule()
            DatabaseOverviewView(store: store, selectedDate: date, dailyGoal: dailyGoal)
        }.frame(width: 840, height: 620).background(Color.workspace)
    }
}

private struct DatabaseInspectionRequest: Identifiable {
    let id = UUID()
    let date: Date
}
