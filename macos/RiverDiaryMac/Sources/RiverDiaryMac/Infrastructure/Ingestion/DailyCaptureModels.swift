import Foundation

// MARK: - Chrome History

struct ChromeVisit: Codable, Hashable {
    var url: String
    var title: String
    var visitedAt: Date
    var visitCount: Int
    var domain: String

    /// Stable local reference for AI citations; the raw URL is never embedded in
    /// the citation itself and titles are only sent when the user opts in.
    var evidenceID: UUID {
        let digest = SHA256Hex.hash(Data("\(url)|\(visitedAt.timeIntervalSince1970)".utf8))
        let hex = Array(digest.prefix(32))
        guard hex.count == 32 else { return UUID() }
        let value = "\(String(hex[0..<8]))-\(String(hex[8..<12]))-\(String(hex[12..<16]))-\(String(hex[16..<20]))-\(String(hex[20..<32]))"
        return UUID(uuidString: value) ?? UUID()
    }
}

// MARK: - Apple Notes

struct DailyNoteEntry: Codable, Hashable {
    var title: String
    var modifiedAt: Date
}

// MARK: - Daily Capture Record

struct DailyCaptureRecord: Codable {
    var date: String
    var capturedAt: Date
    var iosDataAvailable: Bool

    // iOS data
    var moodScore: Int?
    var sleepHours: Double?
    var sleepDeepMinutes: Double?
    var sleepREMMinutes: Double?
    var exerciseSteps: Int?
    var exerciseDistanceKM: Double?
    var exerciseEnergyKcal: Double?
    var quickNotes: [IngestedQuickNote]

    // Chrome browsing
    var chromeVisits: [ChromeVisit]
    var chromeTotalVisits: Int
    var chromeTopDomains: [String]

    // Apple Notes
    var notesModified: [DailyNoteEntry]

    // Screen time (from ActivityStore)
    var screenTimeMinutes: Int?
    var screenTopApps: [String]

    // Generated mixed overview
    var mixedOverview: String

    var isEmpty: Bool {
        chromeVisits.isEmpty && notesModified.isEmpty && quickNotes.isEmpty
            && moodScore == nil && sleepHours == nil && exerciseSteps == nil
    }

    var summary: String {
        var parts: [String] = []
        if let mood = moodScore { parts.append("心情 \(mood)") }
        if let sleep = sleepHours { parts.append("睡眠 \(String(format: "%.1f", sleep))h") }
        if let steps = exerciseSteps, steps > 0 { parts.append("步数 \(steps)") }
        if chromeTotalVisits > 0 { parts.append("浏览 \(chromeTotalVisits) 页") }
        if !notesModified.isEmpty { parts.append("备忘录 \(notesModified.count) 条") }
        if let screen = screenTimeMinutes, screen > 0 {
            parts.append("屏幕 \(String(format: "%.1f", Double(screen) / 60))h")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Screen Time Snapshot

struct ScreenTimeSnapshot: Codable {
    var totalMinutes: Int
    var topApps: [String]
}

extension DailyCaptureRecord {
    var sleep: IngestedSleepNight? {
        guard let sleepHours else { return nil }
        return IngestedSleepNight(
            date: date,
            totalHours: sleepHours,
            deepMinutes: sleepDeepMinutes ?? 0,
            remMinutes: sleepREMMinutes ?? 0,
            awakeMinutes: 0
        )
    }

    var exercise: IngestedExerciseDay? {
        guard let exerciseSteps else { return nil }
        return IngestedExerciseDay(
            date: date,
            steps: exerciseSteps,
            distanceKilometers: exerciseDistanceKM ?? 0,
            activeEnergyKilocalories: exerciseEnergyKcal ?? 0
        )
    }
}
