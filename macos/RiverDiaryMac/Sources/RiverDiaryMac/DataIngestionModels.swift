import Foundation

// MARK: - Ingested Types (iOS export)

struct IngestedSleepNight: Codable, Hashable, Identifiable {
    var id: String { date }
    var date: String
    var totalHours: Double
    var deepMinutes: Double
    var remMinutes: Double
    var awakeMinutes: Double
}

struct IngestedExerciseDay: Codable, Hashable, Identifiable {
    var id: String { date }
    var date: String
    var steps: Int
    var distanceKilometers: Double
    var activeEnergyKilocalories: Double
}

struct IngestedQuickNote: Codable, Hashable, Identifiable {
    var id: String
    var date: String
    var text: String
    var createdAt: Date?
    var source: String
}

struct IngestedUserData: Codable {
    var version = 2
    var syncedAt: Date
    var sourceUpdatedAt: String?
    var moodScores: [String: Int]
    var sleepNights: [IngestedSleepNight]
    var exerciseDays: [IngestedExerciseDay]
    var quickNotes: [IngestedQuickNote]

    var isEmpty: Bool {
        moodScores.isEmpty && sleepNights.isEmpty && exerciseDays.isEmpty && quickNotes.isEmpty
    }

    var summary: String {
        "评分 \(moodScores.count) 天 · 睡眠 \(sleepNights.count) 晚 · 运动 \(exerciseDays.count) 天 · 快记 \(quickNotes.count) 条"
    }
}

