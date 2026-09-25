import Foundation
import SQLCipher

enum V2Table: String, CaseIterable, Identifiable {
    case rawEvents = "raw_events"
    case activities
    case episodes
    case memories
    case contextSnapshots = "context_snapshots"
    case analysisRuns = "analysis_runs"
    case episodeAnnotations = "episode_annotations"
    case memoryConfirmations = "memory_confirmations"
    case userPrefs = "user_prefs"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rawEvents: "原始事件"
        case .activities: "活动"
        case .episodes: "时间段"
        case .memories: "长期记忆"
        case .contextSnapshots: "上下文快照"
        case .analysisRuns: "分析运行"
        case .episodeAnnotations: "片段标注"
        case .memoryConfirmations: "记忆确认"
        case .userPrefs: "用户设置"
        }
    }
}

/// V2: a single SQLite file for the Memory OS fact layer.
///
/// Ownership rules:
/// - `raw_events` are immutable evidence; append-only.
/// - `activities`, `episodes`, `memories`, `analysis_runs` are derived and
///   rebuildable from evidence without losing user facts.
/// - UI never writes raw_events; AI writes only analysis_runs.
///
/// This release only creates the schema and hands the fact layer safe
/// append/query helpers. It does not migrate or duplicate the legacy DB.
@MainActor
final class V2Store {
    private(set) var db: OpaquePointer?
    private(set) var lastError: String?

    private let databaseURL: URL?

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Location

    private static func defaultDatabaseURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("V2", isDirectory: true)
        do {
            try LocalStorageProtection.ensurePrivateDirectory(
                at: base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
            )
            try LocalStorageProtection.ensurePrivateDirectory(
                at: directory.deletingLastPathComponent()
            )
            try LocalStorageProtection.ensurePrivateDirectory(at: directory)
            return directory.appendingPathComponent("river-v2.db")
        } catch {
            return nil
        }
    }

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        open()
        createSchema()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    // MARK: Open

    private func open() {
        guard let url = databaseURL else {
            lastError = "V2 数据库路径不可用"
            return
        }
        do {
            try LocalStorageProtection.ensurePrivateDirectory(at: url.deletingLastPathComponent())
        } catch {
            lastError = "V2 数据库目录权限设置失败：\(error.localizedDescription)"
            return
        }
        do {
            db = try DatabaseCipher.open(at: url, purpose: "v2-facts-v1")
        } catch {
            lastError = "V2 数据库无法安全打开：\(error.localizedDescription)"
            db = nil
        }
    }

    // MARK: Schema

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { lastError = "数据库未打开"; return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            lastError = Self.errorMessage(db, fallback: "SQL 无法准备")
            return false
        }
        let step = sqlite3_step(statement)
        let ok = step == SQLITE_DONE || step == SQLITE_ROW
        if !ok { lastError = Self.errorMessage(db, fallback: "SQL 执行失败") }
        return ok
    }

    private func createSchema() {
        let tables = [
            """
            CREATE TABLE IF NOT EXISTS raw_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                source TEXT NOT NULL,
                kind TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                source_hash TEXT NOT NULL DEFAULT ''
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS activities (
                id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                group_key TEXT NOT NULL,
                primary_app TEXT,
                category TEXT NOT NULL,
                evidence_ids TEXT NOT NULL DEFAULT '[]'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episodes (
                id TEXT PRIMARY KEY,
                start_time REAL NOT NULL,
                end_time REAL NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL DEFAULT '',
                category TEXT NOT NULL,
                confidence INTEGER NOT NULL DEFAULT 0,
                confidence_factors TEXT NOT NULL DEFAULT '[]',
                activity_ids TEXT NOT NULL DEFAULT '[]',
                evidence_ids TEXT NOT NULL DEFAULT '[]'
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL DEFAULT '',
                kind TEXT NOT NULL,
                confidence INTEGER NOT NULL DEFAULT 0,
                source_episode_ids TEXT NOT NULL DEFAULT '[]',
                created_at REAL NOT NULL,
                last_confirmed_at REAL,
                is_user_confirmed INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS context_snapshots (
                id TEXT PRIMARY KEY,
                created_at REAL NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                model TEXT NOT NULL DEFAULT ''
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS analysis_runs (
                id TEXT PRIMARY KEY,
                task TEXT NOT NULL,
                context_ref TEXT,
                output_text TEXT NOT NULL DEFAULT '',
                evidence_ids TEXT NOT NULL DEFAULT '[]',
                model TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS episode_annotations (
                episode_id TEXT PRIMARY KEY,
                annotation_json TEXT NOT NULL DEFAULT '{}',
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS memory_confirmations (
                memory_id TEXT PRIMARY KEY,
                confirmed_at REAL NOT NULL,
                is_confirmed INTEGER NOT NULL DEFAULT 1,
                note TEXT NOT NULL DEFAULT ''
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS user_prefs (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL DEFAULT ''
            )
            """,
        ]
        for sql in tables { execute(sql) }

        let indices = [
            "CREATE INDEX IF NOT EXISTS idx_raw_events_ts ON raw_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_activities_times ON activities(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_episodes_times ON episodes(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_created ON analysis_runs(created_at)",
        ]
        for sql in indices { execute(sql) }
        if let databaseURL {
            do {
                try LocalStorageProtection.protectFile(at: databaseURL)
            } catch {
                lastError = "V2 数据库权限设置失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: Introspection (used by tests)

    func tableNames() -> [String] {
        guard let db else { return [] }
        var names: [String] = []
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let c = sqlite3_column_text(statement, 0) {
                    names.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(statement)
        return names
    }

    func encryptedSnapshot() throws -> Data {
        guard let db, let databaseURL else {
            throw DatabaseCipherError.invalidDatabase("V2 数据库尚未打开")
        }
        return try DatabaseCipher.encryptedSnapshot(
            of: db,
            purpose: "v2-facts-v1",
            in: databaseURL.deletingLastPathComponent()
        )
    }

    func validateEncryptedSnapshot(_ snapshot: Data) throws {
        guard let databaseURL else {
            throw DatabaseCipherError.invalidDatabase("V2 数据库路径不可用")
        }
        try DatabaseCipher.validateEncryptedSnapshot(
            snapshot,
            purpose: "v2-facts-v1",
            in: databaseURL.deletingLastPathComponent()
        )
    }

    func restoreEncryptedSnapshot(_ snapshot: Data) throws {
        guard let databaseURL, let currentDatabase = db else {
            throw DatabaseCipherError.invalidDatabase("V2 数据库尚未打开")
        }
        try validateEncryptedSnapshot(snapshot)
        guard sqlite3_close(currentDatabase) == SQLITE_OK else {
            throw DatabaseCipherError.invalidDatabase("V2 数据库正在使用，无法安全恢复")
        }
        db = nil

        do {
            try DatabaseCipher.replaceEncryptedDatabase(
                at: databaseURL,
                with: snapshot,
                purpose: "v2-facts-v1"
            )
            lastError = nil
            open()
            guard db != nil else {
                throw DatabaseCipherError.invalidDatabase(lastError ?? "恢复后的 V2 数据库无法打开")
            }
            createSchema()
            if let lastError {
                throw DatabaseCipherError.invalidDatabase(lastError)
            }
        } catch {
            if db == nil {
                lastError = nil
                open()
                createSchema()
            }
            throw error
        }
    }

    func indexNames() -> [String] {
        guard let db else { return [] }
        var names: [String] = []
        let sql = "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let c = sqlite3_column_text(statement, 0) {
                    names.append(String(cString: c))
                }
            }
        }
        sqlite3_finalize(statement)
        return names
    }

    func countRows(in table: V2Table) -> Int {
        guard let db else { return 0 }
        let sql = "SELECT COUNT(*) FROM \(table.rawValue)"
        var statement: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            count = Int(sqlite3_column_int64(statement, 0))
        }
        sqlite3_finalize(statement)
        return count
    }

    // MARK: Raw events (evidence; append-only in production)

    @discardableResult
    func insertRawEvent(_ event: RawEvent) -> Bool {
        guard let db else { return false }
        let payload = encodeJSON(event.payload) ?? "{}"
        let sql = """
        INSERT OR REPLACE INTO raw_events(id, timestamp, source, kind, payload_json, source_hash)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare raw insert")
            return false
        }
        bindText(statement, 1, event.id.uuidString)
        sqlite3_bind_double(statement!, 2, event.timestamp.timeIntervalSince1970)
        bindText(statement, 3, event.source.rawValue)
        bindText(statement, 4, event.kind.rawValue)
        bindText(statement, 5, payload)
        bindText(statement, 6, event.sourceHash)
        return stepDone(statement)
    }

    func rawEvents(between start: Date, end: Date) -> [RawEvent] {
        let sql = """
        SELECT id, timestamp, source, kind, payload_json, source_hash
        FROM raw_events WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp
        """
        return queryRawEvents(sql, binds: { stmt in
            sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        })
    }

    func rawEvents(ids: [UUID]) -> [RawEvent] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT id, timestamp, source, kind, payload_json, source_hash FROM raw_events WHERE id IN (\(placeholders))"
        return queryRawEvents(sql, binds: { stmt in
            for (index, id) in ids.enumerated() {
                bindText(stmt, Int32(index + 1), id.uuidString)
            }
        })
    }

    func latestRawEvent(source: RawEventSource, kind: RawEventKind) -> RawEvent? {
        let sql = """
        SELECT id, timestamp, source, kind, payload_json, source_hash
        FROM raw_events WHERE source = ? AND kind = ? ORDER BY timestamp DESC LIMIT 1
        """
        return queryRawEvents(sql, binds: { stmt in
            bindText(stmt, 1, source.rawValue)
            bindText(stmt, 2, kind.rawValue)
        }).first
    }

    private func queryRawEvents(_ sql: String, binds: (OpaquePointer) -> Void) -> [RawEvent] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        binds(statement!)
        var result: [RawEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: text(statement, 0) ?? "") ?? UUID()
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            let source = RawEventSource(rawValue: text(statement, 2) ?? "") ?? .systemApp
            let kind = RawEventKind(rawValue: text(statement, 3) ?? "") ?? .appForeground
            let payload = decodeJSON(RawEventPayload.self, text(statement, 4)) ?? RawEventPayload()
            let hash = text(statement, 5) ?? ""
            result.append(RawEvent(id: id, timestamp: timestamp, source: source, kind: kind, payload: payload, sourceHash: hash))
        }
        return result
    }

    // MARK: Activities

    @discardableResult
    func insertActivity(_ activity: Activity) -> Bool {
        guard let db else { return false }
        let evidence = JSONEncoder.uuids(activity.evidenceIDs)
        let sql = """
        INSERT OR REPLACE INTO activities(id, start_time, end_time, group_key, primary_app, category, evidence_ids)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare activity insert")
            return false
        }
        bindText(statement, 1, activity.id.uuidString)
        sqlite3_bind_double(statement!, 2, activity.startTime.timeIntervalSince1970)
        sqlite3_bind_double(statement!, 3, activity.endTime.timeIntervalSince1970)
        bindText(statement, 4, activity.groupKey)
        bindText(statement, 5, activity.primaryApp)
        bindText(statement, 6, activity.category.rawValue)
        bindText(statement, 7, evidence)
        return stepDone(statement)
    }

    func activities(between start: Date, end: Date) -> [Activity] {
        guard let db else { return [] }
        let sql = """
        SELECT id, start_time, end_time, group_key, primary_app, category, evidence_ids
        FROM activities WHERE end_time >= ? AND start_time <= ? ORDER BY start_time
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(statement!, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement!, 2, end.timeIntervalSince1970)
        var result: [Activity] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Activity(
                id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                groupKey: text(statement, 3) ?? "",
                primaryApp: text(statement, 4),
                category: ActivityCategory(rawValue: text(statement, 5) ?? "") ?? .other,
                evidenceIDs: JSONDecoder.uuids(text(statement, 6))
            ))
        }
        return result
    }

    // MARK: Episodes

    @discardableResult
    func insertEpisode(_ episode: Episode) -> Bool {
        guard let db else { return false }
        let factors = encodeJSON(episode.confidenceFactors) ?? "[]"
        let sql = """
        INSERT OR REPLACE INTO episodes(id, start_time, end_time, title, summary, category, confidence,
                                        confidence_factors, activity_ids, evidence_ids)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare episode insert")
            return false
        }
        bindText(statement, 1, episode.id.uuidString)
        sqlite3_bind_double(statement!, 2, episode.startTime.timeIntervalSince1970)
        sqlite3_bind_double(statement!, 3, episode.endTime.timeIntervalSince1970)
        bindText(statement, 4, episode.title)
        bindText(statement, 5, episode.summary)
        bindText(statement, 6, episode.category.rawValue)
        sqlite3_bind_int64(statement!, 7, Int64(episode.confidence))
        bindText(statement, 8, factors)
        bindText(statement, 9, JSONEncoder.uuids(episode.activityIDs))
        bindText(statement, 10, JSONEncoder.uuids(episode.evidenceIDs))
        return stepDone(statement)
    }

    func episodes(between start: Date, end: Date) -> [Episode] {
        guard let db else { return [] }
        let sql = """
        SELECT id, start_time, end_time, title, summary, category, confidence,
               confidence_factors, activity_ids, evidence_ids
        FROM episodes WHERE end_time >= ? AND start_time <= ? ORDER BY start_time
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_double(statement!, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement!, 2, end.timeIntervalSince1970)
        var result: [Episode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Episode(
                id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                title: text(statement, 3) ?? "",
                summary: text(statement, 4) ?? "",
                category: EpisodeCategory(rawValue: text(statement, 5) ?? "") ?? .other,
                confidence: Int(sqlite3_column_int64(statement, 6)),
                confidenceFactors: decodeJSON([ConfidenceFactor].self, text(statement, 7)) ?? [],
                activityIDs: JSONDecoder.uuids(text(statement, 8)),
                evidenceIDs: JSONDecoder.uuids(text(statement, 9))
            ))
        }
        return result
    }

    func episodes(ids: [UUID]) -> [Episode] {
        guard let db, !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = """
        SELECT id, start_time, end_time, title, summary, category, confidence,
               confidence_factors, activity_ids, evidence_ids
        FROM episodes WHERE id IN (\(placeholders)) ORDER BY start_time
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        for (index, id) in ids.enumerated() { bindText(statement, Int32(index + 1), id.uuidString) }
        var result: [Episode] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Episode(
                id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                title: text(statement, 3) ?? "",
                summary: text(statement, 4) ?? "",
                category: EpisodeCategory(rawValue: text(statement, 5) ?? "") ?? .other,
                confidence: Int(sqlite3_column_int64(statement, 6)),
                confidenceFactors: decodeJSON([ConfidenceFactor].self, text(statement, 7)) ?? [],
                activityIDs: JSONDecoder.uuids(text(statement, 8)),
                evidenceIDs: JSONDecoder.uuids(text(statement, 9))
            ))
        }
        return result
    }

    // MARK: Memories

    @discardableResult
    func insertMemory(_ memory: Memory) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO memories(id, title, body, kind, confidence, source_episode_ids,
                                        created_at, last_confirmed_at, is_user_confirmed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare memory insert")
            return false
        }
        bindText(statement, 1, memory.id.uuidString)
        bindText(statement, 2, memory.title)
        bindText(statement, 3, memory.body)
        bindText(statement, 4, memory.kind.rawValue)
        sqlite3_bind_int64(statement!, 5, Int64(memory.confidence))
        bindText(statement, 6, JSONEncoder.uuids(memory.sourceEpisodeIDs))
        sqlite3_bind_double(statement!, 7, memory.createdAt.timeIntervalSince1970)
        if let last = memory.lastConfirmedAt {
            sqlite3_bind_double(statement!, 8, last.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement!, 8)
        }
        sqlite3_bind_int64(statement!, 9, memory.isUserConfirmed ? 1 : 0)
        return stepDone(statement)
    }

    func memories() -> [Memory] {
        guard let db else { return [] }
        let sql = """
        SELECT id, title, body, kind, confidence, source_episode_ids,
               created_at, last_confirmed_at, is_user_confirmed
        FROM memories ORDER BY created_at
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [Memory] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Memory(
                id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
                title: text(statement, 1) ?? "",
                body: text(statement, 2) ?? "",
                kind: MemoryKind(rawValue: text(statement, 3) ?? "") ?? .other,
                confidence: Int(sqlite3_column_int64(statement, 4)),
                sourceEpisodeIDs: JSONDecoder.uuids(text(statement, 5)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                lastConfirmedAt: sqlite3_column_type(statement, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                isUserConfirmed: sqlite3_column_int64(statement, 8) != 0
            ))
        }
        return result
    }

    func memoryConfirmation(for memoryID: UUID) -> (confirmed: Bool, note: String)? {
        guard let db else { return nil }
        let sql = "SELECT is_confirmed, note FROM memory_confirmations WHERE memory_id = ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, memoryID.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(statement, 0) != 0, text(statement, 1) ?? "")
    }

    @discardableResult
    func setMemoryConfirmation(_ memoryID: UUID, confirmed: Bool, note: String = "") -> Bool {
        let confirmedAt = Date()
        let sql = """
        INSERT OR REPLACE INTO memory_confirmations(memory_id, confirmed_at, is_confirmed, note)
        VALUES (?, ?, ?, ?)
        """
        let inserted = mutate(sql, binds: { statement in
            bindText(statement, 1, memoryID.uuidString)
            sqlite3_bind_double(statement, 2, confirmedAt.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, confirmed ? 1 : 0)
            bindText(statement, 4, note)
        })
        guard inserted else { return false }

        // Keep the denormalized Memory fields in sync for legacy callers that
        // read the memories table without going through the confirmation overlay.
        let update = "UPDATE memories SET is_user_confirmed = ?, last_confirmed_at = ? WHERE id = ?"
        return mutate(update) { statement in
            sqlite3_bind_int64(statement, 1, confirmed ? 1 : 0)
            sqlite3_bind_double(statement, 2, confirmedAt.timeIntervalSince1970)
            bindText(statement, 3, memoryID.uuidString)
        }
    }

    // MARK: Analysis runs

    @discardableResult
    func insertAnalysisRun(_ run: AnalysisRun) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO analysis_runs(id, task, context_ref, output_text, evidence_ids, model, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare analysis insert")
            return false
        }
        bindText(statement, 1, run.id.uuidString)
        bindText(statement, 2, run.task.rawValue)
        if let ref = run.inputContextReference {
            bindText(statement, 3, ref.uuidString)
        } else {
            sqlite3_bind_null(statement!, 3)
        }
        bindText(statement, 4, run.outputText)
        bindText(statement, 5, JSONEncoder.uuids(run.evidenceIDs))
        bindText(statement, 6, run.model)
        sqlite3_bind_double(statement!, 7, run.createdAt.timeIntervalSince1970)
        return stepDone(statement)
    }

    func analysisRuns() -> [AnalysisRun] {
        guard let db else { return [] }
        let sql = """
        SELECT id, task, context_ref, output_text, evidence_ids, model, created_at
        FROM analysis_runs ORDER BY created_at
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [AnalysisRun] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let contextRef = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : (text(statement, 2).flatMap(UUID.init(uuidString:)))
            result.append(AnalysisRun(
                id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
                task: RiverTaskKind(rawValue: text(statement, 1) ?? "") ?? .query,
                inputContextReference: contextRef,
                outputText: text(statement, 3) ?? "",
                evidenceIDs: JSONDecoder.uuids(text(statement, 4)),
                model: text(statement, 5) ?? "",
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return result
    }

    @discardableResult
    func insertContextSnapshot(id: UUID = UUID(), payloadJSON: String, model: String, createdAt: Date = Date()) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO context_snapshots(id, created_at, payload_json, model)
        VALUES (?, ?, ?, ?)
        """
        return mutate(sql) { statement in
            bindText(statement, 1, id.uuidString)
            sqlite3_bind_double(statement, 2, createdAt.timeIntervalSince1970)
            bindText(statement, 3, payloadJSON)
            bindText(statement, 4, model)
        }
    }

    func contextSnapshotExists(_ id: UUID) -> Bool {
        guard let db else { return false }
        let sql = "SELECT 1 FROM context_snapshots WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        bindText(statement, 1, id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    func contextSnapshot(id: UUID) -> ContextSnapshot? {
        guard let db else { return nil }
        let sql = "SELECT created_at, payload_json, model FROM context_snapshots WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, id.uuidString)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return ContextSnapshot(
            id: id,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            payloadJSON: text(statement, 1) ?? "{}",
            model: text(statement, 2) ?? ""
        )
    }

    // MARK: User prefs (local state only)

    @discardableResult
    func setUserPref(key: String, value: String) -> Bool {
        let sql = "INSERT OR REPLACE INTO user_prefs(key, value) VALUES (?, ?)"
        return mutate(sql, binds: { stmt in
            bindText(stmt, 1, key)
            bindText(stmt, 2, value)
        })
    }

    func userPref(key: String) -> String? {
        guard let db else { return nil }
        let sql = "SELECT value FROM user_prefs WHERE key = ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    // MARK: Derived data lifecycle

    /// Deletes every table that can be rebuilt from evidence, leaving
    /// raw_events (and thus the user's ability to retrace) intact.
    func clearDerivedData() {
        _ = execute("DELETE FROM analysis_runs")
        _ = execute("DELETE FROM memory_confirmations")
        _ = execute("DELETE FROM memories")
        _ = execute("DELETE FROM episode_annotations")
        _ = execute("DELETE FROM episodes")
        _ = execute("DELETE FROM activities")
    }

    // MARK: Low-level helpers

    private func mutate(_ sql: String, binds: (OpaquePointer) -> Void) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare")
            return false
        }
        binds(statement!)
        return stepDone(statement)
    }

    private func stepDone(_ statement: OpaquePointer?) -> Bool {
        let step = sqlite3_step(statement)
        let ok = step == SQLITE_DONE
        if !ok, let db { lastError = Self.errorMessage(db, fallback: "step") }
        return ok
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
        } else {
            sqlite3_bind_null(statement!, index)
        }
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private static func errorMessage(_ db: OpaquePointer, fallback: String) -> String {
        let cString = sqlite3_errmsg(db)
        return cString.map { String(cString: $0) } ?? fallback
    }
}

// MARK: - UUID / JSON array helpers

private extension JSONEncoder {
    static func uuids(_ uuids: [UUID]) -> String {
        let list = uuids.map(\.uuidString)
        guard let data = try? JSONSerialization.data(withJSONObject: list) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

private extension JSONDecoder {
    static func uuids(_ text: String?) -> [UUID] {
        guard let text, let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list.compactMap(UUID.init(uuidString:))
    }
}
