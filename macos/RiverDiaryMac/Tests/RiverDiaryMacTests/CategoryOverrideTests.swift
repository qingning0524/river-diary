import XCTest

@testable import RiverDiaryMac

/// 应用 → 类别 的人工映射。
///
/// 背景：关键词分类器认不出本机的主力应用（17 天 2378 段里专注类前台合计只有
/// 4 分钟），"专注"因此恒为空。映射是**读时推导**：原始文件与 V2 证据不回写，
/// 指认一次全历史生效，撤销后按 应用名+标题 重新推导——这要求"删映射能干净
/// 地回到自动分类"，而不是留在上一次写进文件的旧类别上。
@MainActor
final class CategoryOverrideTests: XCTestCase {

    private var directory: URL!
    private var preferences: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-category-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "river-category-\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suiteName)
        preferences.set(false, forKey: "activity.enabled")
    }

    override func tearDownWithError() throws {
        preferences.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() -> ActivityStore {
        ActivityStore(
            activityDirectory: directory.appendingPathComponent("Activity"),
            userDefaults: preferences,
            v2Store: V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
        )
    }

    private func session(app: String, bundle: String, title: String?, category: String, minutes: Double) -> ActivitySession {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return ActivitySession(
            appName: app, bundleID: bundle, windowTitle: title,
            category: category, start: start,
            end: start.addingTimeInterval(minutes * 60)
        )
    }

    func testOverrideCorrectsHistoryAndSurvivesAReload() throws {
        let store = makeStore()
        // 关键词分类器把 Zed 判成"其他"（它不在词表里）；文件里存的也是"其他"。
        try store.restoreBackup([session(
            app: "Zed", bundle: "dev.zed.Zed", title: nil, category: "其他", minutes: 40
        )])
        XCTAssertEqual(store.sessions.first?.category, "其他")

        store.setCategoryOverride("工作", forBundleID: "dev.zed.Zed")
        XCTAssertEqual(store.sessions.first?.category, "工作", "指认一次，全部历史立即生效")

        // 持久化 + 新实例（同一 suite）加载后仍然生效。
        XCTAssertTrue(preferences.dictionary(forKey: "activity.categoryOverrides")?.keys.contains("dev.zed.zed") == true,
                      "映射按小写 bundleID 持久化")
        let reloaded = makeStore()
        XCTAssertEqual(reloaded.sessions.first?.category, "工作")
    }

    func testRemovingOverrideFallsBackToTitleDerivedCategory() throws {
        let store = makeStore()
        // 文件里存的类别是记录当时的旧词表结果；标题里有 github，自动分类
        // 现在能把它归入"工作"。
        try store.restoreBackup([session(
            app: "Chrome", bundle: "test.Chrome", title: "github.com/river/diary — Pull requests",
            category: "浏览", minutes: 30
        )])
        store.setCategoryOverride("学习", forBundleID: "test.Chrome")
        XCTAssertEqual(store.sessions.first?.category, "学习")

        store.setCategoryOverride(nil, forBundleID: "test.Chrome")
        XCTAssertEqual(
            store.sessions.first?.category, "工作",
            "撤销映射要按 应用名+标题 重新推导，而不是留在上一次写盘的旧类别上"
        )
    }

    func testNoOverrideLeavesDerivedCategoriesAlone() throws {
        let store = makeStore()
        let original = session(app: "Chrome", bundle: "test.Chrome", title: nil, category: "浏览", minutes: 10)
        try store.restoreBackup([original])
        XCTAssertEqual(store.sessions.first?.category, "浏览")
        XCTAssertNil(store.categoryOverride(forBundleID: "test.Chrome"))
        XCTAssertEqual(store.categoryAppOptions().first?.bundleID, "test.chrome")
    }

    func testAppOptionsSortByDurationAndDeduplicateByBundle() throws {
        let store = makeStore()
        try store.restoreBackup([
            session(app: "Chrome", bundle: "test.Chrome", title: nil, category: "浏览", minutes: 50),
            session(app: "Zed", bundle: "test.Zed", title: nil, category: "其他", minutes: 90),
            session(app: "Zed", bundle: "test.Zed", title: nil, category: "其他", minutes: 10)
        ])
        let options = store.categoryAppOptions()
        XCTAssertEqual(options.map(\.appName), ["Zed", "Chrome"], "按时长降序")
        XCTAssertEqual(options.map(\.duration), [100 * 60, 50 * 60], "同 bundle 的时长合并")
    }

    /// 映射不写回原始证据：证据层（V2 原始事件）根本没有类别字段——它只存
    /// 应用、bundle 与标题；类别是投影与展示层的解释。解释可以变，证据不变。
    func testOverrideDoesNotTouchTheEvidenceStore() throws {
        let store = makeStore()
        let original = session(app: "Zed", bundle: "dev.zed.Zed", title: nil, category: "其他", minutes: 20)
        try store.restoreBackup([original])
        store.setCategoryOverride("工作", forBundleID: "dev.zed.Zed")
        XCTAssertEqual(store.sessions.first?.category, "工作")

        let facts = V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
        let events = facts.rawEvents(between: original.start.addingTimeInterval(-60), end: original.end.addingTimeInterval(60))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload.bundleID, "dev.zed.Zed")
        XCTAssertNil(events.first?.payload.text)
        XCTAssertFalse(
            "\(events.first?.payload as Any)".contains("工作"),
            "证据事件里不携带任何类别解释"
        )
    }
}
