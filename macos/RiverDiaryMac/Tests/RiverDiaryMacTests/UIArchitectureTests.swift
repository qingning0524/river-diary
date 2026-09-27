import XCTest
@testable import RiverDiaryMac

final class UIArchitectureTests: XCTestCase {
    func testNavigationHasStableWorkspaceDestinations() {
        // `settings` 不再是工作区目的地：设置只有原生设置窗口这一种形态
        // （⌘,、侧栏入口、菜单项、命令面板都打开同一个窗口），
        // 避免"两处入口、一个视图、两种行为"。
        XCTAssertEqual(
            RiverDestination.allCases.map(\.rawValue),
            ["today", "timeline", "dailyReview", "habitReview", "health", "footprints", "workLearn", "memory", "ask", "progress", "database", "sources"]
        )
        XCTAssertFalse(
            RiverDestination.allCases.contains { $0.rawValue == "settings" },
            "设置不应再作为可切换的工作区页面存在"
        )
    }

    func testEveryWorkspaceHasADiscoverableUniqueKeyboardShortcut() {
        let shortcuts = RiverDestination.allCases.map(\.navigationShortcut.label)
        XCTAssertEqual(
            shortcuts,
            ["⌘1", "⌘4", "⌘5", "⌘⇧R", "⌘6", "⌘7", "⌘8", "⌘2", "⌘3", "⌘9", "⌘0", "⌘⇧D"]
        )
        XCTAssertEqual(Set(shortcuts).count, RiverDestination.allCases.count)
    }

    func testDesignTokensStayOnTheSharedScale() {
        XCTAssertEqual(AppSpacing.xs, 4)
        XCTAssertEqual(AppSpacing.sm, 8)
        XCTAssertEqual(AppSpacing.md, 12)
        XCTAssertEqual(AppRadius.marker, 3)
        XCTAssertEqual(AppRadius.control, 9)
        XCTAssertLessThan(AppRadius.marker, AppRadius.control)
        XCTAssertLessThan(AppRadius.control, AppRadius.row)
        XCTAssertLessThan(AppRadius.row, AppRadius.panel)
        XCTAssertLessThan(AppRadius.panel, AppRadius.floating)
        XCTAssertLessThan(AppMotion.quick, AppMotion.standard)
    }

    func testAppearanceOffersSystemLightAndDarkModes() {
        XCTAssertEqual(RiverAppearance.allCases.map(\.title), ["跟随系统", "浅色", "深色"])
        XCTAssertNil(RiverAppearance.system.colorScheme)
        XCTAssertEqual(RiverAppearance.light.colorScheme, .light)
        XCTAssertEqual(RiverAppearance.dark.colorScheme, .dark)
        XCTAssertEqual(RiverDensity.standard.spacing(20), 20)
        XCTAssertEqual(RiverDensity.compact.spacing(20), 16.8, accuracy: 0.001)
    }

    /// Categories share one accent on purpose; only system noise steps down to the
    /// neutral tone. These hexes must track the `--accent` / `--tertiary-ink` tokens.
    func testActivityCategoriesUseTheEvidenceDeskAccent() {
        XCTAssertEqual(ActivityClassifier.color(for: "工作"), "#3E74DC")
        XCTAssertEqual(ActivityClassifier.color(for: "娱乐"), "#3E74DC")
        XCTAssertEqual(ActivityClassifier.color(for: "系统"), "#94A0B0")
    }

    func testZeroDurationIsNotPresentedAsARecordedSubminuteActivity() {
        XCTAssertEqual(ActivityFormatter.time(0), "0 分钟")
        XCTAssertEqual(ActivityFormatter.time(-1), "0 分钟")
        XCTAssertEqual(ActivityFormatter.time(59), "不到 1 分钟")
    }

    func testSameMinuteTimelineRangeIncludesSeconds() {
        let calendar = Calendar.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22))!
        let start = calendar.date(bySettingHour: 9, minute: 15, second: 12, of: day)!
        let end = calendar.date(bySettingHour: 9, minute: 15, second: 42, of: day)!

        XCTAssertEqual(
            ActivityFormatter.timeRange(start, end),
            "\(start.formatted(.dateTime.hour().minute().second()))–\(end.formatted(.dateTime.hour().minute().second()))"
        )
    }

    @MainActor
    func testFeedbackCenterPublishesAnActionMessage() {
        let center = FeedbackCenter()
        center.show("已保存", kind: .success)
        XCTAssertEqual(center.message?.text, "已保存")
        XCTAssertEqual(center.message?.kind, .success)
    }

    func testMemoryPresentationUsesOneQueryAcrossDurableMemories() {
        let memories = [
            Memory(title: "工作节奏", body: "专注在早晨"),
            Memory(title: "旅行", body: "海边")
        ]
        XCTAssertEqual(MemoryPresentation.durableMemories(memories, query: " 工作 ").map(\.title), ["工作节奏"])
        XCTAssertEqual(MemoryPresentation.normalized(" 过去 "), "过去")
    }

    func testMemoryFavoritesIsAnExplicitScope() {
        XCTAssertTrue(MemoryScope.allCases.contains(.favorites))
        XCTAssertEqual(MemoryScope.favorites.title, "收藏")
        XCTAssertEqual(MemoryPresentation.sections(for: .favorites), [.reflections, .archive])
    }

    func testMemoryPresentationFiltersFavoriteReflections() {
        let now = Date()
        let letters = [
            MonthlyLetter(month: "2026-09", title: "喜欢的信", body: "工作", evidence: "依据", createdAt: now, updatedAt: now, isFavorite: true),
            MonthlyLetter(month: "2026-08", title: "普通的信", body: "工作", evidence: "依据", createdAt: now, updatedAt: now, isFavorite: false)
        ]
        let result = MemoryPresentation.reflections(letters, scope: .favorites, query: "工作")
        XCTAssertEqual(result.map(\.title), ["喜欢的信"])
    }

    func testMemoryPresentationMapsEveryScopeToExpectedSections() {
        XCTAssertEqual(MemoryPresentation.sections(for: .all), [.durable, .reflections, .archive])
        XCTAssertEqual(MemoryPresentation.sections(for: .durable), [.durable])
        XCTAssertEqual(MemoryPresentation.sections(for: .reflections), [.reflections])
        XCTAssertEqual(MemoryPresentation.sections(for: .archive), [.archive])
    }

    @MainActor
    func testQuickCaptureRejectsBlankInputBeforePersistence() {
        let store = DiaryStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("river-quick-capture-\(UUID().uuidString)", isDirectory: true))
        XCTAssertFalse(store.addQuickCapture("   "))
    }

    @MainActor
    func testQuickCaptureReportsSuccessfulPersistence() {
        let store = DiaryStore(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("river-quick-capture-success-\(UUID().uuidString)", isDirectory: true))
        XCTAssertTrue(store.addQuickCapture("一条测试快记"))
        XCTAssertTrue(store.quickCaptures.values.flatMap { $0 }.contains(where: { $0.text == "一条测试快记" }))
    }

    func testSettingsCategoriesHaveStableRoutes() {
        XCTAssertEqual(SettingsCategory.allCases.map(\.rawValue), ["记录与采集", "AI 与模型", "隐私与备份", "外观与应用"])
    }

    func testAIConnectionIsClearlyOptionalAndNeverBlocksStartup() {
        XCTAssertTrue(AIConnectionCopy.setupGuidance.contains("模型连接为可选"))
        XCTAssertFalse(AIConnectionCopy.setupGuidance.contains("强制"))
        XCTAssertFalse(AIConnectionCopy.setupGuidance.contains("首次启动"))
    }
}
