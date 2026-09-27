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

    /// 某一时刻是否落在本时段当天的任一小时区间内。
    /// 对不连续时段（深夜）这是唯一正确的归属方式：跨度判定会把
    /// 05:00–23:00 空洞里的时刻也包进来。
    func contains(moment: Date, on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        let hour = calendar.component(.hour, from: moment)
        let minute = calendar.component(.minute, from: moment)
        let minuteOfDay = hour * 60 + minute
        for hourBlock in self.hours {
            // hourBlock 是 ClosedRange<Int>；迭代它得到的是每个整点 Int。
            for hour in hourBlock {
                let startMinute = hour * 60
                let endMinute = (hour + 1) * 60
                if minuteOfDay >= startMinute, minuteOfDay < endMinute {
                    return true
                }
            }
        }
        return false
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
                // 逐小时求交：像"深夜"（0–4 点 + 23 点）这样的不连续时段，
                // 不能用 min/max 边界把中间空洞里的会话也吞进来。
                for interval in overlaps(session: session, date: date, period: period) {
                    let clipped = session.clipped(start: interval.lowerBound, end: interval.upperBound)
                    guard clipped.duration > 0 else { continue }

                    matched.append(clipped)
                    if start == nil || clipped.start < start! { start = clipped.start }
                    if end == nil || clipped.end > end! { end = clipped.end }
                }
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
            // 快记按"落在时段的任一小时区间内"归属，而不是按首末会话的跨度：
            // 像"深夜"（0–4 点 + 23 点）这样的不连续时段，用跨度会把
            // 05:00–23:00 空洞里的快记也吞进来。
            let segmentCaptures = sameDayCaptures.filter { capture in
                period.contains(moment: capture.createdAt, on: date)
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

    private static func overlaps(
        session: ActivitySession,
        date: Date,
        period: TimelinePeriod
    ) -> [ClosedRange<Date>] {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: date)

        var ranges: [ClosedRange<Date>] = []
        for hours in period.hours {
            for hour in hours {
                guard let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) else { continue }
                let hourEnd = hourStart.addingTimeInterval(3600)
                let overlapStart = max(session.start, hourStart)
                let overlapEnd = min(session.end, hourEnd)
                guard overlapEnd > overlapStart else { continue }
                ranges.append(overlapStart...overlapEnd)
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
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
