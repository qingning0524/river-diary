import Foundation

enum ProgressAnchor {
    static func completedEndDate(
        selectedDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let selectedDay = calendar.startOfDay(for: selectedDate)
        guard calendar.isDate(selectedDay, inSameDayAs: now) else { return selectedDay }
        return calendar.date(byAdding: .day, value: -1, to: selectedDay) ?? selectedDay
    }
}

struct ProgressWindow: Equatable {
    let start: Date
    let end: Date
    let dayCount: Int

    init(dayCount: Int, endingOn date: Date, calendar: Calendar = .current) {
        let end = calendar.startOfDay(for: date)
        self.end = end
        self.dayCount = max(1, dayCount)
        self.start = calendar.date(byAdding: .day, value: -self.dayCount + 1, to: end) ?? end
    }

    var preceding: ProgressWindow {
        let previousEnd = Calendar.current.date(byAdding: .day, value: -1, to: start) ?? start
        return ProgressWindow(dayCount: dayCount, endingOn: previousEnd)
    }

    var spansCalendarYears: Bool {
        Calendar.current.component(.year, from: start) != Calendar.current.component(.year, from: end)
    }
}

struct ProgressPeriodSummary: Equatable {
    let recordedDays: Int
    let focusDuration: TimeInterval?
    let unclassifiedDuration: TimeInterval?
    let entertainmentDuration: TimeInterval?
    let moodAverage: Double?
    let moodDays: Int
    let writingDays: Int
    let captureCount: Int
    let averageSteps: Double?
    let stepDays: Int
    let goalDays: Int
    let completedGoalDays: Int

    init(
        stats: FusedRangeStats,
        entries: [DiaryEntry],
        captures: [String: [QuickCapture]],
        dailyGoals: [String: DailyGoal] = [:]
    ) {
        let keys = Set(stats.dateKeys)
        let scopedEntries = entries.filter { keys.contains($0.date) }
        let scopedDays = stats.dayStats.filter { keys.contains($0.dateKey) }
        let recordedDays = scopedDays.filter { $0.liveTotal > 0 }
        let moods = scopedEntries.compactMap { $0.metrics?.mood ?? $0.score }
            .filter { $0.isFinite && (0...100).contains($0) }
        let healthDays = scopedDays.compactMap { $0.health?.steps }

        self.recordedDays = recordedDays.count
        self.focusDuration = recordedDays.isEmpty ? nil : stats.focusTotal
        self.unclassifiedDuration = recordedDays.isEmpty
            ? nil
            : scopedDays.flatMap(\.categoryUsage)
                .filter { $0.name == "其他" }
                .reduce(0) { $0 + $1.duration }
        self.entertainmentDuration = recordedDays.isEmpty
            ? nil
            : scopedDays.flatMap(\.categoryUsage)
                .filter { $0.name == "娱乐" }
                .reduce(0) { $0 + $1.duration }
        self.moodAverage = moods.isEmpty ? nil : moods.reduce(0, +) / Double(moods.count)
        self.moodDays = moods.count
        self.writingDays = scopedEntries.filter {
            !$0.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        self.captureCount = captures.filter { keys.contains($0.key) }.values.reduce(0) { $0 + $1.count }
        self.averageSteps = healthDays.isEmpty
            ? nil
            : Double(healthDays.reduce(0, +)) / Double(healthDays.count)
        self.stepDays = healthDays.count
        let scopedGoals = dailyGoals.filter { keys.contains($0.key) }.values
        self.goalDays = scopedGoals.count
        self.completedGoalDays = scopedGoals.filter(\.isCompleted).count
    }
}
