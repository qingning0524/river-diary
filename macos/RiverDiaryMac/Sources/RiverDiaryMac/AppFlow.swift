import SwiftUI

enum AppFlow: String, CaseIterable, Identifiable {
    case today, rhythm, memory, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .rhythm: "节律"
        case .memory: "记忆"
        case .settings: "设置"
        }
    }

    var caption: String {
        switch self {
        case .today: "写一段，看清此刻"
        case .rhythm: "身体、屏幕与专注"
        case .memory: "找回散落的感受"
        case .settings: "掌控数据与隐私"
        }
    }

    var icon: String {
        switch self {
        case .today: "sunrise.fill"
        case .rhythm: "waveform.path.ecg"
        case .memory: "sparkle.magnifyingglass"
        case .settings: "switch.2"
        }
    }

    var accent: String {
        switch self {
        case .today: "#4E8CFF"
        case .rhythm: "#2C8158"
        case .memory: "#B05CCF"
        case .settings: "#7A7A7A"
        }
    }
}
