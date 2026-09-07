import Foundation

enum AITask: String {
    case dailyOverview
    case footprintQuestion
    case insightReading
    case memorySearch
    case riverReading
    case noteThemes
    case analysisDaily
    case analysisMood
    case analysisFocus
    case analysisHealth
    case analysisWeekly
    case analysisAction

    var title: String {
        switch self {
        case .dailyOverview: "AI 本日整理"
        case .footprintQuestion: "AI 足迹问答"
        case .insightReading: "AI 状态洞察"
        case .memorySearch: "AI 回忆搜索"
        case .riverReading: "AI 情绪河流"
        case .noteThemes: "AI 快记归纳"
        case .analysisDaily: "每日总结"
        case .analysisMood: "情绪关联"
        case .analysisFocus: "专注分析"
        case .analysisHealth: "健康恢复"
        case .analysisWeekly: "本周规律"
        case .analysisAction: "行动建议"
        }
    }

    var analysisIcon: String {
        switch self {
        case .analysisDaily: "sun.max.fill"
        case .analysisMood: "heart.circle.fill"
        case .analysisFocus: "scope"
        case .analysisHealth: "leaf.fill"
        case .analysisWeekly: "calendar.badge.clock"
        case .analysisAction: "lightbulb.fill"
        default: "sparkles"
        }
    }

    var analysisColor: String {
        switch self {
        case .analysisDaily: "#7C5CFC"
        case .analysisMood: "#F06292"
        case .analysisFocus: "#42A5F5"
        case .analysisHealth: "#66BB6A"
        case .analysisWeekly: "#FFA726"
        case .analysisAction: "#26C6DA"
        default: "#7787FF"
        }
    }

    var analysisSubtitle: String {
        switch self {
        case .analysisDaily: "把今天的数据变成一段有温度的叙述"
        case .analysisMood: "找出情绪变化和活动之间的关联"
        case .analysisFocus: "分析专注模式和碎片化程度"
        case .analysisHealth: "睡眠、运动与恢复的关系"
        case .analysisWeekly: "过去一周的规律和趋势"
        case .analysisAction: "基于数据给出明日建议"
        default: ""
        }
    }
}

struct AITaskState: Identifiable {
    var id: String { task.rawValue }
    var task: AITask
    var isLoading = false
    var answer: String?
    var error: String?
    var updatedAt: Date?
    var isArchived = false
}

struct AIProfile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var provider: AIProvider
    var endpoint: String
    var model: String

    init(
        id: String = UUID().uuidString,
        name: String,
        provider: AIProvider,
        endpoint: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.endpoint = endpoint ?? provider.defaultEndpoint
        self.model = model ?? provider.defaultModel
    }
}

struct AIRequestRecord: Codable {
    var date: Date
    var provider: String
    var model: String
    var success: Bool
    var message: String
}

struct AIChatMessage: Codable {
    var role: String
    var content: String
}

struct AIChatRequest: Codable {
    var model: String
    var messages: [AIChatMessage]
    var temperature: Double
    var stream: Bool
}

struct AIModelListResponse: Codable {
    struct Model: Codable {
        var id: String?
    }

    var `data`: [Model]?
}

struct AIChatResponse: Codable {
    struct Choice: Codable {
        struct Message: Codable {
            var content: String?
        }

        var message: Message?
    }

    struct APIError: Codable {
        var message: String?
    }

    var choices: [Choice]?
    var error: APIError?
}

struct AIAppUsageContext: Codable {
    var name: String
    var minutes: Int
    var category: String
    var source: String
}

struct AIBrowseContext: Codable {
    var site: String
    var visits: Int
}

struct AIHourContext: Codable {
    var hour: Int
    var minutes: Int
    var primaryCategory: String
}

struct AIHealthContext: Codable {
    var steps: Int
    var distanceKM: Double
    var activeEnergyKcal: Double
}

struct AIDayContext: Codable {
    var date: String
    var screenMinutes: Int
    var liveMinutes: Int
    var focusMinutes: Int
    var steps: Int
    var mood: Int?
    var energy: Int?
    var focusScore: Int?
    var outputScore: Int?
    var topApps: [String]
}

struct AISessionContext: Codable {
    var app: String
    var category: String
    var start: String
    var minutes: Int
    var title: String?
}

struct AIAnalysisContext: Codable {
    var scope: String
    var days: Int
    var pipelineTotalMinutes: Int
    var liveTotalMinutes: Int
    var focusTotalMinutes: Int
    var fragmentation: Int
    var confidence: Int
    var apps: [AIAppUsageContext]
    var categories: [AIAppUsageContext]
    var browse: [AIBrowseContext]
    var timeline: [AIHourContext]
    var health: AIHealthContext
    var daily: [AIDayContext]
    var recentSessions: [AISessionContext]?
}

struct AIRequestPayload {
    var question: String
    var context: AIAnalysisContext
}
