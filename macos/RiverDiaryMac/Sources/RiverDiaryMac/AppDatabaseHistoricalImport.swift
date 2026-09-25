import Foundation
import SQLCipher

// MARK: - Historical iOS Import

extension AppDatabase {
    func saveIOSHistory(_ data: IngestedUserData, excluding excludedDate: String? = nil) {
        _ = transaction { database in
            for (date, score) in data.moodScores where date != excludedDate {
                let sql = "INSERT OR REPLACE INTO mood_scores (date, score, source) VALUES (?,?,'iOS 健康')"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, date, -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 2, Int32(score))
                }, database: database) else { return false }
            }

            for night in data.sleepNights where night.date != excludedDate {
                let sql = "INSERT OR REPLACE INTO sleep_nights (date, total_hours, deep_minutes, rem_minutes, awake_minutes) VALUES (?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, night.date, -1, Self.transientDestructor)
                    sqlite3_bind_double(statement, 2, night.totalHours)
                    sqlite3_bind_double(statement, 3, night.deepMinutes)
                    sqlite3_bind_double(statement, 4, night.remMinutes)
                    sqlite3_bind_double(statement, 5, night.awakeMinutes)
                }, database: database) else { return false }
            }

            for day in data.exerciseDays where day.date != excludedDate {
                let sql = "INSERT OR REPLACE INTO exercise_days (date, steps, distance_km, active_energy_kcal) VALUES (?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, day.date, -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 2, Int32(day.steps))
                    sqlite3_bind_double(statement, 3, day.distanceKilometers)
                    sqlite3_bind_double(statement, 4, day.activeEnergyKilocalories)
                }, database: database) else { return false }
            }

            for note in data.quickNotes where note.date != excludedDate {
                let sql = "INSERT OR REPLACE INTO quick_captures (id, date, text, created_at, source) VALUES (?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, note.id, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 2, note.date, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 3, note.text, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 4, note.createdAt.map(DatabaseTime.isoFormatter.string), -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 5, note.source, -1, Self.transientDestructor)
                }, database: database) else { return false }
            }

            let dates = Set(data.moodScores.keys)
                .union(data.sleepNights.map(\.date))
                .union(data.exerciseDays.map(\.date))
                .union(data.quickNotes.map(\.date))
                .filter { $0 != excludedDate }

            for date in dates {
                let mood = data.moodScores[date]
                let sleep = data.sleepNights.first { $0.date == date }
                let exercise = data.exerciseDays.first { $0.date == date }
                let captures = data.quickNotes.filter { $0.date == date }
                let record = DailyCaptureRecord(
                    date: date,
                    capturedAt: data.syncedAt,
                    iosDataAvailable: true,
                    moodScore: mood,
                    sleepHours: sleep?.totalHours,
                    sleepDeepMinutes: sleep?.deepMinutes,
                    sleepREMMinutes: sleep?.remMinutes,
                    exerciseSteps: exercise?.steps,
                    exerciseDistanceKM: exercise?.distanceKilometers,
                    exerciseEnergyKcal: exercise?.activeEnergyKilocalories,
                    quickNotes: captures,
                    chromeVisits: [],
                    chromeTotalVisits: 0,
                    chromeTopDomains: [],
                    notesModified: [],
                    screenTimeMinutes: nil,
                    screenTopApps: [],
                    mixedOverview: "历史 iOS 数据已导入。"
                )
                // Merge into the existing summary row, preserving any macOS-sourced
                // values (session count, chrome/notes counts, screen time) so a
                // re-import of the iOS history does not reset them to zero.
                let existing = existingDailyRecord(date: date, database: database)
                guard upsertDailyRecord(
                    record,
                    moodScore: mood,
                    sleepHours: sleep?.totalHours,
                    exerciseSteps: exercise?.steps,
                    screenTimeMinutes: existing?.screenTimeMinutes,
                    chromeCount: existing?.chromeVisitCount ?? 0,
                    notesCount: existing?.notesCount ?? 0,
                    sessionCount: existing?.sessionCount ?? 0,
                    quickCaptureCount: captures.count,
                    database: database
                ) else { return false }
            }

            return true
        }
    }
}
