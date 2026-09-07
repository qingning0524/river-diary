import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case record, timeline, memory, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "记录"
        case .timeline: "时间"
        case .memory: "记忆"
        case .control: "控制"
        }
    }

    var destinations: [NavigationDestination] {
        switch self {
        case .record: [.today]
        case .timeline: [.river, .rhythm, .activity, .dataExplorer]
        case .memory: [.aiAnalysis, .memorySearch, .memoryInsight, .memoryNotes]
        case .control: [.privacy]
        }
    }
}

enum NavigationDestination: String, CaseIterable, Identifiable {
    case today
    case river
    case rhythm
    case activity
    case dataExplorer
    case aiAnalysis
    case memorySearch
    case memoryInsight
    case memoryNotes
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "主页"
        case .river: "河流"
        case .rhythm: "节律"
        case .activity: "足迹"
        case .dataExplorer: "数据库"
        case .aiAnalysis: "AI 分析"
        case .memorySearch: "回忆搜索"
        case .memoryInsight: "状态"
        case .memoryNotes: "随笔"
        case .privacy: "设置"
        }
    }

    var icon: String {
        switch self {
        case .today: "sparkles"
        case .river: "drop.fill"
        case .rhythm: "chart.dots.scatter"
        case .activity: "waveform.path.ecg"
        case .dataExplorer: "externaldrive"
        case .aiAnalysis: "sparkles.rectangle.stack"
        case .memorySearch: "magnifyingglass"
        case .memoryInsight: "brain.head.profile"
        case .memoryNotes: "note.text"
        case .privacy: "lock.shield"
        }
    }

    var memorySection: MemorySection? {
        switch self {
        case .memorySearch: .search
        case .memoryInsight: .insight
        case .memoryNotes: .notes
        default: nil
        }
    }
}
