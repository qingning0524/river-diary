import Foundation
import SQLCipher
// MARK: - Database

final class AppDatabase {
    static let shared = AppDatabase()

    /// SQLITE_TRANSIENT: SQLite copies the bound buffer at bind time. Binding a
    /// bridged Swift String with `nil` (SQLITE_STATIC) leaves SQLite reading a
    /// temporary buffer at step() time — a dangling pointer.
    static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    var db: OpaquePointer?
    let queue = DispatchQueue(label: "studio.riverdiary.database", qos: .utility)
    /// lastError 会从 DB 串行队列（transaction 内部）和调用方线程（open/restore
    /// 路径）同时读写，String 的并发写不是原子的；用锁隔离，读写点无需改动。
    private let lastErrorLock = NSLock()
    private var lastErrorStorage: String?
    private(set) var lastError: String? {
        get { lastErrorLock.lock(); defer { lastErrorLock.unlock() }; return lastErrorStorage }
        set { lastErrorLock.lock(); defer { lastErrorLock.unlock() }; lastErrorStorage = newValue }
    }
    private let configuredDatabaseURL: URL?

    private var databasePath: URL? {
        if let configuredDatabaseURL {
            do {
                try LocalStorageProtection.ensurePrivateDirectory(at: configuredDatabaseURL.deletingLastPathComponent())
                return configuredDatabaseURL
            } catch {
                lastError = "数据库目录权限设置失败：\(error.localizedDescription)"
                return nil
            }
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
        do {
            try LocalStorageProtection.ensurePrivateDirectory(
                at: base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
            )
            try LocalStorageProtection.ensurePrivateDirectory(at: directory)
            return directory.appendingPathComponent("river-diary.db")
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    init(databaseURL: URL? = nil) {
        configuredDatabaseURL = databaseURL
        open()
        createTables()
        migrateTables()
    }

    deinit {
        close()
    }

    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    /// 启动期崩溃恢复在文件层面替换了数据库；持有该文件的连接必须重开到
    /// 新文件，否则读到旧数据、写入落在已解绑的 inode 上静默丢失。
    /// 只在 URL 匹配时重开（测试环境共享单例指向真实用户库，不匹配就不动）。
    /// 在串行队列上执行，避免与进行中的读写竞争。
    func reopenAfterFileReplacementIfNecessary(url: URL) {
        let needsReopen: Bool = queue.sync { [self] in
            databasePath == url
        }
        guard needsReopen else { return }
        queue.sync { [self] in
            close()
            open()
            createTables()
            migrateTables()
        }
    }

    func encryptedSnapshot() throws -> Data {
        try queue.sync {
            guard let db, let path = databasePath else {
                throw DatabaseCipherError.invalidDatabase("兼容数据库尚未打开")
            }
            return try DatabaseCipher.encryptedSnapshot(
                of: db,
                purpose: "legacy-records-v1",
                in: path.deletingLastPathComponent()
            )
        }
    }

    func validateEncryptedSnapshot(_ snapshot: Data) throws {
        guard let path = databasePath else {
            throw DatabaseCipherError.invalidDatabase("兼容数据库路径不可用")
        }
        try DatabaseCipher.validateEncryptedSnapshot(
            snapshot,
            purpose: "legacy-records-v1",
            in: path.deletingLastPathComponent()
        )
    }

    func restoreEncryptedSnapshot(_ snapshot: Data) throws {
        guard let path = databasePath else {
            throw DatabaseCipherError.invalidDatabase("兼容数据库路径不可用")
        }
        try validateEncryptedSnapshot(snapshot)

        try queue.sync {
            guard let currentDatabase = db else {
                throw DatabaseCipherError.invalidDatabase("兼容数据库尚未打开")
            }
            sqlite3_exec(currentDatabase, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
            guard sqlite3_close(currentDatabase) == SQLITE_OK else {
                throw DatabaseCipherError.invalidDatabase("兼容数据库正在使用，无法安全恢复")
            }
            db = nil

            do {
                try DatabaseCipher.replaceEncryptedDatabase(
                    at: path,
                    with: snapshot,
                    purpose: "legacy-records-v1"
                )
                db = try DatabaseCipher.open(at: path, purpose: "legacy-records-v1")
                sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
                sqlite3_exec(db, "PRAGMA synchronous=FULL;", nil, nil, nil)
                sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
            } catch {
                db = try? DatabaseCipher.open(at: path, purpose: "legacy-records-v1")
                throw error
            }
        }

        createTables()
        migrateTables()
    }

    // MARK: Setup

    private func open() {
        guard let path = databasePath else { return }
        do {
            db = try DatabaseCipher.open(at: path, purpose: "legacy-records-v1")
        } catch {
            lastError = "数据库无法安全打开：\(error.localizedDescription)"
            db = nil
            return
        }
        // WAL journaling + full sync reduce the risk of a half-written transaction
        // being left behind by a crash or power loss; busy_timeout keeps concurrent
        // readers/writers from failing spuriously.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=FULL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
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
            "CREATE INDEX IF NOT EXISTS idx_chrome_date_visited ON chrome_visits(date, visited_at)",
            "CREATE INDEX IF NOT EXISTS idx_notes_date ON daily_notes(date)",
            "CREATE INDEX IF NOT EXISTS idx_notes_date_modified ON daily_notes(date, modified_at)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_date ON activity_sessions(date)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_date_start ON activity_sessions(date, start_time)",
            "CREATE INDEX IF NOT EXISTS idx_captures_date ON quick_captures(date)",
            "CREATE INDEX IF NOT EXISTS idx_captures_date_created ON quick_captures(date, created_at)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_start ON activity_sessions(start_time)",
            """
            CREATE TABLE IF NOT EXISTS ai_results (
                result_key TEXT PRIMARY KEY,
                start_date TEXT NOT NULL,
                end_date TEXT NOT NULL,
                task TEXT NOT NULL,
                model TEXT NOT NULL,
                answer TEXT NOT NULL,
                source_summary TEXT DEFAULT '',
                created_at TEXT NOT NULL,
                is_local INTEGER DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_ai_results_range ON ai_results(start_date, end_date)",
            "CREATE INDEX IF NOT EXISTS idx_ai_results_created ON ai_results(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_ai_results_task_range ON ai_results(task, start_date, end_date)"
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
        if let path = databasePath {
            do {
                try LocalStorageProtection.protectFile(at: path)
            } catch {
                lastError = "数据库权限设置失败：\(error.localizedDescription)"
            }
        }
    }

    private func migrateTables() {
        _ = transaction { database in
            guard addColumnIfMissing("visited_at", "TEXT", to: "chrome_visits", database: database) else { return false }
            guard addColumnIfMissing("bundle_id", "TEXT DEFAULT ''", to: "activity_sessions", database: database) else { return false }
            guard addColumnIfMissing("source_summary", "TEXT DEFAULT ''", to: "ai_results", database: database) else { return false }
            guard addColumnIfMissing("is_local", "INTEGER DEFAULT 0", to: "ai_results", database: database) else { return false }
            return true
        }
    }

    private func addColumnIfMissing(_ column: String, _ definition: String, to table: String, database: OpaquePointer) -> Bool {
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
        guard !exists else { return true }
        var statement: OpaquePointer?
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(definition)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard let statement else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func transaction(_ work: (OpaquePointer) -> Bool) -> Bool {
        queue.sync { [weak self] in
            guard let self, let db = self.db else { return false }
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                self.lastError = databaseError(db)
                return false
            }
            let success = work(db)
            guard success else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                if self.lastError == nil { self.lastError = databaseError(db) }
                return false
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                self.lastError = databaseError(db)
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return false
            }
            self.lastError = nil
            return true
        }
    }

    // MARK: Complete Daily Capture

    @discardableResult
    func saveDailyCapture(
        _ record: DailyCaptureRecord,
        sessions: [ActivitySession],
        collectedChrome: Bool = true,
        collectedNotes: Bool = true,
        collectedHealth: Bool = true,
        collectedScreenTime: Bool = true
    ) -> Bool {
        transaction { database in
            // Preserve previously captured data for any source that did not run this
            // cycle (e.g. a collector was toggled off, or a permissions failure yielded
            // an empty read). Without this, a disabled collector would silently erase
            // data that was already captured for the day.
            var moodScore = record.moodScore
            var sleepHours = record.sleepHours
            var exerciseSteps = record.exerciseSteps
            var chromeCount = record.chromeVisits.count
            var notesCount = record.notesModified.count
            var quickCaptureCount = record.quickNotes.count
            var screenMinutes = record.screenTimeMinutes

            if let existing = existingDailyRecord(date: record.date, database: database) {
                // 两类都要保留：采集器没跑（开关关闭/权限失败），以及跑了但
                // 本次 payload 里没有当天数据（如一天内第二次同步缺健康值）——
                // 后者此前会把 summary 列抹成 NULL，而明细表还留着旧值。
                if !collectedChrome || (collectedChrome && record.chromeVisits.isEmpty) { chromeCount = collectedChrome ? max(existing.chromeVisitCount, chromeCount) : existing.chromeVisitCount }
                if !collectedNotes || (collectedNotes && record.notesModified.isEmpty) { notesCount = collectedNotes ? max(existing.notesCount, notesCount) : existing.notesCount }
                if !collectedHealth || record.moodScore == nil { moodScore = existing.moodScore ?? moodScore }
                if !collectedHealth || record.sleepHours == nil { sleepHours = existing.sleepHours ?? sleepHours }
                if !collectedHealth || record.exerciseSteps == nil { exerciseSteps = existing.exerciseSteps ?? exerciseSteps }
                if !collectedHealth || record.quickNotes.isEmpty { quickCaptureCount = max(existing.quickCaptureCount, quickCaptureCount) }
                if !collectedScreenTime || record.screenTimeMinutes == nil { screenMinutes = existing.screenTimeMinutes ?? screenMinutes }
            }

            guard upsertDailyRecord(
                record,
                moodScore: moodScore,
                sleepHours: sleepHours,
                exerciseSteps: exerciseSteps,
                screenTimeMinutes: screenMinutes,
                chromeCount: chromeCount,
                notesCount: notesCount,
                sessionCount: sessions.count,
                quickCaptureCount: quickCaptureCount,
                database: database
            ) else { return false }

            if let mood = record.moodScore {
                let sql = "INSERT OR REPLACE INTO mood_scores (date, score, source) VALUES (?,?,'iOS 健康')"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, record.date, -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 2, Int32(mood))
                }, database: database) else { return false }
            }

            if let sleep = record.sleep {
                let sql = "INSERT OR REPLACE INTO sleep_nights (date, total_hours, deep_minutes, rem_minutes, awake_minutes) VALUES (?,?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, sleep.date, -1, Self.transientDestructor)
                    sqlite3_bind_double(statement, 2, sleep.totalHours)
                    sqlite3_bind_double(statement, 3, sleep.deepMinutes)
                    sqlite3_bind_double(statement, 4, sleep.remMinutes)
                    sqlite3_bind_double(statement, 5, sleep.awakeMinutes)
                }, database: database) else { return false }
            }

            if let exercise = record.exercise {
                let sql = "INSERT OR REPLACE INTO exercise_days (date, steps, distance_km, active_energy_kcal) VALUES (?,?,?,?)"
                guard execute(sql, bindings: { statement in
                    sqlite3_bind_text(statement, 1, exercise.date, -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 2, Int32(exercise.steps))
                    sqlite3_bind_double(statement, 3, exercise.distanceKilometers)
                    sqlite3_bind_double(statement, 4, exercise.activeEnergyKilocalories)
                }, database: database) else { return false }
            }

            if collectedChrome {
                guard execute("DELETE FROM chrome_visits WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
                for visit in record.chromeVisits {
                    let sql = "INSERT INTO chrome_visits (date, url, title, domain, visited_at, visit_count) VALUES (?,?,?,?,?,?)"
                    guard execute(sql, bindings: { statement in
                        sqlite3_bind_text(statement, 1, record.date, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 2, visit.url, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 3, visit.title, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 4, visit.domain, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 5, DatabaseTime.isoFormatter.string(from: visit.visitedAt), -1, Self.transientDestructor)
                        sqlite3_bind_int(statement, 6, Int32(visit.visitCount))
                    }, database: database) else { return false }
                }
            }

            if collectedNotes {
                guard execute("DELETE FROM daily_notes WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
                for note in record.notesModified {
                    let sql = "INSERT INTO daily_notes (date, title, modified_at) VALUES (?,?,?)"
                    guard execute(sql, bindings: { statement in
                        sqlite3_bind_text(statement, 1, record.date, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 2, note.title, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 3, DatabaseTime.isoFormatter.string(from: note.modifiedAt), -1, Self.transientDestructor)
                    }, database: database) else { return false }
                }
            }

            guard execute("DELETE FROM activity_sessions WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
            for session in sessions {
                guard bindSession(session, date: record.date, database: database) else { return false }
            }

            if collectedHealth {
                guard execute("DELETE FROM quick_captures WHERE date = ?", bindings: bindText(record.date), database: database) else { return false }
                for note in record.quickNotes {
                    let sql = "INSERT OR REPLACE INTO quick_captures (id, date, text, created_at, source) VALUES (?,?,?,?,?)"
                    guard execute(sql, bindings: { statement in
                        sqlite3_bind_text(statement, 1, note.id, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 2, record.date, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 3, note.text, -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 4, note.createdAt.map(DatabaseTime.isoFormatter.string), -1, Self.transientDestructor)
                        sqlite3_bind_text(statement, 5, note.source, -1, Self.transientDestructor)
                    }, database: database) else { return false }
                }
            }

            return true
        }
    }

    /// Reads an existing `daily_records` row within the current transaction so callers
    /// can preserve non-collected summary columns instead of resetting them to zero.
    func existingDailyRecord(date: String, database: OpaquePointer) -> DBDailyRecord? {
        let sql = "SELECT * FROM daily_records WHERE date = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, date, -1, Self.transientDestructor)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readDailyRecord(statement)
    }

    /// Upserts the `daily_records` summary row, writing through the provided aggregate
    /// values (which may have been preserved from a prior capture for non-collected sources).
    func upsertDailyRecord(
        _ record: DailyCaptureRecord,
        moodScore: Int?,
        sleepHours: Double?,
        exerciseSteps: Int?,
        screenTimeMinutes: Int?,
        chromeCount: Int,
        notesCount: Int,
        sessionCount: Int,
        quickCaptureCount: Int,
        database: OpaquePointer
    ) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO daily_records
            (date, captured_at, mood_score, sleep_hours, exercise_steps, screen_time_minutes,
             chrome_visit_count, notes_count, session_count, quick_capture_count, mixed_overview, ios_data_available)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """
        return execute(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, record.date, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 2, DatabaseTime.isoFormatter.string(from: record.capturedAt), -1, Self.transientDestructor)
            self.sqlite3_bind_int_or_null(statement, 3, moodScore)
            self.sqlite3_bind_double_or_null(statement, 4, sleepHours)
            self.sqlite3_bind_int_or_null(statement, 5, exerciseSteps)
            self.sqlite3_bind_int_or_null(statement, 6, screenTimeMinutes)
            sqlite3_bind_int(statement, 7, Int32(chromeCount))
            sqlite3_bind_int(statement, 8, Int32(notesCount))
            sqlite3_bind_int(statement, 9, Int32(sessionCount))
            sqlite3_bind_int(statement, 10, Int32(quickCaptureCount))
            sqlite3_bind_text(statement, 11, record.mixedOverview, -1, Self.transientDestructor)
            sqlite3_bind_int(statement, 12, record.iosDataAvailable ? 1 : 0)
        }, database: database)
    }

    // MARK: Queries

 

 

 

 

 

 

 

 

 

 

    // MARK: AI Archive

    @discardableResult
    func saveAIResult(
        resultKey: String,
        startDate: String,
        endDate: String,
        task: String,
        model: String,
        answer: String,
        sourceSummary: String = "",
        createdAt: Date = Date(),
        isLocal: Bool = false
    ) -> Bool {
        transaction { database in
            execute(
                """
                INSERT OR REPLACE INTO ai_results
                (result_key, start_date, end_date, task, model, answer, source_summary, created_at, is_local)
                VALUES (?,?,?,?,?,?,?,?,?)
                """,
                bindings: { statement in
                    sqlite3_bind_text(statement, 1, resultKey, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 2, startDate, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 3, endDate, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 4, task, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 5, model, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 6, answer, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 7, sourceSummary, -1, Self.transientDestructor)
                    sqlite3_bind_text(statement, 8, DatabaseTime.isoFormatter.string(from: createdAt), -1, Self.transientDestructor)
                    sqlite3_bind_int(statement, 9, isLocal ? 1 : 0)
                },
                database: database
            )
        }
    }

    /// Read the locally collected Chrome page titles for one day. Callers decide
    /// separately whether this more sensitive context may be sent to an AI model.
    func chromeVisits(for dayKey: String) -> [ChromeVisit] {
        query(
            "SELECT url, title, visited_at, visit_count, domain FROM chrome_visits WHERE date = ? ORDER BY visited_at",
            bindings: bindText(dayKey)
        ) { statement in
            ChromeVisit(
                url: text(statement, 0),
                title: text(statement, 1),
                visitedAt: DatabaseTime.isoFormatter.date(from: text(statement, 2)) ?? Date(timeIntervalSince1970: 0),
                visitCount: Int(sqlite3_column_int(statement, 3)),
                domain: text(statement, 4)
            )
        }
    }

    func dailyNotes(for dayKey: String) -> [DailyNoteEntry] {
        query(
            "SELECT title, modified_at FROM daily_notes WHERE date = ? ORDER BY modified_at",
            bindings: bindText(dayKey)
        ) { statement in
            DailyNoteEntry(
                title: text(statement, 0),
                modifiedAt: DatabaseTime.isoFormatter.date(from: text(statement, 1)) ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    func queryAIResults(startDate: String, endDate: String) -> [DBAIResult] {
        query(
            """
            SELECT result_key, start_date, end_date, task, model, answer, source_summary, created_at, is_local
            FROM ai_results WHERE start_date = ? AND end_date = ? ORDER BY created_at DESC
            """,
            bindings: {
                sqlite3_bind_text($0, 1, startDate, -1, Self.transientDestructor)
                sqlite3_bind_text($0, 2, endDate, -1, Self.transientDestructor)
            }
        ) { statement in
            DBAIResult(
                resultKey: text(statement, 0),
                startDate: text(statement, 1),
                endDate: text(statement, 2),
                task: text(statement, 3),
                model: text(statement, 4),
                answer: text(statement, 5),
                sourceSummary: text(statement, 6),
                createdAt: text(statement, 7),
                isLocal: sqlite3_column_int(statement, 8) == 1
            )
        }
    }

 

    // MARK: Retention

    @discardableResult
    func purgeData(before cutoffDate: String) -> Bool {
        transaction { database in
            for table in ["daily_records", "mood_scores", "sleep_nights", "exercise_days", "chrome_visits", "daily_notes", "activity_sessions", "quick_captures"] {
                guard execute("DELETE FROM \(table) WHERE date < ?", bindings: { sqlite3_bind_text($0, 1, cutoffDate, -1, Self.transientDestructor) }, database: database) else { return false }
            }
            return execute("DELETE FROM ai_results WHERE end_date < ?", bindings: { sqlite3_bind_text($0, 1, cutoffDate, -1, Self.transientDestructor) }, database: database)
        }
    }

    // MARK: Binding Helpers

    private func bindSession(_ session: ActivitySession, date: String, database: OpaquePointer) -> Bool {
        let sql = """
            INSERT OR REPLACE INTO activity_sessions
            (id, date, app_name, bundle_id, category, start_time, end_time, duration_minutes, window_title)
            VALUES (?,?,?,?,?,?,?,?,?)
            """
        return execute(sql, bindings: { statement in
            sqlite3_bind_text(statement, 1, session.id.uuidString, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 2, date, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 3, session.appName, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 4, session.bundleID, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 5, session.category, -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 6, DatabaseTime.isoFormatter.string(from: session.start), -1, Self.transientDestructor)
            sqlite3_bind_text(statement, 7, DatabaseTime.isoFormatter.string(from: session.end), -1, Self.transientDestructor)
            sqlite3_bind_int(statement, 8, Int32((session.duration / 60).rounded()))
            if let title = session.windowTitle {
                sqlite3_bind_text(statement, 9, title, -1, Self.transientDestructor)
            } else {
                sqlite3_bind_null(statement, 9)
            }
        }, database: database)
    }

    func execute(_ sql: String, bindings: ((OpaquePointer) -> Void)? = nil, database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = databaseError(database)
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard let preparedStatement = statement else {
            lastError = "数据库语句为空"
            return false
        }
        bindings?(preparedStatement)
        guard sqlite3_step(preparedStatement) == SQLITE_DONE else {
            lastError = databaseError(database)
            return false
        }
        return true
    }

    private func bindText(_ value: String) -> (OpaquePointer) -> Void {
        { statement in sqlite3_bind_text(statement, 1, value, -1, Self.transientDestructor) }
    }

    private func sqlite3_bind_int_or_null(_ statement: OpaquePointer, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(statement, index, Int32(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func sqlite3_bind_double_or_null(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
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

    private func databaseError(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}
