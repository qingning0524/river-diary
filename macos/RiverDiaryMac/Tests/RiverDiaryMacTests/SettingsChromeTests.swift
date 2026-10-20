import XCTest
@testable import RiverDiaryMac

/// 设置窗口的"框体契约"。
///
/// 窗口是彻底无边框的（`styleMask` 不含 `.titled`），系统红黄绿**不存在**，
/// 窗口控制由左栏顶部的 `WindowControls` 自绘，所以不再需要"给系统按钮留净空"。
/// 这里守卫的是版心与窗口尺寸之间的自洽关系。
final class SettingsChromeTests: XCTestCase {

    /// 标题与内容列必须共用同一个版心上限 —— 否则标题贴左边缘、面板缩在中间。
    func testHeaderAndContentShareTheSameMeasure() throws {
        let view = try source("Views/SettingsRedesignView.swift")
        XCTAssertTrue(
            view.contains("maxWidth: AppLayout.settingsColumnMaxWidth"),
            "设置页标题栏没有使用与内容列相同的版心上限：标题会和面板错开"
        )
        let panels = try source("Views/Panels.swift")
        XCTAssertTrue(
            panels.contains("var maxWidth: CGFloat = AppLayout.settingsColumnMaxWidth"),
            "SettingsPage 的默认版心不是 settingsColumnMaxWidth：标题和内容会对不齐"
        )
    }

    /// 默认窗口宽度下，内容列正好铺满版心（不多不少）。
    func testContentColumnFillsTheDefaultWindow() {
        let available = AppLayout.settingsWindowWidth
            - AppLayout.settingsRailWidth
            - 1
            - AppSpacing.page * 2
        XCTAssertLessThanOrEqual(
            AppLayout.settingsColumnMaxWidth, available,
            "版心比可用宽度还大，内容会被裁掉"
        )
        XCTAssertGreaterThan(
            AppLayout.settingsColumnMaxWidth, available - 40,
            "版心明显小于可用宽度，默认尺寸下右侧会留出一条空带"
        )
    }

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/RiverDiaryMac")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testSettingsWindowIsLargerThanItsMinimum() {
        XCTAssertGreaterThan(AppLayout.settingsWindowWidth, AppLayout.settingsWindowMinWidth)
        XCTAssertGreaterThan(AppLayout.settingsWindowHeight, AppLayout.settingsWindowMinHeight)
    }

    func testSettingsContentColumnFitsBesideTheRail() {
        // 设置窗口没有原生标题栏，顶部那条横带也不该存在，
        // 所以窗口宽度只需容纳：左栏 + 1pt 发丝线 + 内容列版心。
        let available = AppLayout.settingsWindowWidth
            - AppLayout.settingsRailWidth
            - 1
        XCTAssertGreaterThan(
            available, AppLayout.settingsColumnMaxWidth,
            "内容列版心放不进窗口：窗口太窄或版心太宽"
        )
    }

    func testRailIsNarrowerThanTheMainSidebar() {
        // 设置窗口不是主窗口：左栏要比主侧栏更紧凑，否则在设置窗口里显得笨重。
        XCTAssertLessThan(AppLayout.settingsRailWidth, AppLayout.sidebarWidth)
    }
}

/// 左栏区分度：把 `ink` 压进 `sidebar` 的配方比例。
extension SettingsChromeTests {
    func testRailBlendIsVisibleButNotHeavy() {
        XCTAssertGreaterThanOrEqual(
            settingsRailBlendAmount, 0.04,
            "压得太浅，左栏和内容区会糊成一片（这正是最初的毛病）"
        )
        // 2026-09-26：上限 0.12 → 0.16。页面画布整体压深（#F0F3F8 → #EAEDF2）之后，
        // 原来的 0.07 正好落在画布上，必须提到 0.13 才拉得开；上限跟着放宽一档，
        // 真正的把关交给 SettingsRailContrastTests（逐套配色验证色阶差 ≥ 8）。
        XCTAssertLessThanOrEqual(
            settingsRailBlendAmount, 0.16,
            "压得太重，左栏会像一块压下来的重色"
        )
    }
}

/// 配色刷新的位置守卫。
///
/// 实测结论（探针程序验证）：SwiftUI 会缓存已解析的调色板颜色，
/// `needsDisplay` / `layer.setNeedsDisplay` / `displayIfNeeded` / 注入新环境值
/// 都**不会**让它重新解析，只有改变视图身份（`.id`）才会。
///
/// 但 `.id` 的位置决定了用户会不会"跳页"：
/// - 放在窗口根视图的 **body 内部**：视图自身的 `@State`（当前分类、当前页面、
///   Inspector、编辑器草稿）保存在父级身份上不会丢，只是颜色子树重建 → 正确；
/// - 放在 `riverAppEnvironment` 里（由窗口控制器包在视图**外面**）：会连
///   视图自身的 `@State` 一起重建 → 设置页跳回第一个分类。
final class PaletteSwitchStabilityTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/RiverDiaryMac")
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `.id(palette…)` 必须同时存在于两个窗口的根视图 body 里。
    func testBothWindowRootsRebuildTheirColorSubtree() throws {
        let settings = try source("Views/SettingsRedesignView.swift")
        XCTAssertTrue(
            settings.contains(".id(paletteController.palette.rawValue)"),
            "设置窗口根视图缺少 .id(palette)：切换配色时颜色不会刷新"
        )

        let shell = try source("Views/RiverShell.swift")
        XCTAssertTrue(
            shell.contains(".id(paletteController.palette.rawValue)"),
            "主窗口根视图缺少 .id(palette)：切换配色时颜色不会刷新"
        )
    }

    /// `.id(palette…)` 不能出现在 app 级环境修饰符里（那会重建视图自身的 @State）。
    func testPaletteIdentityIsNotBoundAboveTheWindowRoot() throws {
        let design = try source("Design/DesignSystem.swift")
        let modifier = design.components(separatedBy: "struct RiverAppEnvironment").last ?? ""
        let body = modifier.components(separatedBy: "extension View").first ?? modifier
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".id("), line.lowercased().contains("palette") else { continue }
            XCTFail("riverAppEnvironment 里出现 .id(palette)：会把视图自身的 @State 一起重建，导致跳页")
        }
    }

    /// 主窗口里的 `.id(palette…)` 必须排在 `.onAppear` **之前**。
    ///
    /// 排在后面的话，`onAppear` 会被一起重建并重新触发 —— 那会重复执行
    /// `ingestion.start()`、并把已解锁的应用重新锁上。实测 `.id` 在前时
    /// `onAppear` 不会重跑。
    func testShellPaletteIdentityComesBeforeLifecycleSideEffects() throws {
        let shell = try source("Views/RiverShell.swift")
        guard let idRange = shell.range(of: ".id(paletteController.palette.rawValue)"),
              let appearRange = shell.range(of: ".onAppear {") else {
            return XCTFail("找不到 .id(palette) 或 .onAppear")
        }
        XCTAssertLessThan(
            idRange.lowerBound, appearRange.lowerBound,
            "`.id(palette)` 必须排在 `.onAppear` 之前，否则 onAppear 会随重建重新触发"
        )
    }
}
