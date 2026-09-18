import Foundation

enum AITask: String, Codable {
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

    static let analysisSuite: [AITask] = [
        .analysisDaily,
        .analysisMood,
        .analysisFocus,
        .analysisHealth,
        .analysisWeekly,
        .analysisAction
    ]

    var isAnalysisSuiteTask: Bool {
        Self.analysisSuite.contains(self)
    }

    var title: String {
        switch self {
        case .dailyOverview: "AI 本日整理"
        case .footprintQuestion: "AI 足迹问答"
        case .insightReading: "AI 状态洞察"
        case .memorySearch: "AI 搜索"
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
    var sourceSummary: String? = nil
    var model: String? = nil
}

struct InsightRequest: Codable, Hashable, Identifiable {
    var id: String { "\(task.rawValue)|\(startDate ?? "")|\(endDate ?? "")" }
    var task: AITask
    var startDate: String?
    var endDate: String?
    var sourceSummary: String
    var createdAt: Date
}

struct InsightResult: Codable, Hashable, Identifiable {
    var id: String { resultKey }
    var resultKey: String
    var startDate: String
    var endDate: String
    var task: AITask
    var model: String
    var answer: String
    var sourceSummary: String
    var createdAt: Date
    var isLocal: Bool
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
    var maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
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

enum AISearchAnswerFormatter {
    private static let headingAliases: [(String, String)] = [
        ("【结论】", "**结论**"),
        ("【相关日期】", "**相关日期**"),
        ("【证据】", "**证据**"),
        ("【边界】", "**边界**"),
        ("## 结论", "**结论**"),
        ("## 相关日期", "**相关日期**"),
        ("## 证据", "**证据**"),
        ("## 边界", "**边界**")
    ]

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (alias, heading) in headingAliases {
            text = text.replacingOccurrences(of: alias, with: heading)
        }
        text = text.replacingOccurrences(
            of: "\\*\\*(结论|相关日期|证据|边界)\\*\\*[：:]\\s*",
            with: "**$1**\n",
            options: .regularExpression
        )

        let requiredHeadings = ["**结论**", "**相关日期**", "**证据**", "**边界**"]
        guard requiredHeadings.allSatisfy({ text.contains($0) }) else {
            return """
            **结论**
            \(text)

            **相关日期**
            请以结论和证据中的完整日期为准。

            **证据**
            原回答没有按标准结构列出证据。

            **边界**
            本次内容只基于本机检索到的历史记录，相关性不代表因果关系。如果你想，可以重新搜索。
            """
        }
        return text
    }
}

enum AIAnalysisAnswerFormatter {
    private static let aliases: [(String, String)] = [
        ("【结论】", "**结论**"),
        ("【关键依据】", "**关键依据**"),
        ("【建议】", "**建议**"),
        ("【边界】", "**边界**"),
        ("**核心发现**", "**结论**"),
        ("**概览**", "**结论**"),
        ("**整体趋势**", "**结论**"),
        ("**具体线索**", "**关键依据**"),
        ("**行动建议**", "**建议**")
    ]

    static func normalize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (alias, heading) in aliases {
            text = text.replacingOccurrences(of: alias, with: heading)
        }
        text = text.replacingOccurrences(
            of: "\\*\\*(结论|关键依据|建议|边界)\\*\\*[：:]\\s*",
            with: "**$1**\n",
            options: .regularExpression
        )

        let headings = ["**结论**", "**关键依据**", "**建议**", "**边界**"]
        if !text.contains("**结论**") {
            text = "**结论**\n" + text
        }
        if !text.contains("**关键依据**") {
            text += "\n\n**关键依据**\n当前回答没有单独列出依据，请结合本卡片的来源摘要查看。"
        }
        if !text.contains("**建议**") {
            text += "\n\n**建议**\n如果你想，可以从最小的一步开始。"
        }
        if !text.contains("**边界**") {
            text += "\n\n**边界**\n只基于当前所选范围内已有记录，相关性不代表因果关系。"
        }

        return headings.reduce(text) { result, heading in
            result.replacingOccurrences(of: "\n\n\n\(heading)", with: "\n\n\(heading)")
        }
    }
}

enum AIAnalysisBundleParser {
    private static let taskByTitle: [String: AITask] = Dictionary(
        uniqueKeysWithValues: AITask.analysisSuite.map { ($0.title, $0) }
    )

    static func parse(_ raw: String) -> [AITask: String] {
        var result: [AITask: String] = [:]
        var currentTask: AITask?
        var currentLines: [String] = []

        func flush() {
            guard let task = currentTask else { return }
            let body = currentLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                result[task] = AIAnalysisAnswerFormatter.normalize(body)
            }
            currentLines = []
        }

        for line in raw.components(separatedBy: .newlines) {
            if let task = task(forHeading: line) {
                flush()
                currentTask = task
            } else if currentTask != nil {
                currentLines.append(line)
            }
        }
        flush()
        return result
    }

    private static func task(forHeading line: String) -> AITask? {
        var heading = line.trimmingCharacters(in: .whitespacesAndNewlines)
        heading = heading.replacingOccurrences(of: "#", with: "")
        heading = heading.replacingOccurrences(of: "*", with: "")
        heading = heading.replacingOccurrences(of: "【", with: "")
        heading = heading.replacingOccurrences(of: "】", with: "")
        heading = heading.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.、：: "))
        return taskByTitle[heading]
    }
}
