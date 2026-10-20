import Foundation

enum SettingsCategory: String, CaseIterable, Identifiable {
    case account = "账号与权益"
    case recording = "记录与采集"
    case ai = "AI 与模型"
    case privacy = "隐私与备份"
    case appearance = "外观与应用"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .account: "person.crop.circle"
        case .recording: "waveform.path.ecg"
        case .ai: "sparkles"
        case .privacy: "lock.shield"
        case .appearance: "paintbrush"
        }
    }

    /// One line of context for the page header while this section is open.
    var detail: String {
        switch self {
        case .account: "账号登录与高级权益兑换"
        case .recording: "自动记录、采集来源与实时足迹"
        case .ai: "模型连接是可选项，未连接也能使用全部本地记录"
        case .privacy: "信任状态、数据范围、加密备份与应用锁"
        case .appearance: "显示模式与内容密度"
        }
    }
}
