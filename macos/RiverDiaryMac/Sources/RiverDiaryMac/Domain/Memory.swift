import Foundation

enum MemoryKind: String, Codable, Hashable, CaseIterable, Sendable {
    case longTermFact
    case habit
    case projectTrajectory
    case interpersonal
    case journey
    case other

    var displayName: String {
        switch self {
        case .longTermFact: "长期事实"
        case .habit: "习惯"
        case .projectTrajectory: "项目轨迹"
        case .interpersonal: "关系"
        case .journey: "旅程"
        case .other: "其他"
        }
    }
}

/// A durable memory distilled from episodes. It never stores raw machine
/// observations; it always points back to the episodes that produced it.
struct Memory: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var body: String
    var kind: MemoryKind
    var confidence: Int
    var sourceEpisodeIDs: [UUID]
    /// Stable cross-device evidence pointers. Event, capture, and diary refs are
    /// resolved by each client against its own shared projections.
    var evidenceRefs: [String]?
    var createdAt: Date
    var lastConfirmedAt: Date?
    var isUserConfirmed: Bool

    init(
        id: UUID = UUID(),
        title: String,
        body: String = "",
        kind: MemoryKind = .other,
        confidence: Int = 50,
        sourceEpisodeIDs: [UUID] = [],
        evidenceRefs: [String]? = nil,
        createdAt: Date = Date(),
        lastConfirmedAt: Date? = nil,
        isUserConfirmed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.confidence = confidence
        self.sourceEpisodeIDs = sourceEpisodeIDs
        self.evidenceRefs = evidenceRefs
        self.createdAt = createdAt
        self.lastConfirmedAt = lastConfirmedAt
        self.isUserConfirmed = isUserConfirmed
    }
}
