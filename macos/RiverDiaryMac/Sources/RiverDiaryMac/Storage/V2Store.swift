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
    case habitRules = "habit_rules"
    case habitCards = "habit_cards"
    case habitBatches = "habit_batches"

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
        case .habitRules: "个人规则"
        case .habitCards: "回顾问题"
        case .habitBatches: "回顾批次"
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

    /// 本实例打开的数据库文件（测试与恢复路径用于按 URL 匹配连接）。
    var currentDatabaseURL: URL? { databaseURL }

    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Every live V2Store connection. A snapshot restore swaps the database file
    /// under all of them at once; the registry lets each instance reopen onto
    /// the restored file instead of keeping a handle to the replaced inode,
    /// where writes would silently vanish until app restart.
    @MainActor
    private static let liveInstances = NSHashTable<V2Store>.weakObjects()

    /// 启动期崩溃恢复在文件层面替换了数据库（POSIX rename 绕过了
    /// `restoreEncryptedSnapshot`），持有该文件的存活连接必须重开到新文件，
    /// 否则读旧 inode、写全部丢失。只重开 URL 匹配的连接。
    @MainActor
    static func reopenConnectionsAfterFileReplacement(at url: URL) {
        for instance in liveInstances.allObjects where instance.databaseURL == url {
            instance.close()
            instance.open()
            instance.createSchema()
        }
    }

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
        Self.liveInstances.add(self)
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
            sqlite3_exec(db, "PRAGMA busy_timeout=5000;", nil, nil, nil)
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

    private func createSchema() {        let tables = [
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
            """
            CREATE TABLE IF NOT EXISTS habit_rules (
                id TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS habit_cards (
                id TEXT PRIMARY KEY,
                batch_id TEXT,
                dedup_key TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                updated_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS habit_batches (
                id TEXT PRIMARY KEY,
                period_key TEXT NOT NULL,
                payload_json TEXT NOT NULL DEFAULT '{}',
                created_at REAL NOT NULL,
                shown_at REAL
            )
            """,
        ]
        for sql in tables { execute(sql) }

        // 列级迁移：与 AppDatabase 的 addColumnIfMissing 同思路。analysis_runs 此前
        // 是"无键追加"，结果互相不可寻址；这里补出去重键、字符串证据引用与结构化
        // 摘要三列，让它变成"每个任务+范围一行、可被下游功能消费"的结果层。
        addColumnIfMissing(table: "analysis_runs", column: "dedup_key", definition: "TEXT")
        addColumnIfMissing(table: "analysis_runs", column: "range_key", definition: "TEXT")
        addColumnIfMissing(table: "analysis_runs", column: "evidence_refs", definition: "TEXT NOT NULL DEFAULT '[]'")
        addColumnIfMissing(table: "analysis_runs", column: "digest_json", definition: "TEXT")

        let indices = [
            "CREATE INDEX IF NOT EXISTS idx_raw_events_ts ON raw_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_activities_times ON activities(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_episodes_times ON episodes(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_created ON analysis_runs(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_habit_cards_dedup ON habit_cards(dedup_key)",
            "CREATE INDEX IF NOT EXISTS idx_habit_batches_period ON habit_batches(period_key)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_dedup ON analysis_runs(dedup_key)",
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

    /// 表列存在性迁移：`ALTER TABLE ... ADD COLUMN`，已存在时静默跳过。
    private func addColumnIfMissing(table: String, column: String, definition: String) {
        guard let db else { return }
        let sql = "PRAGMA table_info(\(table))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare table_info")
            return
        }
        var exists = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1), name == column { exists = true }
        }
        guard !exists else { return }
        if !execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)") {
            lastError = Self.errorMessage(db, fallback: "迁移 \(table).\(column) 失败")
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
            // 恢复把磁盘文件从其余连接下面整体换掉了：让所有存活的兄弟实例
            // 重开到恢复后的文件，避免它们的写入落进已被解绑的旧 inode。
            for instance in Self.liveInstances.allObjects where instance !== self {
                instance.close()
                instance.open()
                instance.createSchema()
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

    /// 批量读取确认状态：记忆库刷新曾对每条记忆各发一次查询（N+1）。
    func memoryConfirmations(ids: [UUID]) -> [UUID: (confirmed: Bool, note: String)] {
        guard let db, !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT memory_id, is_confirmed, note FROM memory_confirmations WHERE memory_id IN (\(placeholders))"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        for (index, id) in ids.enumerated() { bindText(statement, Int32(index + 1), id.uuidString) }
        var result: [UUID: (confirmed: Bool, note: String)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = text(statement, 0), let id = UUID(uuidString: idText) else { continue }
            result[id] = (sqlite3_column_int64(statement, 1) != 0, text(statement, 2) ?? "")
        }
        return result
    }

    @discardableResult
    func setMemoryConfirmation(_ memoryID: UUID, confirmed: Bool, note: String = "") -> Bool {
        let confirmedAt = Date()
        let sql = """
        INSERT OR REPLACE INTO memory_confirmations(memory_id, confirmed_at, is_confirmed, note)
        VALUES (?, ?, ?, ?)
        """
        // 覆盖表与去规范化列必须同事务：两层不一致会让"已确认"状态永久分叉。
        return transaction { [self] in
            guard mutate(sql, binds: { statement in
                bindText(statement, 1, memoryID.uuidString)
                sqlite3_bind_double(statement, 2, confirmedAt.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 3, confirmed ? 1 : 0)
                bindText(statement, 4, note)
            }) else { return false }

            // Keep the denormalized Memory fields in sync for legacy callers that
            // read the memories table without going through the confirmation overlay.
            let update = "UPDATE memories SET is_user_confirmed = ?, last_confirmed_at = ? WHERE id = ?"
            return mutate(update) { statement in
                sqlite3_bind_int64(statement, 1, confirmed ? 1 : 0)
                sqlite3_bind_double(statement, 2, confirmedAt.timeIntervalSince1970)
                bindText(statement, 3, memoryID.uuidString)
            }
        }
    }

    // MARK: Analysis runs

    /// 一条可寻址的分析结果：在 `AnalysisRun` 之上补充去重键、范围键、
    /// 字符串证据引用与结构化摘要，让结果能被下游功能（周报、询问、月信）按键读取。
    struct AnalysisRunRecord {
        var run: AnalysisRun
        var dedupKey: String
        var rangeKey: String
        var evidenceRefs: [String]
        var digestJSON: String?
    }

    @discardableResult
    func insertAnalysisRun(_ run: AnalysisRun) -> Bool {
        storeAnalysisRun(run, dedupKey: nil, rangeKey: nil, evidenceRefs: [], digestJSON: nil)
    }

    /// 无范围键的追加（如询问页按查询缓存的结果），但同样携带引用与摘要列。
    @discardableResult
    func insertAnalysisRun(_ run: AnalysisRun, evidenceRefs: [String], digestJSON: String?) -> Bool {
        storeAnalysisRun(run, dedupKey: nil, rangeKey: nil, evidenceRefs: evidenceRefs, digestJSON: digestJSON)
    }

    /// 按去重键 upsert：同一 `dedupKey` 只保留最新一条（最后写入者获胜），
    /// 防止 analysis_runs 随重复触发无限膨胀。`dedupKey` 为 nil 时退化为普通插入。
    @discardableResult
    func upsertAnalysisRun(
        _ run: AnalysisRun,
        dedupKey: String,
        rangeKey: String,
        evidenceRefs: [String],
        digestJSON: String? = nil
    ) -> Bool {
        storeAnalysisRun(run, dedupKey: dedupKey, rangeKey: rangeKey, evidenceRefs: evidenceRefs, digestJSON: digestJSON)
    }

    private func storeAnalysisRun(
        _ run: AnalysisRun,
        dedupKey: String?,
        rangeKey: String?,
        evidenceRefs: [String],
        digestJSON: String?
    ) -> Bool {
        guard let db else { return false }
        let refs = Self.jsonStringArray(evidenceRefs)
        if let dedupKey, !dedupKey.isEmpty {
            // 删除与插入必须在同一事务里：中间失败要么整体成功要么整体回滚，
            // 绝不能丢掉已保存的旧结果，也不能留下同键双行。
            let inserted = transaction { [self] in
                guard mutate("DELETE FROM analysis_runs WHERE dedup_key = ?", binds: { statement in
                    bindText(statement, 1, dedupKey)
                }) else { return false }
                return insertRunStatement(run, rangeKey: rangeKey, evidenceRefsJSON: refs, digestJSON: digestJSON, dedupKey: dedupKey)
            }
            return inserted
        }
        return transaction { [self] in
            insertRunStatement(run, rangeKey: rangeKey, evidenceRefsJSON: refs, digestJSON: digestJSON, dedupKey: dedupKey)
        }
    }

    /// 事务内使用的单行插入（不自行开事务）。
    private func insertRunStatement(
        _ run: AnalysisRun,
        rangeKey: String?,
        evidenceRefsJSON: String,
        digestJSON: String?,
        dedupKey: String?
    ) -> Bool {
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO analysis_runs(id, task, context_ref, output_text, evidence_ids, model, created_at,
                                            dedup_key, range_key, evidence_refs, digest_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        return mutate(sql) { statement in
            bindText(statement, 1, run.id.uuidString)
            bindText(statement, 2, run.task.rawValue)
            if let ref = run.inputContextReference {
                bindText(statement, 3, ref.uuidString)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            bindText(statement, 4, run.outputText)
            bindText(statement, 5, JSONEncoder.uuids(run.evidenceIDs))
            bindText(statement, 6, run.model)
            sqlite3_bind_double(statement, 7, run.createdAt.timeIntervalSince1970)
            if let dedupKey {
                bindText(statement, 8, dedupKey)
            } else {
                sqlite3_bind_null(statement, 8)
            }
            if let rangeKey {
                bindText(statement, 9, rangeKey)
            } else {
                sqlite3_bind_null(statement, 9)
            }
            bindText(statement, 10, evidenceRefsJSON)
            if let digestJSON {
                bindText(statement, 11, digestJSON)
            } else {
                sqlite3_bind_null(statement, 11)
            }
        }
    }

    func latestAnalysisRun(dedupKey: String) -> AnalysisRunRecord? {
        guard let db else { return nil }
        let sql = """
        SELECT id, task, context_ref, output_text, evidence_ids, model, created_at,
               dedup_key, range_key, evidence_refs, digest_json
        FROM analysis_runs WHERE dedup_key = ? ORDER BY created_at DESC LIMIT 1
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, dedupKey)
        guard sqlite3_step(statement) == SQLITE_ROW, let prepared = statement else { return nil }
        return analysisRunRecord(prepared)
    }

    /// 某任务在某日期范围内的全部结果（按时间升序）。
    func analysisRunRecords(task: RiverTaskKind, between start: Date, end: Date) -> [AnalysisRunRecord] {
        guard let db else { return [] }
        let sql = """
        SELECT id, task, context_ref, output_text, evidence_ids, model, created_at,
               dedup_key, range_key, evidence_refs, digest_json
        FROM analysis_runs WHERE task = ? AND created_at >= ? AND created_at <= ? ORDER BY created_at
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bindText(statement, 1, task.rawValue)
        sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, end.timeIntervalSince1970)
        var result: [AnalysisRunRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW, let prepared = statement {
            result.append(analysisRunRecord(prepared))
        }
        return result
    }

    private func analysisRunRecord(_ statement: OpaquePointer) -> AnalysisRunRecord {
        let contextRef = sqlite3_column_type(statement, 2) == SQLITE_NULL
            ? nil
            : (text(statement, 2).flatMap(UUID.init(uuidString:)))
        let run = AnalysisRun(
            id: UUID(uuidString: text(statement, 0) ?? "") ?? UUID(),
            task: RiverTaskKind(rawValue: text(statement, 1) ?? "") ?? .query,
            inputContextReference: contextRef,
            outputText: text(statement, 3) ?? "",
            evidenceIDs: JSONDecoder.uuids(text(statement, 4)),
            model: text(statement, 5) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
        )
        return AnalysisRunRecord(
            run: run,
            dedupKey: text(statement, 7) ?? "",
            rangeKey: text(statement, 8) ?? "",
            evidenceRefs: Self.parseJSONStringArray(text(statement, 9)),
            digestJSON: sqlite3_column_type(statement, 10) == SQLITE_NULL ? nil : text(statement, 10)
        )
    }

    func analysisRuns() -> [AnalysisRun] {
        guard let db else { return [] }
        let sql = """
        SELECT id, task, context_ref, output_text, evidence_ids, model, created_at,
               dedup_key, range_key, evidence_refs, digest_json
        FROM analysis_runs ORDER BY created_at
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [AnalysisRun] = []
        while sqlite3_step(statement) == SQLITE_ROW, let prepared = statement {
            result.append(analysisRunRecord(prepared).run)
        }
        return result
    }

    private static func jsonStringArray(_ values: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: values) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func parseJSONStringArray(_ text: String?) -> [String] {
        guard let text, let data = text.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return list
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

    // MARK: Habit review (个人规则 / 回顾问题 / 回顾批次)
    //
    // 负载是完整的 Codable JSON；列上只冗余查询需要的状态字段。
    // habit_* 三张表都是用户知识，不参与 clearDerivedData。

    struct HabitPayloadRow {
        var id: UUID
        var status: String
        var dedupKey: String
        var batchID: UUID?
        var periodKey: String
        var payloadJSON: String
        var createdAt: Date
        var shownAt: Date?
    }

    @discardableResult
    func upsertHabitRule(id: UUID, status: String, payloadJSON: String, updatedAt: Date) -> Bool {
        mutate(
            "INSERT OR REPLACE INTO habit_rules(id, status, payload_json, updated_at) VALUES (?, ?, ?, ?)"
        ) { statement in
            bindText(statement, 1, id.uuidString)
            bindText(statement, 2, status)
            bindText(statement, 3, payloadJSON)
            sqlite3_bind_double(statement, 4, updatedAt.timeIntervalSince1970)
        }
    }

    @discardableResult
    func upsertHabitCard(id: UUID, batchID: UUID?, dedupKey: String, status: String, payloadJSON: String, updatedAt: Date) -> Bool {
        mutate(
            "INSERT OR REPLACE INTO habit_cards(id, batch_id, dedup_key, status, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?)"
        ) { statement in
            bindText(statement, 1, id.uuidString)
            if let batchID {
                bindText(statement, 2, batchID.uuidString)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            bindText(statement, 3, dedupKey)
            bindText(statement, 4, status)
            bindText(statement, 5, payloadJSON)
            sqlite3_bind_double(statement, 6, updatedAt.timeIntervalSince1970)
        }
    }

    @discardableResult
    func upsertHabitBatch(id: UUID, periodKey: String, payloadJSON: String, createdAt: Date, shownAt: Date?) -> Bool {
        mutate(
            "INSERT OR REPLACE INTO habit_batches(id, period_key, payload_json, created_at, shown_at) VALUES (?, ?, ?, ?, ?)"
        ) { statement in
            bindText(statement, 1, id.uuidString)
            bindText(statement, 2, periodKey)
            bindText(statement, 3, payloadJSON)
            sqlite3_bind_double(statement, 4, createdAt.timeIntervalSince1970)
            if let shownAt {
                sqlite3_bind_double(statement, 5, shownAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 5)
            }
        }
    }

    func habitRuleRows() -> [HabitPayloadRow] {
        let sql = "SELECT id, status, '' , NULL, '', payload_json, updated_at, NULL FROM habit_rules"
        return queryHabitRows(sql)
    }

    func habitCardRows() -> [HabitPayloadRow] {
        let sql = """
        SELECT id, status, dedup_key, batch_id, '', payload_json, updated_at, NULL
        FROM habit_cards ORDER BY updated_at
        """
        return queryHabitRows(sql)
    }

    func habitBatchRows() -> [HabitPayloadRow] {
        let sql = "SELECT id, '', '', NULL, period_key, payload_json, created_at, shown_at FROM habit_batches ORDER BY created_at"
        return queryHabitRows(sql)
    }

    private func queryHabitRows(_ sql: String) -> [HabitPayloadRow] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [HabitPayloadRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = UUID(uuidString: text(statement, 0) ?? "") ?? UUID()
            let status = text(statement, 1) ?? ""
            let dedupKey = text(statement, 2) ?? ""
            let batchID = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : (text(statement, 3).flatMap(UUID.init(uuidString:)))
            let periodKey = text(statement, 4) ?? ""
            let payloadJSON = text(statement, 5) ?? "{}"
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            let shownAt = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            result.append(HabitPayloadRow(
                id: id,
                status: status,
                dedupKey: dedupKey,
                batchID: batchID,
                periodKey: periodKey,
                payloadJSON: payloadJSON,
                createdAt: createdAt,
                shownAt: shownAt
            ))
        }
        return result
    }

    // MARK: Derived data lifecycle

    /// 清除实时活动在事实层的全部痕迹：activities/episodes 全表，
    /// raw_events 仅限 systemApp 来源的 appForeground（地点/健康等其它来源不受影响）。
    /// 与 `ActivityStore.clearActivity` 的"删除实时片段"承诺对齐——此前该操作
    /// 只删了活动目录，V2 里同内容的副本原样保留。
    func clearActivityEvidence() -> Bool {
        transaction {
            guard execute("DELETE FROM activities") else { return false }
            guard execute("DELETE FROM episodes") else { return false }
            return execute("DELETE FROM raw_events WHERE source = 'systemApp' AND kind = 'appForeground'")
        }
    }

    /// Deletes every table that can be rebuilt from evidence, leaving
    /// raw_events (and thus the user's ability to retrace) intact.
    /// `habit_*` 三张表是用户确认过的知识与回顾记录，不属于派生数据，不在这里清除。
    func clearDerivedData() {
        _ = execute("DELETE FROM analysis_runs")
        _ = execute("DELETE FROM memory_confirmations")
        _ = execute("DELETE FROM memories")
        _ = execute("DELETE FROM episode_annotations")
        _ = execute("DELETE FROM episodes")
        _ = execute("DELETE FROM activities")
    }

    // MARK: Low-level helpers

    /// 在单个事务里执行一组写入。V2Store 此前没有事务助手，"删除+插入"
    /// 这类多语句写各自跑在 autocommit 里——中间失败会永久丢掉旧结果。
    /// 传入的闭包返回 false 时回滚并返回 false（lastError 已由内部语句设置）。
    private func transaction(_ work: () -> Bool) -> Bool {
        guard let db else { return false }
        guard execute("BEGIN IMMEDIATE") else { return false }
        if work() {
            guard execute("COMMIT") else {
                _ = execute("ROLLBACK")
                return false
            }
            return true
        } else {
            _ = execute("ROLLBACK")
            return false
        }
    }

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
