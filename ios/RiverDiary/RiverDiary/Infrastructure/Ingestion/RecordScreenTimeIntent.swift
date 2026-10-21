import AppIntents
import Foundation
import RiverDiaryCore

/// iOS 不向第三方 App 开放“屏幕使用时间”原始数据。这里用快捷指令记录
/// 用户从“设置 → 屏幕使用时间”看到的当天总分钟数；事件仍先写本机。
struct RecordScreenTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "记录屏幕使用时间"
    static var description = IntentDescription("把今天在“屏幕使用时间”里看到的分钟数保存到 River Diary 本机事件库。")
    static var openAppWhenRun = false

    @Parameter(
        title: "分钟数",
        description: "例如 185。只填今天所有应用加起来的总时长。",
        inclusiveRange: (0, 1_440)
    )
    var minutes: Int

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard RiverLocalDatabase.databaseFileExists() || RiverAccountSessionStore.hasUsablePersistedSession() else {
                throw RiverLocalDatabaseError.sql("请先在 River Diary 登录账号；未绑定账号时不会创建本机资料库。")
            }
            let database = try RiverLocalDatabase(rebuildDerivedProjectionsOnOpen: false)
            _ = try RiverScreenTimeRecorder.record(minutes: minutes, in: database)
        }
        return .result()
    }
}

@MainActor
enum RiverScreenTimeRecorder {
    static let kind = "screenTime.daily"
    static let source = "shortcuts"

    @discardableResult
    static func record(
        minutes: Int,
        observedAt: Date = Date(),
        in database: RiverLocalDatabase
    ) throws -> RiverEvent {
        guard (0...1_440).contains(minutes) else {
            throw RiverLocalDatabaseError.sql("屏幕使用时间需要在 0 到 1440 分钟之间。")
        }
        let payload = RiverEventPayload(metrics: RiverEventMetrics(screenMinutes: minutes))
        let event = try database.append(
            source: source,
            kind: kind,
            payload: payload,
            observedAt: observedAt
        )
        IPhoneDayContextBuilder.publish(database: database)
        return event
    }

    /// 当天最后一条记录。多次运行以最新一条为准；不把多次输入相加，
    /// 因为用户填的是“当天总时长”，不是增量。
    static func latestMinutes(
        on day: Date = Date(),
        in database: RiverLocalDatabase
    ) -> Int? {
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start),
              let events = try? database.allEvents() else { return nil }
        return events
            .filter { $0.kind == kind && $0.observedAt >= start && $0.observedAt < end }
            .compactMap { event -> (Date, Int)? in
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload),
                      let minutes = payload.metrics?.screenMinutes else { return nil }
                return (event.recordedAt, minutes)
            }
            .max { $0.0 < $1.0 }?
            .1
    }
}

struct RiverDiaryAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogAppActivityIntent(),
            phrases: ["记录应用活动到 \(.applicationName)"],
            shortTitle: "记录应用活动",
            systemImageName: "app.badge"
        )
        AppShortcut(
            intent: RecordScreenTimeIntent(),
            phrases: ["记录屏幕使用时间到 \(.applicationName)"],
            shortTitle: "记录屏幕使用时间",
            systemImageName: "hourglass"
        )
        AppShortcut(
            intent: RecordVoiceMemoIntent(),
            phrases: ["记录语音速记到 \(.applicationName)"],
            shortTitle: "记录语音速记",
            systemImageName: "mic"
        )
    }
}
