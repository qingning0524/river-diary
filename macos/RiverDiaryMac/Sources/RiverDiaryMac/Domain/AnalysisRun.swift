import Foundation

enum RiverTaskKind: String, Codable, Hashable, CaseIterable, Sendable {
    case summarize
    case memoryCandidate
    case weeklyReview
    case query
    case monthlyLetter
    case namingProposal
    case dailyOverview
    case footprintQuestion
    case insightReading
    case memorySearch
    case riverReading
    case noteThemes
    case timelineDigest
    case habitReview
    case analysis
}

/// AI output, kept strictly outside the fact layer. An analysis run records
/// the context it read and the evidence that grounded it, but can never write
/// back to raw_events, activities, episodes, or memories.
struct AnalysisRun: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var task: RiverTaskKind
    var inputContextReference: UUID?
    var outputText: String
    var evidenceIDs: [UUID]
    var model: String
    var createdAt: Date

    var title: String {
        switch task {
        case .summarize: "总结"
        case .memoryCandidate: "记忆候选"
        case .weeklyReview: "周期回顾"
        case .query: "记忆查询"
        case .monthlyLetter: "河流信"
        case .namingProposal: "命名建议"
        case .dailyOverview: "本日整理"
        case .footprintQuestion: "足迹问答"
        case .insightReading: "状态洞察"
        case .memorySearch: "AI 搜索"
        case .riverReading: "情绪河流"
        case .noteThemes: "快记主题"
        case .timelineDigest: "时间线整理"
        case .habitReview: "习惯回顾交流"
        case .analysis: "综合分析"
        }
    }

    init(
        id: UUID = UUID(),
        task: RiverTaskKind,
        inputContextReference: UUID? = nil,
        outputText: String = "",
        evidenceIDs: [UUID] = [],
        model: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.task = task
        self.inputContextReference = inputContextReference
        self.outputText = outputText
        self.evidenceIDs = evidenceIDs
        self.model = model
        self.createdAt = createdAt
    }
}

struct ContextSnapshot: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var payloadJSON: String
    var model: String
}
