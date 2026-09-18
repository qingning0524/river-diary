import Foundation

enum EvidenceRefKind: String, Codable, Hashable, CaseIterable, Sendable {
    case rawEvent
    case activity
    case episode
    case memory
}

/// A pointer that lets Ask / Inspector explain *why* River believes something:
/// which object, of what kind, and when it happened.
struct EvidenceRef: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var kind: EvidenceRefKind
    var objectID: UUID
    var reason: String
    var sourceTimestamp: Date

    init(
        id: UUID = UUID(),
        kind: EvidenceRefKind,
        objectID: UUID,
        reason: String = "",
        sourceTimestamp: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.objectID = objectID
        self.reason = reason
        self.sourceTimestamp = sourceTimestamp
    }
}
