import Foundation

struct RiverRecordedInterval {
    let start: Date
    let duration: TimeInterval
}

/// Normalizes units and merges recorded intervals. No coverage or health score is invented.
enum RiverDayReadingMath {
    static func recordedDuration(_ intervals: [RiverRecordedInterval], on date: Date, calendar: Calendar = .current) -> TimeInterval? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
        let spans = intervals.compactMap { item -> (Date, Date)? in
            guard item.duration.isFinite, item.duration > 0 else { return nil }
            let lower = max(start, item.start)
            let upper = min(end, item.start.addingTimeInterval(item.duration))
            return upper > lower ? (lower, upper) : nil
        }.sorted { $0.0 < $1.0 }
        guard var merged = spans.first else { return nil }
        var total: TimeInterval = 0
        for span in spans.dropFirst() {
            if span.0 <= merged.1 { merged.1 = max(merged.1, span.1) }
            else { total += merged.1.timeIntervalSince(merged.0); merged = span }
        }
        return total + merged.1.timeIntervalSince(merged.0)
    }

    static func timeText(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "未记录" }
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(remainder) 分"
        }
        return "\(minutes) 分钟"
    }
}
