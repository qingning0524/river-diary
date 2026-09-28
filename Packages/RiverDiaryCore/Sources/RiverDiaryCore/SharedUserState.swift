import Foundation

public enum RiverCanonicalArtifactKey {
    public static func dailyReview(dayKey: String) -> String { "daily-review:\(dayKey)" }
}

public enum RiverSharedStateRecordKind: Hashable, Sendable, Codable {
    case habitRule
    case habitCard
    case habitBatch
    case memory
    case pendingConfirmation
    case journalEntry
    case monthlyLetter
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .habitRule: "habitRule"
        case .habitCard: "habitCard"
        case .habitBatch: "habitBatch"
        case .memory: "memory"
        case .pendingConfirmation: "pendingConfirmation"
        case .journalEntry: "journalEntry"
        case .monthlyLetter: "monthlyLetter"
        case .unknown(let value): value
        }
    }

    public init(rawValue: String) {
        switch rawValue {
        case "habitRule": self = .habitRule
        case "habitCard": self = .habitCard
        case "habitBatch": self = .habitBatch
        case "memory": self = .memory
        case "pendingConfirmation": self = .pendingConfirmation
        case "journalEntry": self = .journalEntry
        case "monthlyLetter": self = .monthlyLetter
        default: self = .unknown(rawValue)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RiverJournalEntryContent: Codable, Hashable, Sendable {
    public let dayKey: String
    public let body: String
    public let moodScore: Int?
    public let energyScore: Int?
    public let focusScore: Int?
    public let outputScore: Int?
    public let category: String?
    public let tags: [String]
    public let updatedAt: Date

    public init(dayKey: String, body: String, moodScore: Int? = nil, energyScore: Int? = nil,
                focusScore: Int? = nil, outputScore: Int? = nil, category: String? = nil,
                tags: [String] = [], updatedAt: Date = Date()) {
        self.dayKey = dayKey
        self.body = body
        self.moodScore = moodScore
        self.energyScore = energyScore
        self.focusScore = focusScore
        self.outputScore = outputScore
        self.category = category
        self.tags = tags
        self.updatedAt = updatedAt
    }
}

public struct RiverMonthlyLetterContent: Codable, Hashable, Sendable {
    public let monthKey: String
    public let title: String
    public let body: String
    public let evidence: String
    public let createdAt: Date
    public let updatedAt: Date
    public let isFavorite: Bool

    public init(monthKey: String, title: String, body: String, evidence: String,
                createdAt: Date, updatedAt: Date, isFavorite: Bool = false) {
        self.monthKey = monthKey
        self.title = title
        self.body = body
        self.evidence = evidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
    }
}

public struct RiverMoodScoreDecision: Codable, Hashable, Sendable {
    public let day: String
    public let score: Int

    public init(day: String, score: Int) {
        self.day = day
        self.score = score
    }
}

public struct RiverMoodScoreReset: Codable, Hashable, Sendable {
    public let day: String

    public init(day: String) { self.day = day }
}

public enum RiverPendingConfirmationResolution: String, Codable, Hashable, Sendable {
    case confirmed
    case rejected
    case corrected
    case dismissed
}

public struct RiverPendingConfirmationContent: Codable, Hashable, Sendable {
    public let title: String
    public let question: String
    public let detail: String
    public let candidate: String?
    public let targetType: String?
    public let targetID: String?
    public let resolution: RiverPendingConfirmationResolution?
    public let correction: String?
    public let resolvedAt: Date?

    public init(title: String, question: String, detail: String = "", candidate: String? = nil,
                targetType: String? = nil, targetID: String? = nil,
                resolution: RiverPendingConfirmationResolution? = nil,
                correction: String? = nil, resolvedAt: Date? = nil) {
        self.title = title
        self.question = question
        self.detail = detail
        self.candidate = candidate
        self.targetType = targetType
        self.targetID = targetID
        self.resolution = resolution
        self.correction = correction
        self.resolvedAt = resolvedAt
    }

    public func resolving(_ resolution: RiverPendingConfirmationResolution,
                          correction: String? = nil, at date: Date = Date()) -> Self {
        Self(title: title, question: question, detail: detail, candidate: candidate,
             targetType: targetType, targetID: targetID, resolution: resolution,
             correction: correction, resolvedAt: date)
    }
}

public extension RiverSharedStateRecord {
    var journalEntryContent: RiverJournalEntryContent? {
        guard kind == .journalEntry, let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiverJournalEntryContent.self, from: data)
    }

    var monthlyLetterContent: RiverMonthlyLetterContent? {
        guard kind == .monthlyLetter, let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiverMonthlyLetterContent.self, from: data)
    }

    static func journalEntry(_ content: RiverJournalEntryContent, status: String = "current") -> Self? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(content),
              let payload = String(data: bytes, encoding: .utf8) else { return nil }
        let id = RiverStableIdentifier.uuid(namespace: "journal-entry", key: content.dayKey)
        return Self(id: id, kind: .journalEntry, status: status, logicalKey: content.dayKey,
                    payloadJSON: payload, createdAt: content.updatedAt, updatedAt: content.updatedAt)
    }

    static func monthlyLetter(_ content: RiverMonthlyLetterContent) -> Self? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(content),
              let payload = String(data: bytes, encoding: .utf8) else { return nil }
        let id = RiverStableIdentifier.uuid(namespace: "monthly-letter", key: content.monthKey)
        return Self(id: id, kind: .monthlyLetter, status: "current", logicalKey: content.monthKey,
                    payloadJSON: payload, createdAt: content.createdAt, updatedAt: content.updatedAt)
    }

    var pendingConfirmationContent: RiverPendingConfirmationContent? {
        guard kind == .pendingConfirmation, let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RiverPendingConfirmationContent.self, from: data)
    }

    static func placeCandidate(_ place: RiverPlace) -> Self? {
        guard !place.isUserConfirmed, place.visitCount >= 2,
              let candidate = place.mapName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty else { return nil }
        let content = RiverPendingConfirmationContent(
            title: "地点候选",
            question: "这里是「\(candidate)」吗？",
            detail: place.mapAddress ?? "你已经多次到访这个地点。",
            candidate: candidate,
            targetType: "place",
            targetID: place.id
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(content),
              let payload = String(data: bytes, encoding: .utf8) else { return nil }
        let id = RiverStableIdentifier.uuid(namespace: "place-confirmation", key: place.id)
        return Self(id: id, kind: .pendingConfirmation, status: "pending",
                    logicalKey: "place-confirmation:\(place.id)", payloadJSON: payload,
                    createdAt: place.firstSeen, updatedAt: place.firstSeen)
    }

    func resolving(_ resolution: RiverPendingConfirmationResolution,
                   correction: String? = nil, at date: Date = Date()) -> Self? {
        guard kind == .pendingConfirmation, status == "pending",
              let content = pendingConfirmationContent else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(content.resolving(resolution, correction: correction, at: date)),
              let payload = String(data: bytes, encoding: .utf8) else { return nil }
        return Self(id: id, kind: kind, status: resolution.rawValue, logicalKey: logicalKey,
                    payloadJSON: payload, createdAt: createdAt, updatedAt: date,
                    batchID: batchID, shownAt: shownAt)
    }
}

public struct RiverMemoryConfirmation: Codable, Hashable, Sendable {
    public let memoryID: UUID
    public let confirmed: Bool
    public let note: String
    public let updatedAt: Date

    public init(memoryID: UUID, confirmed: Bool, note: String = "", updatedAt: Date = Date()) {
        self.memoryID = memoryID
        self.confirmed = confirmed
        self.note = note
        self.updatedAt = updatedAt
    }
}

public enum RiverStateOperationFreshness {
    /// Distinguishes new analytical results from user decisions that invalidate
    /// the inputs behind already-published generated Artifacts.
    public static func changesAnalyticalState(_ operation: StateOperation) -> Bool {
        switch operation.operationType {
        case "artifact.stale":
            return false
        case "memory.confirmation.set", "habit.preference.set", "mood.score.set", "mood.score.reset",
             "place.identity.set", "place.rename", "place.confirm", "timeline.annotation.set",
             "object.tombstone", "device.lifecycle.set":
            return true
        case "shared.record.upsert":
            guard let record = try? JSONDecoder().decode(RiverSharedStateRecord.self, from: operation.payload) else { return true }
            switch record.kind {
            case .memory:
                return record.status == "confirmed"
            case .habitRule:
                return record.status == "active" || record.status == "retired" || record.status == "challenged"
            case .habitCard:
                return record.status == "answered" || record.status == "skipped" || record.status == "expired"
            case .habitBatch:
                return false
            case .pendingConfirmation:
                return ["confirmed", "rejected", "corrected", "dismissed"].contains(record.status)
            case .journalEntry:
                return record.status == "current" || record.status == "deleted"
            case .monthlyLetter:
                return record.status == "current"
            case .unknown:
                return record.status == "current" || record.status == "confirmed" || record.status == "deleted"
            }
        default:
            return false
        }
    }
}

/// Portable record envelope for shared user state. `payloadJSON` preserves
/// domain-specific fields while the outer record supplies stable identity,
/// logical key, and queryable conflict metadata.
public struct RiverSharedStateRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: RiverSharedStateRecordKind
    public let status: String
    public let logicalKey: String
    public let payloadJSON: String
    public let createdAt: Date
    public let updatedAt: Date
    public let batchID: UUID?
    public let shownAt: Date?

    public var targetID: String { "user-record:\(kind.rawValue):\(id.uuidString.lowercased())" }

    public init(id: UUID, kind: RiverSharedStateRecordKind, status: String, logicalKey: String,
                payloadJSON: String, createdAt: Date, updatedAt: Date,
                batchID: UUID? = nil, shownAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.logicalKey = logicalKey
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.batchID = batchID
        self.shownAt = shownAt
    }
}
