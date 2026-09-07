import Foundation
import SQLite3
// MARK: - Database

final class AppDatabase {
    static let shared = AppDatabase()

    var db: OpaquePointer?
    let queue = DispatchQueue(label: "studio.riverdiary.database", qos: .utility)
    private(set) var lastError: String?

    private var databasePath: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent("river-diary.db")
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private init() {
        open()
        createTables()
        migrateTables()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: Setup

    private func open() {
        guard let path = databasePath else { return }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path.path, &db, flags, nil) != SQLITE_OK {
            lastError = "数据库无法打开"
            db = nil
        }
    }

    private func createTables() {
        let statements = [
            """
            CREATE TABLE IF NOT EXISTS daily_records (
                date TEXT PRIMARY KEY,
                captured_at TEXT,
                mood_score INTEGER,
                sleep_hours REAL,
                exercise_steps INTEGER,
                screen_time_minutes INTEGER,
                chrome_visit_count INTEGER DEFAULT 0,
                notes_count INTEGER DEFAULT 0,
                session_count INTEGER DEFAULT 0,
                quick_capture_count INTEGER DEFAULT 0,
                mixed_overview TEXT DEFAULT '',
                ios_data_available INTEGER DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS mood_scores (
                date TEXT PRIMARY KEY,
                score INTEGER NOT NULL,
                source TEXT DEFAULT 'iOS 健康'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sleep_nights (
                date TEXT PRIMARY KEY,
                total_hours REAL NOT NULL,
                deep_minutes REAL DEFAULT 0,
                rem_minutes REAL DEFAULT 0,
                awake_minutes REAL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS exercise_days (
                date TEXT PRIMARY KEY,
                steps INTEGER DEFAULT 0,
                distance_km REAL DEFAULT 0,
                active_energy_kcal REAL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS chrome_visits (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                url TEXT NOT NULL,
                title TEXT DEFAULT '',
                domain TEXT DEFAULT '',
                visited_at TEXT,
                visit_count INTEGER DEFAULT 1
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS daily_notes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL,
                title TEXT NOT NULL,
                modified_at TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS activity_sessions (
                id TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                app_name TEXT NOT NULL,
                bundle_id TEXT DEFAULT '',
                category TEXT DEFAULT '',
                start_time TEXT,
                end_time TEXT,
                duration_minutes INTEGER DEFAULT 0,
                window_title TEXT
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS quick_captures (
                id TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                text TEXT NOT NULL,
                created_at TEXT,
                source TEXT DEFAULT 'iOS 快记'
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_chrome_date ON chrome_visits(date)",
            "CREATE INDEX IF NOT EXISTS idx_notes_date ON daily_notes(date)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_date ON activity_sessions(date)",
            "CREATE INDEX IF NOT EXISTS idx_captures_date ON quick_captures(date)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_start ON activity_sessions(start_time)",
            """
            CREATE TABLE IF NOT EXISTS ai_results (
                result_key TEXT PRIMARY KEY,
                start_date TEXT NOT NULL,
                end_date TEXT NOT NULL,
                task TEXT NOT NULL,
                model TEXT NOT NULL,
                answer TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_ai_results_range ON ai_results(start_date, end_date)"
        ]

        _ = transaction { database in
            for sql in statements {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
                let stepResult = sqlite3_step(statement)
                let success = stepResult == SQLITE_DONE || stepResult == SQLITE_ROW
                sqlite3_finalize(statement)
                if !success { return false }
            }
            return true
        }
    }

    private func migrateTables() {
        _ = transaction { database in
            addColumnIfMissing("visited_at", "TEXT", to: "chrome_visits", database: database)
            addColumnIfMissing("bundle_id", "TEXT DEFAULT ''", to: "activity_sessions", database: database)
            return true
        }
    }

    private func addColumnIfMissing(_ column: String, _ definition: String, to table: String, database: OpaquePointer) {
        var checkStatement: OpaquePointer?
        let checkSQL = "PRAGMA table_info(\(table))"
        var exists = false
        if sqlite3_prepare_v2(database, checkSQL, -1, &checkStatement, nil) == SQLITE_OK {
            while sqlite3_step(checkStatement) == SQLITE_ROW {
                if text(checkStatement, 1).lowercased() == column.lowercased() {
                    exists = true
                    break
                }
            }
        }
        sqlite3_finalize(checkStatement)
        guard !exists else { return }
        var statement: OpaquePointer?
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    func transaction(_ work: (OpaquePointer) -> Bool) -> Bool {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return false }
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            let success = work(db)
            sqlite3_exec(db, success ? "COMMIT" : "ROLLBACK", nil, nil, nil)
            self.lastError = success ? nil : "数据库写入失败"
            return success
        }
    }

    // MARK: Complete Daily Capture

    @discardableResult
    func saveDailyCapture(_ record: DailyCaptureRecord, sessions: [ActivitySession]) -> Bool {
        transaction { database in
            guard bindDailyRecord(record, sessionCount: sessions.count, database: database) else { return false }

            if let mood = record.moodScore {
                let sql = "INSERT OR REPLACE INTO mood_scores (date, score, source) VALUES (?,?,'iOS 健康')"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, record.date, -1, nil)
                    sqlite3_bind_int(statement, 2, Int32(mood))
                }, database: database) else { return false }
            }

            if let sleep = record.sleep {
                let sql = "INSERT OR REPLACE INTO sleep_nights (date, total_hours, deep_minutes, rem_minutes, awake_minutes) VALUES (?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, sleep.date, -1, nil)
                    sqlite3_bind_double(statement, 2, sleep.totalHours)
                    sqlite3_bind_double(statement, 3, sleep.deepMinutes)
                    sqlite3_bind_double(statement, 4, sleep.remMinutes)
                    sqlite3_bind_double(statement, 5, sleep.awakeMinutes)
                }, database: database) else { return false }
            }

            if let exercise = record.exercise {
                let sql = "INSERT OR REPLACE INTO exercise_days (date, steps, distance_km, active_energy_kcal) VALUES (?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, exercise.date, -1, nil)
                    sqlite3_bind_int(statement, 2, Int32(exercise.steps))
                    sqlite3_bind_double(statement, 3, exercise.distanceKilometers)
                    sqlite3_bind_double(statement, 4, exercise.activeEnergyKilocalories)
                }, database: database) else { return false }
            }

            guard execute("DELETE FROM chrome_visits WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
            for visit in record.chromeVisits {
                let sql = "INSERT INTO chrome_visits (date, url, title, domain, visited_at, visit_count) VALUES (?,?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, record.date, -1, nil)
                    sqlite3_bind_text(statement, 2, visit.url, -1, nil)
                    sqlite3_bind_text(statement, 3, visit.title, -1, nil)
                    sqlite3_bind_text(statement, 4, visit.domain, -1, nil)
                    sqlite3_bind_text(statement, 5, DatabaseTime.isoFormatter.string(from: visit.visitedAt), -1, nil)
                    sqlite3_bind_int(statement, 6, Int32(visit.visitCount))
                }, database: database) else { return false }
            }

            guard execute("DELETE FROM daily_notes WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
            for note in record.notesModified {
                let sql = "INSERT INTO daily_notes (date, title, modified_at) VALUES (?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, record.date, -1, nil)
                    sqlite3_bind_text(statement, 2, note.title, -1, nil)
                    sqlite3_bind_text(statement, 3, DatabaseTime.isoFormatter.string(from: note.modifiedAt), -1, nil)
                }, database: database) else { return false }
            }

            guard execute("DELETE FROM activity_sessions WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
            for session in sessions {
                guard bindSession(session, date: record.date, database: database) else { return false }
            }

            guard execute("DELETE FROM quick_captures WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
            for note in record.quickNotes {
                let sql = "INSERT OR REPLACE INTO quick_captures (id, date, text, created_at, source) VALUES (?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, note.id, -1, nil)
                    sqlite3_bind_text(statement, 2, record.date, -1, nil)
                    sqlite3_bind_text(statement, 3, note.text, -1, nil)
                    sqlite3_bind_text(statement, 4, note.createdAt.map(DatabaseTime.isoFormatter.string), -1, nil)
                    sqlite3_bind_text(statement, 5, note.source, -1, nil)
                }, database: database) else { return false }
            }

            return true
        }
    }

    // MARK: Queries

    func queryDailyRecord(date: String) -> DBDailyRecord? {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return nil }
            let sql = "SELECT * FROM daily_records WHERE date = ? LIMIT 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, date, -1, nil)
            if sqlite3_step(statement) == SQLITE_ROW {
                return readDailyRecord(statement)
            }
            return nil
        }
    }

    func queryDailyRecords(limit: Int = 365) -> [DBDailyRecord] {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return [] }
            let sql = "SELECT * FROM daily_records ORDER BY date DESC LIMIT ?"
            var results: [DBDailyRecord] = []
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            while sqlite3_step(statement) == SQLITE_ROW {
                results.append(readDailyRecord(statement))
            }
            return results
        }
    }

    func queryAvailableDates(limit: Int = 365) -> [String] {
        queryDailyRecords(limit: limit).map(\.date)
    }

    func queryChromeVisits(date: String) -> [DBChromeVisit] {
        query(
            "SELECT id, date, url, title, domain, visited_at, visit_count FROM chrome_visits WHERE date = ? ORDER BY visited_at DESC",
            bindings: bindText(date)
        ) { statement in
            DBChromeVisit(
                id: Int(sqlite3_column_int64(statement, 0)),
                date: text(statement, 1),
                url: text(statement, 2),
                title: text(statement, 3),
                domain: text(statement, 4),
                visitedAt: text(statement, 5),
                visitCount: Int(sqlite3_column_int(statement, 6))
            )
        }
    }

    func queryDailyNotes(date: String) -> [DBDailyNote] {
        query(
            "SELECT id, date, title, modified_at FROM daily_notes WHERE date = ? ORDER BY modified_at DESC",
            bindings: bindText(date)
        ) { statement in
            DBDailyNote(
                id: Int(sqlite3_column_int64(statement, 0)),
                date: text(statement, 1),
                title: text(statement, 2),
                modifiedAt: text(statement, 3)
            )
        }
    }

    func queryActivitySessions(date: String) -> [DBActivitySession] {
        query(
            "SELECT id, date, app_name, bundle_id, category, start_time, end_time, duration_minutes, window_title FROM activity_sessions WHERE date = ? ORDER BY start_time",
            bindings: bindText(date)
        ) { statement in
            let title = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : text(statement, 8)
            return DBActivitySession(
                id: text(statement, 0),
                date: text(statement, 1),
                appName: text(statement, 2),
                category: text(statement, 4),
                startTime: text(statement, 5),
                endTime: text(statement, 6),
                durationMinutes: Int(sqlite3_column_int(statement, 7)),
                windowTitle: title
            )
        }
    }

    func queryQuickCaptures(date: String) -> [DBQuickCapture] {
        query(
            "SELECT id, date, text, created_at, source FROM quick_captures WHERE date = ? ORDER BY created_at",
            bindings: bindText(date)
        ) { statement in
            DBQuickCapture(
                id: text(statement, 0),
                date: text(statement, 1),
                text: text(statement, 2),
                createdAt: text(statement, 3),
                source: text(statement, 4)
            )
        }
    }

    func queryMoodScore(date: String) -> DBMoodScore? {
        queryOne(
            "SELECT date, score, source FROM mood_scores WHERE date = ? LIMIT 1",
            bindings: bindText(date)
        ) { DBMoodScore(date: text($0, 0), score: Int(sqlite3_column_int($0, 1)), source: text($0, 2)) }
    }

    func querySleepNight(date: String) -> DBSleepNight? {
        queryOne(
            "SELECT date, total_hours, deep_minutes, rem_minutes, awake_minutes FROM sleep_nights WHERE date = ? LIMIT 1",
            bindings: bindText(date)
        ) {
            DBSleepNight(
                date: text($0, 0),
                totalHours: sqlite3_column_double($0, 1),
                deepMinutes: sqlite3_column_double($0, 2),
                remMinutes: sqlite3_column_double($0, 3),
                awakeMinutes: sqlite3_column_double($0, 4)
            )
        }
    }

    func queryExerciseDay(date: String) -> DBExerciseDay? {
        queryOne(
            "SELECT date, steps, distance_km, active_energy_kcal FROM exercise_days WHERE date = ? LIMIT 1",
            bindings: bindText(date)
        ) {
            DBExerciseDay(
                date: text($0, 0),
                steps: Int(sqlite3_column_int($0, 1)),
                distanceKM: sqlite3_column_double($0, 2),
                activeEnergyKcal: sqlite3_column_double($0, 3)
            )
        }
    }

    // MARK: AI Archive

    @discardableResult
    func saveAIResult(
        resultKey: String,
        startDate: String,
        endDate: String,
        task: String,
        model: String,
        answer: String,
        createdAt: Date = Date()
    ) -> Bool {
        transaction { database in
            execute(
                """
                INSERT OR REPLACE INTO ai_results
                (result_key, start_date, end_date, task, model, answer, created_at)
                VALUES (?,?,?,?,?,?,?)
                """,
                bindings: { statement in
                    sqlite3_bind_text(statement, 1, resultKey, -1, nil)
                    sqlite3_bind_text(statement, 2, startDate, -1, nil)
                    sqlite3_bind_text(statement, 3, endDate, -1, nil)
                    sqlite3_bind_text(statement, 4, task, -1, nil)
                    sqlite3_bind_text(statement, 5, model, -1, nil)
                    sqlite3_bind_text(statement, 6, answer, -1, nil)
                    sqlite3_bind_text(statement, 7, DatabaseTime.isoFormatter.string(from: createdAt), -1, nil)
                },
                database: database
            )
        }
    }

    func queryAIResults(startDate: String, endDate: String) -> [DBAIResult] {
        query(
            """
            SELECT result_key, start_date, end_date, task, model, answer, created_at
            FROM ai_results WHERE start_date = ? AND end_date = ? ORDER BY created_at DESC
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, nil)
                sqlite3_bind_text($0, 2, endDate, -1, nil)
            }
        ) { statement in
            DBAIResult(
                resultKey: text(statement, 0),
                startDate: text(statement, 1),
                endDate: text(statement, 2),
                task: text(statement, 3),
                model: text(statement, 4),
                answer: text(statement, 5),
                createdAt: text(statement, 6)
            )
        }
    }

    func queryRecentAIResults(limit: Int = 30) -> [DBAIResult] {
        query(
            """
            SELECT result_key, start_date, end_date, task, model, answer, created_at
            FROM ai_results ORDER BY created_at DESC LIMIT ?
            """,
            bindings: { sqlite3_bind_int($0, 1, Int32(limit)) }
        ) { statement in
            DBAIResult(
                resultKey: text(statement, 0),
                startDate: text(statement, 1),
                endDate: text(statement, 2),
                task: text(statement, 3),
                model: text(statement, 4),
                answer: text(statement, 5),
                createdAt: text(statement, 6)
            )
        }
    }

    // MARK: Cross-day Query

    func queryCrossDaySnapshot(startDate: String, endDate: String, searchText: String = "", limitPerType: Int = 200) -> DatabaseCrossDaySnapshot {
        let pattern = "%\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))%"
        var snapshot = DatabaseCrossDaySnapshot(startDate: startDate, endDate: endDate, query: searchText)

        snapshot.dailyRecords = queryDailyRecords(limit: 1000).filter { $0.date >= startDate && $0.date <= endDate }
        snapshot.chromeVisits = query(
            """
            SELECT id, date, url, title, domain, visited_at, visit_count
            FROM chrome_visits
            WHERE date BETWEEN ? AND ? AND (? = '' OR lower(url) LIKE lower(?) OR lower(title) LIKE lower(?) OR lower(domain) LIKE lower(?))
            ORDER BY date DESC, visited_at DESC LIMIT ?
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, nil)
                sqlite3_bind_text($0, 2, endDate, -1, nil)
                sqlite3_bind_text($0, 3, searchText.trimmingCharacters(in: .whitespacesAndNewlines), -1, nil)
                sqlite3_bind_text($0, 4, pattern, -1, nil)
                sqlite3_bind_text($0, 5, pattern, -1, nil)
                sqlite3_bind_text($0, 6, pattern, -1, nil)
                sqlite3_bind_int($0, 7, Int32(limitPerType))
            }
        ) { statement in
            DBChromeVisit(
                id: Int(sqlite3_column_int64(statement, 0)),
                date: text(statement, 1),
                url: text(statement, 2),
                title: text(statement, 3),
                domain: text(statement, 4),
                visitedAt: text(statement, 5),
                visitCount: Int(sqlite3_column_int(statement, 6))
            )
        }

        snapshot.notes = query(
            """
            SELECT id, date, title, modified_at FROM daily_notes
            WHERE date BETWEEN ? AND ? AND (? = '' OR lower(title) LIKE lower(?))
            ORDER BY date DESC, modified_at DESC LIMIT ?
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, nil)
                sqlite3_bind_text($0, 2, endDate, -1, nil)
                sqlite3_bind_text($0, 3, searchText.trimmingCharacters(in: .whitespacesAndNewlines), -1, nil)
                sqlite3_bind_text($0, 4, pattern, -1, nil)
                sqlite3_bind_int($0, 5, Int32(limitPerType))
            }
        ) { statement in
            DBDailyNote(
                id: Int(sqlite3_column_int64(statement, 0)),
                date: text(statement, 1),
                title: text(statement, 2),
                modifiedAt: text(statement, 3)
            )
        }

        snapshot.sessions = query(
            """
            SELECT id, date, app_name, bundle_id, category, start_time, end_time, duration_minutes, window_title
            FROM activity_sessions
            WHERE date BETWEEN ? AND ? AND (? = '' OR lower(app_name) LIKE lower(?) OR lower(category) LIKE lower(?) OR lower(coalesce(window_title, '')) LIKE lower(?))
            ORDER BY date DESC, start_time DESC LIMIT ?
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, nil)
                sqlite3_bind_text($0, 2, endDate, -1, nil)
                sqlite3_bind_text($0, 3, searchText.trimmingCharacters(in: .whitespacesAndNewlines), -1, nil)
                sqlite3_bind_text($0, 4, pattern, -1, nil)
                sqlite3_bind_text($0, 5, pattern, -1, nil)
                sqlite3_bind_text($0, 6, pattern, -1, nil)
                sqlite3_bind_int($0, 7, Int32(limitPerType))
            }
        ) { statement in
            let title = sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : text(statement, 8)
            return DBActivitySession(
                id: text(statement, 0),
                date: text(statement, 1),
                appName: text(statement, 2),
                category: text(statement, 4),
                startTime: text(statement, 5),
                endTime: text(statement, 6),
                durationMinutes: Int(sqlite3_column_int(statement, 7)),
                windowTitle: title
            )
        }

        snapshot.quickCaptures = query(
            """
            SELECT id, date, text, created_at, source FROM quick_captures
            WHERE date BETWEEN ? AND ? AND (? = '' OR lower(text) LIKE lower(?) OR lower(source) LIKE lower(?))
            ORDER BY date DESC, created_at DESC LIMIT ?
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, nil)
                sqlite3_bind_text($0, 2, endDate, -1, nil)
                sqlite3_bind_text($0, 3, searchText.trimmingCharacters(in: .whitespacesAndNewlines), -1, nil)
                sqlite3_bind_text($0, 4, pattern, -1, nil)
                sqlite3_bind_text($0, 5, pattern, -1, nil)
                sqlite3_bind_int($0, 6, Int32(limitPerType))
            }
        ) { statement in
            DBQuickCapture(
                id: text(statement, 0),
                date: text(statement, 1),
                text: text(statement, 2),
                createdAt: text(statement, 3),
                source: text(statement, 4)
            )
        }

        return snapshot
    }

    // MARK: Retention

    @discardableResult
    func purgeData(before cutoffDate: String) -> Bool {
        transaction { database in
            for table in ["daily_records", "mood_scores", "sleep_nights", "exercise_days", "chrome_visits", "daily_notes", "activity_sessions", "quick_captures"] {
                let column = table == "activity_sessions" ? "date" : "date"
                guard execute("DELETE FROM \(table) WHERE \(column) < ?", bindings: { sqlite3_bind_text($0, 1, cutoffDate, -1, nil) }, database: database) else { return false }
            }
            return execute("DELETE FROM ai_results WHERE end_date < ?", bindings: { sqlite3_bind_text($0, 1, cutoffDate, -1, nil) }, database: database)
        }
    }

    // MARK: Binding Helpers

    func bindDailyRecord(_ record: DailyCaptureRecord, sessionCount: Int, database: OpaquePointer) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO daily_records
            (date, captured_at, mood_score, sleep_hours, exercise_steps, screen_time_minutes,
             chrome_visit_count, notes_count, session_count, quick_capture_count, mixed_overview, ios_data_available)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """
        return execute(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, record.date, -1, nil)
            sqlite3_bind_text(statement, 2, DatabaseTime.isoFormatter.string(from: record.capturedAt), -1, nil)
            if let mood = record.moodScore {
                sqlite3_bind_int(statement, 3, Int32(mood))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            if let sleepHours = record.sleepHours {
                sqlite3_bind_double(statement, 4, sleepHours)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            if let exerciseSteps = record.exerciseSteps {
                sqlite3_bind_int(statement, 5, Int32(exerciseSteps))
            } else {
                sqlite3_bind_null(statement, 5)
            }
            if let screenTimeMinutes = record.screenTimeMinutes {
                sqlite3_bind_int(statement, 6, Int32(screenTimeMinutes))
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_int(statement, 7, Int32(record.chromeVisits.count))
            sqlite3_bind_int(statement, 8, Int32(record.notesModified.count))
            sqlite3_bind_int(statement, 9, Int32(sessionCount))
            sqlite3_bind_int(statement, 10, Int32(record.quickNotes.count))
            sqlite3_bind_text(statement, 11, record.mixedOverview, -1, nil)
            sqlite3_bind_int(statement, 12, record.iosDataAvailable ? 1 : 0)
        }, database: database)
    }

    private func bindSession(_ session: ActivitySession, date: String, database: OpaquePointer) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO activity_sessions
            (id, date, app_name, bundle_id, category, start_time, end_time, duration_minutes, window_title)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
        return execute(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, session.id.uuidString, -1, nil)
            sqlite3_bind_text(statement, 2, date, -1, nil)
            sqlite3_bind_text(statement, 3, session.appName, -1, nil)
            sqlite3_bind_text(statement, 4, session.bundleID, -1, nil)
            sqlite3_bind_text(statement, 5, session.category, -1, nil)
            sqlite3_bind_text(statement, 6, DatabaseTime.isoFormatter.string(from: session.start), -1, nil)
            sqlite3_bind_text(statement, 7, DatabaseTime.isoFormatter.string(from: session.end), -1, nil)
            sqlite3_bind_int(statement, 8, Int32((session.duration / 60).rounded()))
            if let title = session.windowTitle {
                sqlite3_bind_text(statement, 9, title, -1, nil)
            } else {
                sqlite3_bind_null(statement, 9)
            }
        }, database: database)
    }

    func execute(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard let preparedStatement = statement else { return false }
        bindings?(preparedStatement)
        return sqlite3_step(preparedStatement) == SQLITE_DONE
    }

    private func bindText(_ value: String) -> (OpaquePointer) -> Void {
        { statement in sqlite3_bind_text(statement, 1, value, -1, nil) }
    }

    // MARK: Query Helpers

    private func query<T>(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil, read: (OpaquePointer) -> T) -> [T] {
        queue.sync { [weak self] in
            guard let self, self.db != nil else { return [] }
            return self.runQuery(sql, bindings: bindings, read: read)
        }
    }

    private func queryOne<T>(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil, read: (OpaquePointer) -> T) -> T? {
        queue.sync { [weak self] in
            guard let self, self.db != nil else { return nil }
            return self.runQuery(sql, bindings: bindings, read: read).first
        }
    }

    private func runQuery<T>(_ sql: String, bindings: ((OpaquePointer) -> Void)?, read: (OpaquePointer) -> T) -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        guard let preparedStatement = statement else { return [] }
        bindings?(preparedStatement)
        var results: [T] = []
        while sqlite3_step(preparedStatement) == SQLITE_ROW {
            results.append(read(preparedStatement))
        }
        return results
    }

    private func readDailyRecord(_ statement: OpaquePointer?) -> DBDailyRecord {
        let optionalInt: (Int32) -> Int? = { index in
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index))
        }
        let optionalDouble: (Int32) -> Double? = { index in
            sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
        }

        return DBDailyRecord(
            date: text(statement, 0),
            capturedAt: text(statement, 1),
            moodScore: optionalInt(2),
            sleepHours: optionalDouble(3),
            exerciseSteps: optionalInt(4),
            screenTimeMinutes: optionalInt(5),
            chromeVisitCount: Int(sqlite3_column_int(statement, 6)),
            notesCount: Int(sqlite3_column_int(statement, 7)),
            sessionCount: Int(sqlite3_column_int(statement, 8)),
            quickCaptureCount: Int(sqlite3_column_int(statement, 9)),
            mixedOverview: text(statement, 10),
            iosDataAvailable: sqlite3_column_int(statement, 11) == 1
        )
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }
}
