import Foundation

/// Personal context stays separate from the automatically collected evidence.
struct TimelineAnnotation: Codable, Hashable {
    var title: String = ""
    var note: String = ""
    var placeName: String = ""
    var activityLabel: String = ""
    var isFavorite: Bool = false
    var isReviewed: Bool = false
    var reviewedAt: Date?
    var updatedAt: Date = Date()

    init(
        title: String = "",
        note: String = "",
        placeName: String = "",
        activityLabel: String = "",
        isFavorite: Bool = false,
        isReviewed: Bool = false,
        reviewedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.note = note
        self.placeName = placeName
        self.activityLabel = activityLabel
        self.isFavorite = isFavorite
        self.isReviewed = isReviewed
        self.reviewedAt = reviewedAt
        self.updatedAt = updatedAt
    }

    var normalized: TimelineAnnotation {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        result.placeName = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.activityLabel = activityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var isEmpty: Bool {
        let value = normalized
        return value.title.isEmpty && value.note.isEmpty && value.placeName.isEmpty && value.activityLabel.isEmpty && !isFavorite && !isReviewed
    }

    private enum CodingKeys: String, CodingKey {
        case title, note, placeName, activityLabel, isFavorite, isReviewed, reviewedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        placeName = try container.decodeIfPresent(String.self, forKey: .placeName) ?? ""
        activityLabel = try container.decodeIfPresent(String.self, forKey: .activityLabel) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isReviewed = try container.decodeIfPresent(Bool.self, forKey: .isReviewed) ?? false
        reviewedAt = try container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(note, forKey: .note)
        try container.encode(placeName, forKey: .placeName)
        try container.encode(activityLabel, forKey: .activityLabel)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(isReviewed, forKey: .isReviewed)
        try container.encodeIfPresent(reviewedAt, forKey: .reviewedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    static func key(for session: ActivitySession) -> String {
        // The collector assigns a new UUID when closing a session spanning midnight.
        // Its clipped start and application identity remain stable before and after that split.
        "\(Int(session.start.timeIntervalSince1970))|\(session.bundleID)|\(session.appName)"
    }

    static func updating(_ existing: [String: TimelineAnnotation], key: String, with value: TimelineAnnotation) -> [String: TimelineAnnotation] {
        var result = existing
        result[key] = value.isEmpty ? nil : value.normalized
        return result
    }
}
