import Foundation

/// Personal context stays separate from the automatically collected evidence.
struct TimelineAnnotation: Codable, Hashable {
    var title: String = ""
    var note: String = ""
    var isFavorite: Bool = false
    var updatedAt: Date = Date()

    var normalized: TimelineAnnotation {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    var isEmpty: Bool { normalized.title.isEmpty && normalized.note.isEmpty && !isFavorite }

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
