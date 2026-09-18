import Foundation

enum MemoryKind: String, Codable, Hashable, CaseIterable, Sendable {
    case longTermFact
    case habit
    case projectTrajectory
    case interpersonal
    case journey
    case other
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
        self.createdAt = createdAt
        self.lastConfirmedAt = lastConfirmedAt
        self.isUserConfirmed = isUserConfirmed
    }
}
