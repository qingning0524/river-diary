import Foundation

enum TimelineSegmentNameStore {
    private static let storageKey = "timeline.segmentNames"

    static func name(for date: Date, period: TimelinePeriod) -> String {
        let dateKey = DiaryEntry.dateFormatter.string(from: date)
        return dictionary()[dateKey]?[period.rawValue] ?? ""
    }

    static func save(_ value: String, for date: Date, period: TimelinePeriod) {
        let dateKey = DiaryEntry.dateFormatter.string(from: date)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var allNames = dictionary()
        var dayNames = allNames[dateKey] ?? [:]

        if trimmed.isEmpty {
            dayNames.removeValue(forKey: period.rawValue)
        } else {
            dayNames[period.rawValue] = trimmed
        }

        if dayNames.isEmpty {
            allNames.removeValue(forKey: dateKey)
        } else {
            allNames[dateKey] = dayNames
        }

        guard let data = try? JSONEncoder().encode(allNames) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func dictionary() -> [String: [String: String]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let names = try? JSONDecoder().decode([String: [String: String]].self, from: data) else {
            return [:]
        }
        return names
    }
}
