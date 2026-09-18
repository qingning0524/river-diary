import Foundation

enum EpisodeCategory: String, Codable, Hashable, CaseIterable, Sendable {
    case work
    case study
    case communication
    case admin
    case leisure
    case personal
    case other
}

struct ConfidenceFactor: Codable, Hashable, Sendable {
    var name: String
    var value: Double

    init(name: String, value: Double) {
        self.name = name
        self.value = value
    }
}

/// A human-meaningful episode. Always carries its provenance:
/// the activities and, transitively, the raw events that formed it.
struct Episode: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var title: String
    var summary: String
    var category: EpisodeCategory
    var confidence: Int
    var confidenceFactors: [ConfidenceFactor]
    var activityIDs: [UUID]
    var evidenceIDs: [UUID]

    var duration: TimeInterval {
        max(0, endTime.timeIntervalSince(startTime))
    }

    /// Deduplicated union of the episode's direct evidence along with the
    /// evidence its activities reference. Used for Ask grounding.
    func allEvidenceIDs(bundle: [String: [UUID]], system: Any? = nil) -> [UUID] {
        var result: [UUID] = []
        var seen = Set<UUID>()
        func include(_ uuid: UUID) {
            if seen.insert(uuid).inserted { result.append(uuid) }
        }
        for id in evidenceIDs { include(id) }
        for id in activityIDs {
            if let refs = bundle[id.uuidString] {
                for ref in refs { include(ref) }
            }
        }
        return result
    }

    init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        title: String,
        summary: String = "",
        category: EpisodeCategory = .other,
        confidence: Int = 50,
        confidenceFactors: [ConfidenceFactor] = [],
        activityIDs: [UUID] = [],
        evidenceIDs: [UUID] = []
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.title = title
        self.summary = summary
        self.category = category
        self.confidence = confidence
        self.confidenceFactors = confidenceFactors
        self.activityIDs = activityIDs
        self.evidenceIDs = evidenceIDs
    }
}
