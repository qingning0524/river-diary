import Foundation

enum AITask: String, Codable {
    case dailyOverview
    case memorySearch
    case timelineDigest
    case habitReview
    case analysisDaily
    case analysisWeekly

    /// 需要四段结构（结论/关键依据/建议/边界）+ 证据核验的任务。
    /// 六卡综合分析套件已删除，这两个是仅存的成员。
    static let structuredAnalysisTasks: [AITask] = [
        .analysisDaily,
        .analysisWeekly
    ]

    var isAnalysisSuiteTask: Bool {
        Self.structuredAnalysisTasks.contains(self)
    }

    var title: String {
        switch self {
        case .dailyOverview: "AI 本日整理"
        case .memorySearch: "AI 搜索"
        case .timelineDigest: "AI 时间线整理"
        case .habitReview: "习惯回顾交流"
        case .analysisDaily: "每日总结"
        case .analysisWeekly: "本周规律"
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
    /// 该归档结果所属的范围键（如 d-2026-09-27 / w-2026-09-21）。
    /// 恢复逻辑据此避免跨页面互踩：今日页与复盘页各自恢复自己的范围。
    var archivedRangeKey: String? = nil
}

struct InsightRequest: Codable, Hashable, Identifiable {
    var id: String { "\(task.rawValue)|\(startDate ?? "")|\(endDate ?? "")" }
    var task: AITask
    var startDate: String?
    var endDate: String?
    var sourceSummary: String
    var createdAt: Date
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
