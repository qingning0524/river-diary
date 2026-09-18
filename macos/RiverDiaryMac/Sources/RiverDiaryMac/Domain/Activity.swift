import Foundation

enum ActivityCategory: String, Codable, Hashable, CaseIterable, Sendable {
    case focused
    case exploring
    case communication
    case admin
    case leisure
    case idle
    case other
}

/// A merged, de-duplicated block of activity derived from raw events.
/// It is a rebuildable projection; never delete raw events to reconstruct it.
struct Activity: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var groupKey: String
    var primaryApp: String?
    var category: ActivityCategory
    var evidenceIDs: [UUID]

    var duration: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }

    init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        groupKey: String,
        primaryApp: String? = nil,
        category: ActivityCategory = .other,
        evidenceIDs: [UUID] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.groupKey = groupKey
        self.primaryApp = primaryApp
        self.category = category
        self.evidenceIDs = evidenceIDs
    }
}
