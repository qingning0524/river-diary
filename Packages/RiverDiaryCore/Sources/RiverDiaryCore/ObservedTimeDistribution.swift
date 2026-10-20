import Foundation

/// Source intervals are already observed. Missing durations never become manual-entry requirements.
public struct ObservedTimeInterval: Sendable {
    public var id: String
    public var category: String
    public var start: Date
    public var end: Date
    public var priority: Int
    public init(id: String, category: String, start: Date, end: Date, priority: Int) { self.id = id; self.category = category; self.start = start; self.end = end; self.priority = priority }
}
public struct ObservedTimeShare: Equatable, Sendable {
    public let category: String
    public let seconds: Double
    public let percentage: Int
}
public enum ObservedTimeDistribution {
    public static func calculate(_ intervals: [ObservedTimeInterval], on date: Date, calendar: Calendar = .current) -> [ObservedTimeShare] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let clipped = intervals.compactMap { interval -> ObservedTimeInterval? in
            var value = interval; value.start = max(value.start, start); value.end = min(value.end, end)
            return value.end > value.start && !value.category.isEmpty ? value : nil
        }
        let edges = Set(clipped.flatMap { [$0.start, $0.end] }).sorted()
        guard edges.count > 1 else { return [] }
        var totals: [String: Double] = [:]
        for index in 0..<(edges.count - 1) {
            let left = edges[index], right = edges[index + 1]
            let candidates = clipped.filter { $0.start < right && $0.end > left }.sorted {
                $0.priority == $1.priority ? $0.id < $1.id : $0.priority > $1.priority
            }
            if let selected = candidates.first { totals[selected.category, default: 0] += right.timeIntervalSince(left) }
        }
        let total = totals.values.reduce(0, +)
        guard total > 0 else { return [] }
        let ordered = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var percents = ordered.map { Int(floor($0.value / total * 100)) }
        let fractions = ordered.indices.sorted {
            let left = ordered[$0].value / total * 100 - Double(percents[$0]), right = ordered[$1].value / total * 100 - Double(percents[$1])
            return left == right ? $0 < $1 : left > right
        }
        for index in fractions.prefix(100 - percents.reduce(0, +)) { percents[index] += 1 }
        return ordered.indices.map { .init(category: ordered[$0].key, seconds: ordered[$0].value, percentage: percents[$0]) }
    }
}
