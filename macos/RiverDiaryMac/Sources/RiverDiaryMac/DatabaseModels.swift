import Foundation

// MARK: - Database Models
//
// Rows read back out of the encrypted legacy database. Only the types the
// surviving queries still return live here (ai_results and daily_records);
// the rest of the schema is written-only from capture records.

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
