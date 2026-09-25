import Foundation

// MARK: - Date Helpers

enum DatabaseTime {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(_ value: String) -> Date? {
        isoFormatter.date(from: value)
    }

}
