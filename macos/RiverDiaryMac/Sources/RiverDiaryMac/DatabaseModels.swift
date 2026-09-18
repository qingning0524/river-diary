import Foundation

// MARK: - Database Models

struct DBMoodScore: Codable, Identifiable, Hashable {
    var id: String { date }
    var date: String
    var score: Int
    var source: String
}

struct DBSleepNight: Codable, Identifiable, Hashable {
    var id: String { date }
    var date: String
    var totalHours: Double
    var deepMinutes: Double
    var remMinutes: Double
    var awakeMinutes: Double
}

struct DBExerciseDay: Codable, Identifiable, Hashable {
    var id: String { date }
    var date: String
    var steps: Int
    var distanceKM: Double
    var activeEnergyKcal: Double
}

struct DBChromeVisit: Codable, Identifiable, Hashable {
    var id: Int
    var date: String
    var url: String
    var title: String
    var domain: String
    var visitedAt: String
    var visitCount: Int
}

struct DBDailyNote: Codable, Identifiable, Hashable {
    var id: Int
    var date: String
    var title: String
    var modifiedAt: String
}

struct DBActivitySession: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var appName: String
    var category: String
    var startTime: String
    var endTime: String
    var durationMinutes: Int
    var windowTitle: String?
}

struct DBQuickCapture: Codable, Identifiable, Hashable {
    var id: String
    var date: String
    var text: String
    var createdAt: String
    var source: String
}

struct DBAIResult: Codable, Identifiable, Hashable {
    var id: String { resultKey }
    var resultKey: String
    var startDate: String
    var endDate: String
    var task: String
    var model: String
    var answer: String
    var sourceSummary: String
    var createdAt: String
    var isLocal: Bool
}

struct DatabaseCrossDaySnapshot {
    var startDate: String
    var endDate: String
    var query: String
    var dailyRecords: [DBDailyRecord] = []
    var chromeVisits: [DBChromeVisit] = []
    var notes: [DBDailyNote] = []
    var sessions: [DBActivitySession] = []
    var quickCaptures: [DBQuickCapture] = []

    var recordCount: Int {
        dailyRecords.count + chromeVisits.count + notes.count + sessions.count + quickCaptures.count
    }
}

struct DBDailyRecord: Codable, Identifiable, Hashable {
    var id: String { date }
    var date: String
    var capturedAt: String
    var moodScore: Int?
    var sleepHours: Double?
    var exerciseSteps: Int?
    var screenTimeMinutes: Int?
    var chromeVisitCount: Int
    var notesCount: Int
    var sessionCount: Int
    var quickCaptureCount: Int
    var mixedOverview: String
    var iosDataAvailable: Bool
}
