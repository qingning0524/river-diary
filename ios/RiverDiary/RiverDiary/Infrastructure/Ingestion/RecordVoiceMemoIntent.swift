import AppIntents
import Foundation
import RiverDiaryCore

/// 语音速记走 Shortcuts 的“听写文本”，本 App 只接收转写后的文字。
/// 不申请麦克风/语音识别权限，也不保存音频；这条边界要在设置里写清楚。
struct RecordVoiceMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "记录语音速记"
    static var description = IntentDescription("把快捷指令听写出的文字保存到 River Diary 本机事件库。")
    static var openAppWhenRun = false

    @Parameter(title: "转写文本", description: "快捷指令“听写文本”的输出")
    var text: String

    func perform() async throws -> some IntentResult {
        try await MainActor.run {
            guard RiverLocalDatabase.databaseFileExists() || RiverAccountSessionStore.hasUsablePersistedSession() else {
                throw RiverLocalDatabaseError.sql("请先在 River Diary 登录账号；未绑定账号时不会创建本机资料库。")
            }
            let database = try RiverLocalDatabase(rebuildDerivedProjectionsOnOpen: false)
            _ = try RiverVoiceMemoRecorder.record(text: text, in: database)
        }
        return .result()
    }
}

@MainActor
enum RiverVoiceMemoRecorder {
    static let kind = "manual.voiceMemo"
    static let source = "shortcuts"

    @discardableResult
    static func record(
        text: String,
        observedAt: Date = Date(),
        in database: RiverLocalDatabase
    ) throws -> RiverEvent {
        guard let normalized = VoiceMemoReading.normalizedText(text) else {
            throw RiverLocalDatabaseError.sql("语音速记没有可保存的文字。")
        }
        let event = try database.append(
            source: source,
            kind: kind,
            payload: RiverEventPayload(text: normalized),
            observedAt: observedAt
        )
        IPhoneDayContextBuilder.publish(database: database)
        return event
    }
}
