import AppIntents
import Foundation
import RiverDiaryCore

enum RiverAppActivityTransition: String, AppEnum, CaseIterable, Sendable {
    case opened
    case closed

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "应用活动")
    static var caseDisplayRepresentations: [RiverAppActivityTransition: DisplayRepresentation] = [
        .opened: DisplayRepresentation(title: "打开"),
        .closed: DisplayRepresentation(title: "离开")
    ]
}

struct LogAppActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "记录应用活动"
    static var description = IntentDescription("把用户设置的应用打开或离开事件保存到 River Diary 本机事件库。")
    static var openAppWhenRun = false

    @Parameter(title: "应用名称", description: "例如：微信、Safari 或 ChatGPT")
    var displayName: String

    @Parameter(title: "应用标识", description: "应用的 Bundle Identifier")
    var appIdentifier: String

    @Parameter(title: "活动")
    var transition: RiverAppActivityTransition

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            // 生命周期门禁：未登录且本机还没有资料库时，系统入口不能替用户创建正式库。
            guard RiverLocalDatabase.databaseFileExists() || RiverAccountSessionStore.hasUsablePersistedSession() else {
                throw RiverLocalDatabaseError.sql("请先在 River Diary 登录账号；未绑定账号时不会创建本机资料库。")
            }
            let database = try RiverLocalDatabase(rebuildDerivedProjectionsOnOpen: false)
            _ = try RiverAppActivityRecorder.record(
                displayName: displayName,
                appIdentifier: appIdentifier,
                transition: transition,
                in: database
            )
        }
        return .result()
    }
}

@MainActor
enum RiverAppActivityRecorder {
    @discardableResult
    static func record(
        displayName: String,
        appIdentifier: String,
        transition: RiverAppActivityTransition,
        observedAt: Date = Date(),
        in database: RiverLocalDatabase
    ) throws -> RiverEvent {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = appIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !identifier.isEmpty else {
            throw RiverLocalDatabaseError.sql("请在快捷指令中填写应用名称和 Bundle Identifier。")
        }
        let event = try database.append(
            source: "shortcuts",
            kind: "app.\(transition.rawValue)",
            payload: RiverEventPayload(appName: name, bundleID: identifier),
            observedAt: observedAt
        )
        IPhoneDayContextBuilder.publish(database: database)
        return event
    }
}
