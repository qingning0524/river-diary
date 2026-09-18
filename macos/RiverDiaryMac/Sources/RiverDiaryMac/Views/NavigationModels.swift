import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable {
    case today, time, memory, insight, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "日记"
        case .time: "时间线"
        case .memory: "记忆"
        case .insight: "洞察"
        case .system: "设置"
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
        case .today: "book.closed"
        case .time: "point.3.connected.trianglepath.dotted"
        case .memory: "sparkle.magnifyingglass"
        case .insight: "brain.head.profile"
        case .system: "gearshape"
        }
    }

    var shortcutNumber: Int {
        Array(AppDestination.allCases).firstIndex(of: self)! + 1
    }
}

enum TimeSection: String, CaseIterable, Identifiable {
    case river, rhythm, activity

    static let displayOrder: [TimeSection] = [.activity, .river, .rhythm]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .river: "情绪河"
        case .rhythm: "节律"
        case .activity: "时间线"
        }
    }
}

enum SystemSection: String, CaseIterable, Identifiable {
    case controls, data

    var id: String { rawValue }

    var title: String {
        switch self {
        case .controls: "偏好设置"
        case .data: "高级数据"
        }
    }
}
