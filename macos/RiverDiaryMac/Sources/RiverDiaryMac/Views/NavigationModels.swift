import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case today, time, memory, insight, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今天"
        case .time: "时间"
        case .memory: "记忆"
        case .insight: "洞察"
        case .system: "系统"
        }
    }

    var caption: String {
        switch self {
        case .today: "今天怎么样，现在记一点"
        case .time: "过去发生了什么"
        case .memory: "找回以前的字句和感受"
        case .insight: "从记录里得到理解和建议"
        case .system: "管理数据、AI 和隐私"
        }
    }

    var icon: String {
        switch self {
        case .today: "sunrise.fill"
        case .time: "clock.badge.checkmark"
        case .memory: "sparkle.magnifyingglass"
        case .insight: "brain.head.profile"
        case .system: "switch.2"
        }
    }

    var shortcutNumber: Int {
        Array(AppDestination.allCases).firstIndex(of: self)! + 1
    }
}

enum TimeSection: String, CaseIterable, Identifiable {
    case river, rhythm, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .river: "情绪河"
        case .rhythm: "节律"
        case .activity: "足迹"
        }
    }
}

enum SystemSection: String, CaseIterable, Identifiable {
    case controls, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controls: "隐私与备份"
        case .data: "高级数据"
        }
    }
}
