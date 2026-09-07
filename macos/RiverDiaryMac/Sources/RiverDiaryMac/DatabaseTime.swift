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

    static func shortTime(_ value: String) -> String {
        guard let date = date(value) else { return value.isEmpty ? "—" : value }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func fullTime(_ value: String) -> String {
        guard let date = date(value) else { return value.isEmpty ? "—" : value }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
