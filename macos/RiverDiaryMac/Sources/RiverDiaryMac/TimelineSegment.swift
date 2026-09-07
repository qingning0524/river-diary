import Foundation

struct TimelineAppUsage: Hashable {
    var name: String
    var duration: TimeInterval
}

struct TimelineSegment: Identifiable, Hashable {
    var id: String { "\(period.rawValue)-\(DateFormatter.segmentID.string(from: date))" }
    var date: Date
    var period: TimelinePeriod
    var start: Date
    var end: Date
    var totalDuration: TimeInterval
    var focusDuration: TimeInterval
    var switchCount: Int
    var sessions: [ActivitySession]
    var appDurations: [TimelineAppUsage]
    var captures: [QuickCapture] = []

    var isEmpty: Bool { (sessions.isEmpty && captures.isEmpty) || (totalDuration <= 0 && captures.isEmpty) }

    var focusRatio: Double {
        guard totalDuration > 0 else { return 0 }
        return min(1, max(0, focusDuration / totalDuration))
    }

    var primaryApp: String? {
        appDurations.first?.name
    }

    var appSummary: String {
        let names = appDurations.prefix(3).map(\.name)
        return names.joined(separator: " · ")
    }

    var timeRangeText: String {
        let formatter = DateFormatter.shortClock
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }
}

enum TimelinePeriod: String, CaseIterable, Identifiable {
    case earlyMorning
    case morning
    case afternoon
    case evening
    case lateNight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .earlyMorning: "清晨"
        case .morning: "上午"
        case .afternoon: "下午"
        case .evening: "夜晚"
        case .lateNight: "深夜"
        }
    }

    var symbol: String {
        switch self {
        case .earlyMorning: "sunrise.fill"
        case .morning: "sun.max.fill"
        case .afternoon: "sun.and.horizon.fill"
        case .evening: "moon.stars.fill"
        case .lateNight: "moon.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .earlyMorning: "#FFB74D"
        case .morning: "#42A5F5"
        case .afternoon: "#7E57C2"
        case .evening: "#7C5CFC"
        case .lateNight: "#78909C"
        }
    }

    var hours: [ClosedRange<Int>] {
        switch self {
        case .earlyMorning: [5...8]
        case .morning: [9...11]
        case .afternoon: [12...17]
        case .evening: [18...22]
        case .lateNight: [0...4, 23...23]
        }
    }
}

enum TimelineSegmentEngine {
    static func segments(
        for date: Date,
        sessions: [ActivitySession],
        quickCaptures: [QuickCapture] = []
    ) -> [TimelineSegment] {
        let dayKey = DiaryEntry.dateFormatter.string(from: date)
        let sameDay = sessions
            .filter { $0.dayKey == dayKey }
            .sorted { $0.start < $1.start }
        let sameDayCaptures = quickCaptures
            .filter { DiaryEntry.dateFormatter.string(from: $0.createdAt) == dayKey }
            .sorted { $0.createdAt < $1.createdAt }

        return TimelinePeriod.allCases.map { period in
            var start: Date?
            var end: Date?
            var matched: [ActivitySession] = []

            for session in sameDay {
                guard let interval = overlap(session: session, date: date, period: period) else { continue }
                let clipped = session.clipped(start: interval.lowerBound, end: interval.upperBound)
                guard clipped.duration > 0 else { continue }

                matched.append(clipped)
                if start == nil || clipped.start < start! { start = clipped.start }
                if end == nil || clipped.end > end! { end = clipped.end }
            }

            let duration = matched.reduce(0) { $0 + $1.duration }
            let focusDuration = matched
                .filter { ActivityClassifier.isFocus($0.category) }
                .reduce(0) { $0 + $1.duration }
            let appDurations = Dictionary(grouping: matched, by: \.appName)
                .mapValues { $0.reduce(0) { $0 + $1.duration } }
                .sorted { $0.value > $1.value }
                .map { TimelineAppUsage(name: $0.key, duration: $0.value) }

            let segmentStart = start ?? calendarStart(date: date, period: period)
            let segmentEnd = end ?? calendarEnd(date: date, period: period)
            let segmentCaptures = sameDayCaptures.filter { capture in
                capture.createdAt >= segmentStart && capture.createdAt < segmentEnd
            }

            return TimelineSegment(
                date: date,
                period: period,
                start: segmentStart,
                end: segmentEnd,
                totalDuration: duration,
                focusDuration: focusDuration,
                switchCount: max(0, matched.count - 1),
                sessions: matched,
                appDurations: appDurations,
                captures: segmentCaptures
            )
        }
    }

    private static func overlap(
        session: ActivitySession,
        date: Date,
        period: TimelinePeriod
    ) -> ClosedRange<Date>? {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        var bounds: [Date] = []
        for hours in period.hours {
            for hour in hours {
                guard let point = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                bounds.append(point)
                bounds.append(point.addingTimeInterval(3600))
            }
        }

        guard let lowerBound = bounds.min(), let upperBound = bounds.max() else { return nil }
        let overlapStart = max(session.start, lowerBound)
        let overlapEnd = min(session.end, upperBound)
        guard overlapEnd > overlapStart else { return nil }
        return overlapStart...overlapEnd
    }

    private static func calendarStart(date: Date, period: TimelinePeriod) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let hour = period.hours.first?.lowerBound ?? 0
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    private static func calendarEnd(date: Date, period: TimelinePeriod) -> Date {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)
        let hour = period.hours.last?.upperBound ?? 23
        let base = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        return base.addingTimeInterval(3600)
    }
}

extension ActivitySession {
    fileprivate func clipped(start: Date, end: Date) -> ActivitySession {
        guard end > start else { return self }
        return ActivitySession(
            id: id,
            appName: appName,
            bundleID: bundleID,
            windowTitle: windowTitle,
            category: category,
            start: max(self.start, start),
            end: min(self.end, end)
        )
    }
}

private extension DateFormatter {
    static let segmentID: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static let shortClock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()
}
