import Foundation
import RiverDiaryCore
import SQLCipher

enum V2Table: String, CaseIterable, Identifiable {
    case rawEvents = "raw_events"
    case activities
    case episodes
    case memories
    case places
    case contextSnapshots = "context_snapshots"
    case analysisRuns = "analysis_runs"
    case analysisJobs = "analysis_jobs"
    case episodeAnnotations = "episode_annotations"
    case memoryConfirmations = "memory_confirmations"
    case userPrefs = "user_prefs"
    case habitRules = "habit_rules"
    case habitCards = "habit_cards"
    case habitBatches = "habit_batches"
    case devices
    case stateOperations = "state_operations"
    case artifacts
    case artifactDependencies = "artifact_dependencies"
    case syncImports = "sync_imports"
    case syncExports = "sync_exports"
    case syncState = "sync_state"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rawEvents: "原始事件"
        case .activities: "活动"
        case .episodes: "时间段"
        case .memories: "长期记忆"
        case .places: "地点"
        case .contextSnapshots: "上下文快照"
        case .analysisRuns: "分析运行"
        case .analysisJobs: "分析任务"
        case .episodeAnnotations: "片段标注"
        case .memoryConfirmations: "记忆确认"
        case .userPrefs: "用户设置"
        case .habitRules: "个人规则"
        case .habitCards: "回顾问题"
        case .habitBatches: "回顾批次"
        case .devices: "设备"
        case .stateOperations: "用户状态操作"
        case .artifacts: "AI 结果版本"
        case .artifactDependencies: "结果依赖"
        case .syncImports: "同步导入"
        case .syncExports: "同步导出"
        case .syncState: "同步状态"
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
    private static let supportedSchemaVersion: Int32 = 2
    private static let derivedRebuildRequiredKey = "derived.syncRebuildRequired"
    private static let pendingEventInvalidationKey = "derived.pendingEventInvalidation"
    private(set) var db: OpaquePointer?
    private(set) var lastError: String?

    private let databaseURL: URL?
    /// Test-only identity injection lets two V2Store instances represent separate nodes.
    private let testDeviceID: RiverDeviceID?

    /// 本实例打开的数据库文件（测试与恢复路径用于按 URL 匹配连接）。
    var currentDatabaseURL: URL? { databaseURL }
    var databaseSchemaVersion: Int { Int(schemaVersion()) }

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

    init(databaseURL: URL? = nil, testDeviceID: RiverDeviceID? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL()
        self.testDeviceID = testDeviceID
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
            if schemaVersion() > Self.supportedSchemaVersion {
                lastError = "V2 数据库由更新版本创建；请先升级 River Diary。"
                sqlite3_close(db)
                db = nil
            }
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

    private func schemaVersion() -> Int32 {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    private func createSchema() {
        guard db != nil else { return }
        let tables = [
            """
            CREATE TABLE IF NOT EXISTS raw_events (
                id TEXT PRIMARY KEY,
                origin_device_id TEXT NOT NULL DEFAULT '',
                origin_sequence INTEGER NOT NULL DEFAULT 0,
                timestamp REAL NOT NULL,
                recorded_at REAL NOT NULL DEFAULT 0,
                observed_timezone TEXT,
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
                evidence_refs_json TEXT NOT NULL DEFAULT '[]',
                created_at REAL NOT NULL,
                last_confirmed_at REAL,
                is_user_confirmed INTEGER NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS places (
                place_id TEXT PRIMARY KEY,
                latitude REAL NOT NULL,
                longitude REAL NOT NULL,
                radius_meters REAL NOT NULL,
                map_name TEXT,
                map_address TEXT,
                poi_category TEXT,
                map_provider TEXT,
                map_result_identifier TEXT,
                user_defined_name TEXT,
                semantic_type TEXT,
                is_user_confirmed INTEGER NOT NULL DEFAULT 0,
                confidence REAL NOT NULL DEFAULT 0,
                first_seen REAL NOT NULL,
                last_seen REAL NOT NULL,
                visit_count INTEGER NOT NULL DEFAULT 0,
                total_duration_seconds REAL NOT NULL DEFAULT 0
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
            """
            CREATE TABLE IF NOT EXISTS devices (
                device_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL DEFAULT '',
                platform TEXT NOT NULL DEFAULT '',
                lifecycle TEXT NOT NULL DEFAULT 'active',
                logical_millis INTEGER NOT NULL DEFAULT 0,
                logical_counter INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS state_operations (
                operation_id TEXT PRIMARY KEY,
                actor_device_id TEXT NOT NULL,
                origin_sequence INTEGER NOT NULL,
                logical_millis INTEGER NOT NULL,
                logical_counter INTEGER NOT NULL,
                target_id TEXT NOT NULL,
                field_key TEXT NOT NULL,
                operation_type TEXT NOT NULL,
                payload BLOB NOT NULL,
                causal_frontier_json TEXT NOT NULL DEFAULT '{}',
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS artifacts (
                artifact_id TEXT PRIMARY KEY,
                logical_key TEXT NOT NULL,
                artifact_type TEXT NOT NULL,
                revision_number INTEGER NOT NULL,
                origin_device_id TEXT NOT NULL,
                logical_millis INTEGER NOT NULL,
                logical_counter INTEGER NOT NULL,
                input_frontier_json TEXT NOT NULL DEFAULT '{}',
                input_snapshot_hash TEXT NOT NULL DEFAULT '',
                pipeline_version TEXT NOT NULL DEFAULT '',
                prompt_version TEXT NOT NULL DEFAULT '',
                model_provider TEXT NOT NULL DEFAULT '',
                model_identifier TEXT NOT NULL DEFAULT '',
                content BLOB NOT NULL,
                content_hash TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'provisional',
                user_state INTEGER NOT NULL DEFAULT 0,
                is_canonical INTEGER NOT NULL DEFAULT 0,
                supersedes_revision_id TEXT,
                created_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS artifact_dependencies (
                artifact_id TEXT NOT NULL,
                dependency_type TEXT NOT NULL,
                dependency_id TEXT NOT NULL,
                range_start REAL,
                range_end REAL,
                PRIMARY KEY(artifact_id, dependency_type, dependency_id)
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sync_imports (
                object_id TEXT PRIMARY KEY,
                source_device_id TEXT NOT NULL,
                object_type TEXT NOT NULL,
                ciphertext_hash TEXT NOT NULL,
                imported_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sync_exports (
                object_id TEXT PRIMARY KEY,
                source_device_id TEXT NOT NULL,
                object_type TEXT NOT NULL,
                ciphertext_hash TEXT NOT NULL,
                exported_at REAL NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL DEFAULT ''
            )
            """,
            "CREATE TABLE IF NOT EXISTS analysis_jobs (job_id TEXT PRIMARY KEY, logical_key TEXT NOT NULL, artifact_type TEXT NOT NULL, input_frontier_json TEXT NOT NULL, priority INTEGER NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, started_at REAL, finished_at REAL, attempt INTEGER NOT NULL, origin_device_id TEXT NOT NULL, pipeline_version TEXT NOT NULL, prompt_version TEXT NOT NULL, last_error TEXT, payload_json TEXT NOT NULL)",
        ]
        for sql in tables { execute(sql) }

        // 列级迁移：与 AppDatabase 的 addColumnIfMissing 同思路。analysis_runs 此前
        // 是"无键追加"，结果互相不可寻址；这里补出去重键、字符串证据引用与结构化
        // 摘要三列，让它变成"每个任务+范围一行、可被下游功能消费"的结果层。
        addColumnIfMissing(table: "analysis_runs", column: "dedup_key", definition: "TEXT")
        addColumnIfMissing(table: "analysis_runs", column: "range_key", definition: "TEXT")
        addColumnIfMissing(table: "analysis_runs", column: "evidence_refs", definition: "TEXT NOT NULL DEFAULT '[]'")
        addColumnIfMissing(table: "analysis_runs", column: "digest_json", definition: "TEXT")
        addColumnIfMissing(table: "memories", column: "evidence_refs_json", definition: "TEXT NOT NULL DEFAULT '[]'")
        addColumnIfMissing(table: "raw_events", column: "origin_device_id", definition: "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing(table: "raw_events", column: "origin_sequence", definition: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing(table: "raw_events", column: "observed_timezone", definition: "TEXT")
        addColumnIfMissing(table: "raw_events", column: "recorded_at", definition: "REAL NOT NULL DEFAULT 0")
        addColumnIfMissing(table: "artifacts", column: "is_canonical", definition: "INTEGER NOT NULL DEFAULT 0")

        backfillLegacyEventIdentity()
        backfillLegacyRecordedAt()
        registerLocalDeviceIfNeeded()

        let indices = [
            "CREATE INDEX IF NOT EXISTS idx_raw_events_ts ON raw_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_activities_times ON activities(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_episodes_times ON episodes(start_time, end_time)",
            "CREATE INDEX IF NOT EXISTS idx_memories_created ON memories(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_created ON analysis_runs(created_at)",
            "CREATE INDEX IF NOT EXISTS idx_habit_cards_dedup ON habit_cards(dedup_key)",
            "CREATE INDEX IF NOT EXISTS idx_habit_batches_period ON habit_batches(period_key)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_dedup ON analysis_runs(dedup_key)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_raw_event_origin_sequence ON raw_events(origin_device_id, origin_sequence) WHERE origin_device_id != '' AND origin_sequence > 0",
            "CREATE INDEX IF NOT EXISTS idx_raw_event_origin_time ON raw_events(origin_device_id, timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_state_operation_target ON state_operations(target_id, field_key, logical_millis, logical_counter)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_state_operation_origin_sequence ON state_operations(actor_device_id, origin_sequence)",
            "CREATE INDEX IF NOT EXISTS idx_artifact_logical_key ON artifacts(logical_key, artifact_type, revision_number)",
            "CREATE INDEX IF NOT EXISTS idx_artifact_dependency_lookup ON artifact_dependencies(dependency_type, dependency_id)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_jobs_queue ON analysis_jobs(status, priority DESC, created_at)",
        ]
        for sql in indices { execute(sql) }
        execute("PRAGMA user_version = 2")
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

    private func backfillLegacyEventIdentity() {
        guard let db, let deviceID = localDeviceID() else { return }
        let counterKey = "owned.event.sequence.\(deviceID.rawValue)"
        let savedCounter = UInt64(syncValue(counterKey) ?? "0") ?? 0
        var maximum = max(savedCounter, maximumEventSequence(for: deviceID))
        var statement: OpaquePointer?
        let select = "SELECT id FROM raw_events WHERE origin_device_id = '' ORDER BY timestamp, id"
        guard sqlite3_prepare_v2(db, select, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare event identity migration")
            return
        }
        var legacyIDs: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = text(statement, 0) { legacyIDs.append(id) }
        }
        sqlite3_finalize(statement)

        let migrated = transaction { [self] in
            for id in legacyIDs {
                guard maximum < UInt64(Int64.max) else {
                    lastError = "本机事件序号超出支持范围"
                    return false
                }
                maximum += 1
                let ok = mutate(
                    "UPDATE raw_events SET origin_device_id = ?, origin_sequence = ?, observed_timezone = COALESCE(observed_timezone, ?), recorded_at = CASE WHEN recorded_at = 0 THEN timestamp ELSE recorded_at END WHERE id = ?"
                ) { statement in
                    bindText(statement, 1, deviceID.rawValue)
                    sqlite3_bind_int64(statement, 2, Int64(maximum))
                    bindText(statement, 3, TimeZone.current.identifier)
                    bindText(statement, 4, id)
                }
                if !ok { return false }
            }
            return saveSyncValue(String(maximum), for: counterKey)
        }
        if !migrated { return }
    }

    private func backfillLegacyRecordedAt() {
        _ = execute("UPDATE raw_events SET recorded_at = timestamp WHERE recorded_at = 0")
    }

    private func registerLocalDeviceIfNeeded() {
        guard let deviceID = localDeviceID() else { return }
        let platform = "macOS"
        let displayName = ProcessInfo.processInfo.hostName
        let now = Date()
        _ = mutate(
            "INSERT OR IGNORE INTO devices(device_id, display_name, platform, lifecycle, logical_millis, logical_counter, updated_at) VALUES (?, ?, ?, 'active', 0, 0, ?)"
        ) { statement in
            bindText(statement, 1, deviceID.rawValue)
            bindText(statement, 2, displayName)
            bindText(statement, 3, platform)
            sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        }
    }

    private func localDeviceID() -> RiverDeviceID? {
        if let testDeviceID { return testDeviceID }
        do {
            return try RiverSecureStore.loadOrCreateDeviceID(kind: "mac")
        } catch {
            lastError = "无法安全载入此 Mac 的设备标识：\(error.localizedDescription)"
            return nil
        }
    }

    private func syncValue(_ key: String) -> String? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM sync_state WHERE key = ?", -1, &statement, nil) == SQLITE_OK else { return nil }
        bindText(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    @discardableResult
    private func saveSyncValue(_ value: String, for key: String) -> Bool {
        mutate("INSERT OR REPLACE INTO sync_state(key, value) VALUES (?, ?)") { statement in
            bindText(statement, 1, key)
            bindText(statement, 2, value)
        }
    }

    private func maximumEventSequence(for deviceID: RiverDeviceID) -> UInt64 {
        guard let db else { return 0 }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(origin_sequence) FROM raw_events WHERE origin_device_id = ?", -1, &statement, nil) == SQLITE_OK else { return 0 }
        bindText(statement, 1, deviceID.rawValue)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return UInt64(max(0, sqlite3_column_int64(statement, 0)))
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
            guard saveSyncValue("1", for: Self.derivedRebuildRequiredKey) else {
                throw DatabaseCipherError.invalidDatabase(lastError ?? "无法安排恢复后的派生状态核对")
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
        guard db != nil else { return false }
        let inserted = transaction { [self] in
            if let existing = rawEvents(ids: [event.id]).first {
                guard existing.timestamp == event.timestamp,
                      existing.persistedSource == event.persistedSource,
                      existing.persistedKind == event.persistedKind,
                      existing.payload == event.payload,
                      existing.sourceHash == event.sourceHash else {
                    lastError = "同一 Event ID 对应了不同内容：\(event.id.uuidString)"
                    return false
                }
                return true
            }

            var persisted = event
            if persisted.originSequence == 0 {
                guard let deviceID = localDeviceID(),
                      persisted.originDeviceID == nil || persisted.originDeviceID == deviceID else {
                    lastError = "本机事件缺少有效设备身份或序号"
                    return false
                }
                let key = "owned.event.sequence.\(deviceID.rawValue)"
                let current = max(UInt64(syncValue(key) ?? "0") ?? 0, maximumEventSequence(for: deviceID))
                guard current < UInt64(Int64.max) else {
                    lastError = "本机事件序号超出支持范围"
                    return false
                }
                persisted.originDeviceID = deviceID
                persisted.originSequence = current + 1
                guard saveSyncValue(String(current + 1), for: key) else { return false }
            } else if persisted.originDeviceID == nil || persisted.originSequence > UInt64(Int64.max) {
                lastError = "导入事件缺少有效来源设备或序号"
                return false
            }
            guard insertRawEventStatement(persisted) else { return false }
            guard saveSyncValue("1", for: Self.pendingEventInvalidationKey) else { return false }
            if persisted.persistedKind.hasPrefix("location.")
                && !saveSyncValue("1", for: Self.derivedRebuildRequiredKey) { return false }
            return true
        }
        if inserted, let stored = rawEvents(ids: [event.id]).first {
            let invalidated = invalidateArtifacts(covering: stored)
            if invalidated && !saveSyncValue("0", for: Self.pendingEventInvalidationKey) {
                lastError = "无法完成本机 Event 的 Artifact 失效核对"
            }
            NotificationCenter.default.post(name: .riverLocalCanonicalStateDidChange, object: stored.originDeviceID?.rawValue)
        }
        return inserted
    }

    @discardableResult
    func importEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) -> Bool {
        guard db != nil else { return false }
        var insertedAny = false
        let imported = transaction { [self] in
            if syncImportExists(objectID) { return true }
            for replicaEvent in batch.events {
                let event = RawEvent(replica: replicaEvent)
                if let existing = rawEvents(ids: [event.id]).first {
                    guard existing.timestamp == event.timestamp,
                          existing.persistedSource == event.persistedSource,
                          existing.persistedKind == event.persistedKind,
                          existing.payload == event.payload,
                          existing.sourceHash == event.sourceHash,
                          existing.originDeviceID == event.originDeviceID,
                          existing.originSequence == event.originSequence else {
                        lastError = "远端 Event ID 与本地内容冲突：\(event.id.uuidString)"
                        return false
                    }
                    continue
                }
                guard event.originDeviceID == batch.deviceID, event.originSequence > 0,
                      event.originSequence <= UInt64(Int64.max),
                      insertRawEventStatement(event) else { return false }
                insertedAny = true
            }
            if insertedAny && !saveSyncValue("1", for: Self.derivedRebuildRequiredKey) { return false }
            guard refreshImportedEventFrontier(for: batch.deviceID) else { return false }
            return mutate(
                "INSERT INTO sync_imports(object_id, source_device_id, object_type, ciphertext_hash, imported_at) VALUES (?, ?, 'events', ?, ?)"
            ) { statement in
                bindText(statement, 1, objectID)
                bindText(statement, 2, batch.deviceID.rawValue)
                bindText(statement, 3, ciphertextHash)
                sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            }
        }
        if imported {
            for replicaEvent in batch.events {
                _ = invalidateArtifacts(covering: RawEvent(replica: replicaEvent))
            }
        }
        return imported
    }

    private func insertRawEventStatement(_ event: RawEvent) -> Bool {
        guard let db, let deviceID = event.originDeviceID, event.originSequence > 0,
              event.originSequence <= UInt64(Int64.max) else { return false }
        let payload = encodeJSON(event.payload) ?? "{}"
        let sql = """
        INSERT OR IGNORE INTO raw_events(
            id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone,
            source, kind, payload_json, source_hash
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare raw insert")
            return false
        }
        bindText(statement, 1, event.id.uuidString)
        bindText(statement, 2, deviceID.rawValue)
        sqlite3_bind_int64(statement, 3, Int64(event.originSequence))
        sqlite3_bind_double(statement, 4, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, event.recordedAt.timeIntervalSince1970)
        bindText(statement, 6, event.observedTimeZoneIdentifier)
        bindText(statement, 7, event.persistedSource)
        bindText(statement, 8, event.persistedKind)
        bindText(statement, 9, payload)
        bindText(statement, 10, event.sourceHash)
        guard stepDone(statement) else { return false }
        guard sqlite3_changes(db) == 1 else {
            lastError = "远端事件来源序号已被另一 Event ID 使用：\(deviceID.rawValue)#\(event.originSequence)"
            return false
        }
        return true
    }

    private func syncImportExists(_ objectID: String) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sync_imports WHERE object_id = ?", -1, &statement, nil) == SQLITE_OK else { return false }
        bindText(statement, 1, objectID)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func refreshImportedEventFrontier(for deviceID: RiverDeviceID) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT origin_sequence FROM raw_events WHERE origin_device_id = ? ORDER BY origin_sequence", -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare imported frontier")
            return false
        }
        bindText(statement, 1, deviceID.rawValue)
        var sequences: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sequences.append(UInt64(max(0, sqlite3_column_int64(statement, 0))))
        }
        let key = "imported.event.prefix.\(deviceID.rawValue)"
        let watermark = UInt64(syncValue(key) ?? "0") ?? 0
        let scan = SequenceScan(sequences: sequences, startingAfter: watermark)
        return saveSyncValue(String(scan.contiguousThrough), for: key)
    }

    func importedEventFrontier(for deviceID: RiverDeviceID) -> UInt64 {
        UInt64(syncValue("imported.event.prefix.\(deviceID.rawValue)") ?? "0") ?? 0
    }

    func ownedEventFrontier() -> UInt64 {
        guard let deviceID = localDeviceID() else { return 0 }
        return UInt64(syncValue("owned.event.sequence.\(deviceID.rawValue)") ?? "0") ?? 0
    }

    func localDeviceIdentifier() -> RiverDeviceID? { localDeviceID() }

    func allRawEvents() -> [RawEvent] {
        queryRawEvents("""
        SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone,
               source, kind, payload_json, source_hash FROM raw_events
        ORDER BY timestamp, origin_device_id, origin_sequence
        """) { _ in }
    }

    func effectiveRawEvents() -> [RawEvent] {
        let deleted = StateOperationResolver.tombstonedObjectIDs(allStateOperations())
        return allRawEvents().filter { !deleted.contains("event:\($0.id.uuidString)") }
    }

    func exportableRawEventBatches(maximumEvents: Int = 128) -> [RiverEventBatch] {
        guard let deviceID = localDeviceID(), maximumEvents > 0 else { return [] }
        let events = allRawEvents().filter { $0.originDeviceID == deviceID }
        let replicas = events.compactMap { $0.replica() }
        guard !replicas.isEmpty else { return [] }
        var batches: [RiverEventBatch] = []
        var group: [RiverEvent] = []
        for event in replicas.sorted(by: { $0.originSequence < $1.originSequence }) {
            if let last = group.last, event.originSequence != last.originSequence + 1 {
                if let batch = try? RiverEventBatch(deviceID: deviceID, events: group) { batches.append(batch) }
                group = []
            }
            group.append(event)
            if group.count >= maximumEvents {
                if let batch = try? RiverEventBatch(deviceID: deviceID, events: group) { batches.append(batch) }
                group = []
            }
        }
        if !group.isEmpty, let batch = try? RiverEventBatch(deviceID: deviceID, events: group) { batches.append(batch) }
        return batches
    }

    // MARK: Append-only user state

    struct StateOperationDraft {
        let id: UUID
        let targetID: String
        let fieldKey: String
        let operationType: String
        let payload: Data
    }

    @discardableResult
    func appendStateOperation(
        id: UUID = UUID(),
        targetID: String,
        fieldKey: String,
        operationType: String,
        payload: Data
    ) -> StateOperation? {
        appendStateOperationsAtomically([
            StateOperationDraft(
                id: id, targetID: targetID, fieldKey: fieldKey,
                operationType: operationType, payload: payload
            )
        ])?.first
    }

    func appendStateOperationsAtomically(_ drafts: [StateOperationDraft]) -> [StateOperation]? {
        guard !drafts.isEmpty else { return [] }
        guard let deviceID = localDeviceIdentifier() else { return nil }
        guard Set(drafts.map(\.id)).count == drafts.count else {
            lastError = "同一原子状态更新包含重复操作 ID。"
            return nil
        }
        var results: [StateOperation] = []
        var addedOperations: [StateOperation] = []
        let inserted = transaction { [self] in
            for draft in drafts {
                if let existing = stateOperation(id: draft.id) {
                    guard existing.actorDeviceID == deviceID, existing.targetID == draft.targetID,
                          existing.fieldKey == draft.fieldKey, existing.operationType == draft.operationType,
                          existing.payload == draft.payload else {
                        lastError = "同一操作 ID 对应了不同用户决定：\(draft.id.uuidString)"
                        return false
                    }
                    results.append(existing)
                    continue
                }
                let sequenceKey = "owned.operation.sequence.\(deviceID.rawValue)"
                let sequence = UInt64(syncValue(sequenceKey) ?? "0") ?? 0
                guard sequence < UInt64(Int64.max) else {
                    lastError = "用户状态操作序号超出支持范围"
                    return false
                }
                var clock = HybridLogicalClock(
                    physicalMilliseconds: UInt64(syncValue("hlc.physical.\(deviceID.rawValue)") ?? "0") ?? 0,
                    logicalCounter: UInt32(syncValue("hlc.logical.\(deviceID.rawValue)") ?? "0") ?? 0,
                    deviceID: deviceID
                )
                clock.tick(wallTimeMilliseconds: UInt64(max(0, Date().timeIntervalSince1970 * 1_000)))
                guard let causalFrontier = try? InputFrontier(operationSequences: knownOperationFrontiers(localNextSequence: sequence)) else {
                    lastError = "无法生成用户状态因果 frontier"
                    return false
                }
                let operation = StateOperation(
                    id: draft.id,
                    actorDeviceID: deviceID,
                    originSequence: sequence + 1,
                    clock: clock,
                    causalFrontier: causalFrontier,
                    targetID: draft.targetID,
                    fieldKey: draft.fieldKey,
                    operationType: draft.operationType,
                    payload: draft.payload
                )
                guard insertStateOperationStatement(operation),
                      saveSyncValue(String(operation.originSequence), for: sequenceKey),
                      saveSyncValue(String(clock.physicalMilliseconds), for: "hlc.physical.\(deviceID.rawValue)"),
                      saveSyncValue(String(clock.logicalCounter), for: "hlc.logical.\(deviceID.rawValue)") else { return false }
                results.append(operation)
                addedOperations.append(operation)
            }
            if !addedOperations.isEmpty && !saveSyncValue("1", for: Self.derivedRebuildRequiredKey) {
                return false
            }
            return true
        }
        guard inserted else { return nil }
        if !addedOperations.isEmpty {
            NotificationCenter.default.post(name: .riverLocalCanonicalStateDidChange, object: deviceID.rawValue)
            for operation in addedOperations
            where RiverStateOperationFreshness.changesAnalyticalState(operation)
                && !RiverStateOperationFreshness.defersAnalyticalInvalidation(operation) {
                _ = invalidateArtifacts(covering: operation)
            }
        }
        return results
    }

    func stateOperationResolution() -> StateResolution {
        StateOperationResolver.resolve(allStateOperations())
    }

    func timelineAnnotationsFromOperations() -> [String: TimelineAnnotation] {
        let operations = allStateOperations().filter {
            $0.operationType == "timeline.annotation.set" && $0.fieldKey == "annotation"
        }
        let resolved = StateOperationResolver.resolve(operations)
        var values: [String: TimelineAnnotation] = [:]
        for operation in resolved.currentByField.values {
            guard let annotation = try? decoder.decode(TimelineAnnotation.self, from: operation.payload) else { continue }
            values[operation.targetID] = annotation
        }
        return values
    }

    func allStateOperations() -> [StateOperation] {
        queryStateOperations("""
        SELECT operation_id, actor_device_id, origin_sequence, logical_millis, logical_counter,
               target_id, field_key, operation_type, payload, causal_frontier_json
        FROM state_operations ORDER BY actor_device_id, origin_sequence
        """) { _ in }
    }

    /// Identity checks use the primary key rather than decoding the complete history.
    private func stateOperation(id: UUID) -> StateOperation? {
        queryStateOperations("""
        SELECT operation_id, actor_device_id, origin_sequence, logical_millis, logical_counter,
               target_id, field_key, operation_type, payload, causal_frontier_json
        FROM state_operations WHERE operation_id = ?
        """) { statement in
            bindText(statement, 1, id.uuidString)
        }.first
    }

    private func queryStateOperations(_ sql: String, binds: (OpaquePointer) -> Void) -> [StateOperation] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        binds(statement!)
        var result: [StateOperation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let operationID = UUID(uuidString: text(statement, 0) ?? ""),
                  let actorText = text(statement, 1),
                  let target = text(statement, 5),
                  let field = text(statement, 6),
                  let type = text(statement, 7),
                  let payload = blob(statement, 8),
                  let frontierData = text(statement, 9)?.data(using: .utf8),
                  let frontier = try? decoder.decode(InputFrontier.self, from: frontierData) else { continue }
            let actor = RiverDeviceID(rawValue: actorText)
            result.append(StateOperation(
                id: operationID,
                actorDeviceID: actor,
                originSequence: UInt64(max(0, sqlite3_column_int64(statement, 2))),
                clock: HybridLogicalClock(
                    physicalMilliseconds: UInt64(max(0, sqlite3_column_int64(statement, 3))),
                    logicalCounter: UInt32(max(0, sqlite3_column_int64(statement, 4))),
                    deviceID: actor
                ),
                causalFrontier: frontier,
                targetID: target,
                fieldKey: field,
                operationType: type,
                payload: payload
            ))
        }
        return result
    }

    func exportableStateOperationBatches(maximumOperations: Int = 128) -> [StateOperationBatch] {
        guard let deviceID = localDeviceIdentifier(), maximumOperations > 0 else { return [] }
        let operations = allStateOperations().filter { $0.actorDeviceID == deviceID }
        var batches: [StateOperationBatch] = []
        var group: [StateOperation] = []
        for operation in operations {
            if let last = group.last,
               last.originSequence == UInt64.max || operation.originSequence != last.originSequence + 1 {
                if let batch = try? StateOperationBatch(deviceID: deviceID, operations: group) { batches.append(batch) }
                group = []
            }
            group.append(operation)
            if group.count >= maximumOperations {
                if let batch = try? StateOperationBatch(deviceID: deviceID, operations: group) { batches.append(batch) }
                group = []
            }
        }
        if !group.isEmpty, let batch = try? StateOperationBatch(deviceID: deviceID, operations: group) { batches.append(batch) }
        return batches
    }

    @discardableResult
    func importStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) -> Bool {
        guard db != nil else { return false }
        var insertedAny = false
        return transaction { [self] in
            if syncImportExists(objectID) { return true }
            for operation in batch.operations {
                guard operation.actorDeviceID == batch.deviceID, operation.originSequence > 0,
                      operation.originSequence <= UInt64(Int64.max) else {
                    lastError = "导入的用户状态操作来源或序号无效"
                    return false
                }
                if let existing = stateOperation(id: operation.id) {
                    guard existing == operation else {
                        lastError = "远端操作 ID 与本地内容冲突：\(operation.id.uuidString)"
                        return false
                    }
                    continue
                }
                guard insertStateOperationStatement(operation) else { return false }
                insertedAny = true
            }
            if insertedAny && !saveSyncValue("1", for: Self.derivedRebuildRequiredKey) { return false }
            guard refreshImportedOperationFrontier(for: batch.deviceID) else { return false }
            return mutate(
                "INSERT INTO sync_imports(object_id, source_device_id, object_type, ciphertext_hash, imported_at) VALUES (?, ?, 'state_operations', ?, ?)"
            ) { statement in
                bindText(statement, 1, objectID)
                bindText(statement, 2, batch.deviceID.rawValue)
                bindText(statement, 3, ciphertextHash)
                sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            }
        }
    }

    private func insertStateOperationStatement(_ operation: StateOperation) -> Bool {
        guard let db,
              let frontierJSON = encodeJSON(operation.causalFrontier),
              operation.originSequence > 0,
              operation.originSequence <= UInt64(Int64.max) else { return false }
        let sql = """
        INSERT OR IGNORE INTO state_operations(
            operation_id, actor_device_id, origin_sequence, logical_millis, logical_counter,
            target_id, field_key, operation_type, payload, causal_frontier_json, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare state operation")
            return false
        }
        bindText(statement, 1, operation.id.uuidString)
        bindText(statement, 2, operation.actorDeviceID.rawValue)
        sqlite3_bind_int64(statement, 3, Int64(operation.originSequence))
        sqlite3_bind_int64(statement, 4, Int64(operation.clock.physicalMilliseconds))
        sqlite3_bind_int64(statement, 5, Int64(operation.clock.logicalCounter))
        bindText(statement, 6, operation.targetID)
        bindText(statement, 7, operation.fieldKey)
        bindText(statement, 8, operation.operationType)
        bindBlob(statement, 9, operation.payload)
        bindText(statement, 10, frontierJSON)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        guard stepDone(statement), sqlite3_changes(db) == 1 else {
            lastError = "操作 ID 或来源序号发生冲突：\(operation.id.uuidString)"
            return false
        }
        return true
    }

    private func knownOperationFrontiers(localNextSequence: UInt64) -> [String: UInt64] {
        guard let deviceID = localDeviceIdentifier() else { return [:] }
        var result = [deviceID.rawValue: localNextSequence]
        if let registrations = try? allDeviceRegistrations() {
            for registration in registrations where registration.id != deviceID {
                result[registration.id.rawValue] = importedOperationFrontier(for: registration.id)
            }
        }
        return result
    }

    func importedOperationFrontier(for deviceID: RiverDeviceID) -> UInt64 {
        UInt64(syncValue("imported.operation.prefix.\(deviceID.rawValue)") ?? "0") ?? 0
    }

    private func refreshImportedOperationFrontier(for deviceID: RiverDeviceID) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT origin_sequence FROM state_operations WHERE actor_device_id = ? ORDER BY origin_sequence", -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "prepare operation frontier")
            return false
        }
        bindText(statement, 1, deviceID.rawValue)
        var sequences: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            sequences.append(UInt64(max(0, sqlite3_column_int64(statement, 0))))
        }
        let key = "imported.operation.prefix.\(deviceID.rawValue)"
        let watermark = UInt64(syncValue(key) ?? "0") ?? 0
        let scan = SequenceScan(sequences: sequences, startingAfter: watermark)
        return saveSyncValue(String(scan.contiguousThrough), for: key)
    }

    func rawEvents(between start: Date, end: Date) -> [RawEvent] {
        let sql = """
        SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone,
               source, kind, payload_json, source_hash
        FROM raw_events WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp
        """
        let values = queryRawEvents(sql, binds: { stmt in
            sqlite3_bind_double(stmt, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, end.timeIntervalSince1970)
        })
        let deleted = StateOperationResolver.tombstonedObjectIDs(allStateOperations())
        return values.filter { !deleted.contains("event:\($0.id.uuidString)") }
    }

    func rawEvents(ids: [UUID]) -> [RawEvent] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone, source, kind, payload_json, source_hash FROM raw_events WHERE id IN (\(placeholders))"
        let values = queryRawEvents(sql, binds: { stmt in
            for (index, id) in ids.enumerated() {
                bindText(stmt, Int32(index + 1), id.uuidString)
            }
        })
        let deleted = StateOperationResolver.tombstonedObjectIDs(allStateOperations())
        return values.filter { !deleted.contains("event:\($0.id.uuidString)") }
    }

    func latestRawEvent(source: RawEventSource, kind: RawEventKind) -> RawEvent? {
        let sql = """
        SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone,
               source, kind, payload_json, source_hash
        FROM raw_events WHERE source = ? AND kind = ? ORDER BY timestamp DESC LIMIT 1
        """
        let deleted = StateOperationResolver.tombstonedObjectIDs(allStateOperations())
        return queryRawEvents(sql, binds: { stmt in
            bindText(stmt, 1, source.rawValue)
            bindText(stmt, 2, kind.rawValue)
        }).first(where: { !deleted.contains("event:\($0.id.uuidString)") })
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
            let deviceID = text(statement, 1).flatMap { $0.isEmpty ? nil : RiverDeviceID(rawValue: $0) }
            let sequence = UInt64(max(0, sqlite3_column_int64(statement, 2)))
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            let recordedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            let timezone = text(statement, 5)
            let sourceText = text(statement, 6) ?? ""
            let kindText = text(statement, 7) ?? ""
            let source = RawEventSource(rawValue: sourceText) ?? .manual
            let kind = RawEventKind(rawValue: kindText) ?? .quickCapture
            let payload = decodeJSON(RawEventPayload.self, text(statement, 8)) ?? RawEventPayload()
            let hash = text(statement, 9) ?? ""
            result.append(RawEvent(
                id: id, timestamp: timestamp, source: source, kind: kind,
                payload: payload, sourceHash: hash, originDeviceID: deviceID,
                originSequence: sequence, recordedAt: recordedAt, observedTimeZoneIdentifier: timezone,
                sourceRawValue: RawEventSource(rawValue: sourceText) == nil ? sourceText : nil,
                kindRawValue: RawEventKind(rawValue: kindText) == nil ? kindText : nil
            ))
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
        queryEpisodes("""
        SELECT id, start_time, end_time, title, summary, category, confidence,
               confidence_factors, activity_ids, evidence_ids
        FROM episodes WHERE end_time >= ? AND start_time <= ? ORDER BY start_time, id
        """) { statement in
            sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        } ?? []
    }

    func episodes(ids: [UUID]) -> [Episode] {
        guard !ids.isEmpty, let batches = identifierBatches(ids) else { return [] }
        var result: [Episode] = []
        for batch in batches {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            guard let episodes = queryEpisodes("""
            SELECT id, start_time, end_time, title, summary, category, confidence,
                   confidence_factors, activity_ids, evidence_ids
            FROM episodes WHERE id IN (\(placeholders))
            """, binds: { statement in
                for (index, id) in batch.enumerated() { bindText(statement, Int32(index + 1), id.uuidString) }
            }) else { return [] }
            result.append(contentsOf: episodes)
        }
        return result.sorted { lhs, rhs in
            lhs.startTime == rhs.startTime ? lhs.id.uuidString < rhs.id.uuidString : lhs.startTime < rhs.startTime
        }
    }

    private func queryEpisodes(_ sql: String, binds: (OpaquePointer) -> Void) -> [Episode]? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            lastError = Self.errorMessage(db, fallback: "时间段查询无法准备")
            return nil
        }
        binds(statement!)
        var result: [Episode] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
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
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            lastError = Self.errorMessage(db, fallback: "时间段查询未完成")
            return nil
        }
        return result
    }

    // MARK: Memories

    @discardableResult
    func insertMemory(_ memory: Memory) -> Bool {
        guard let payloadJSON = encodeJSON(memory) else {
            lastError = "记忆无法序列化为共享状态"
            return false
        }
        let sharedRecord = RiverSharedStateRecord(
            id: memory.id,
            kind: .memory,
            status: memory.isUserConfirmed ? "confirmed" : "candidate",
            logicalKey: memory.id.uuidString.lowercased(),
            payloadJSON: payloadJSON,
            createdAt: memory.createdAt,
            updatedAt: memory.lastConfirmedAt ?? memory.createdAt
        )
        guard persistSharedUserRecord(sharedRecord) else { return false }
        guard let db else { return false }
        let sql = """
        INSERT OR REPLACE INTO memories(id, title, body, kind, confidence, source_episode_ids, evidence_refs_json,
                                        created_at, last_confirmed_at, is_user_confirmed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        bindText(statement, 7, encodeJSON(memory.evidenceRefs ?? []) ?? "[]")
        sqlite3_bind_double(statement!, 8, memory.createdAt.timeIntervalSince1970)
        if let last = memory.lastConfirmedAt {
            sqlite3_bind_double(statement!, 9, last.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement!, 9)
        }
        sqlite3_bind_int64(statement!, 10, memory.isUserConfirmed ? 1 : 0)
        return stepDone(statement)
    }

    func memories() -> [Memory] {
        guard let db else { return [] }
        let sql = """
        SELECT id, title, body, kind, confidence, source_episode_ids, evidence_refs_json,
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
                evidenceRefs: decodeJSON([String].self, text(statement, 6)) ?? [],
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                lastConfirmedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                isUserConfirmed: sqlite3_column_int64(statement, 9) != 0
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
        guard let db, !ids.isEmpty, let batches = identifierBatches(ids) else { return [:] }
        var result: [UUID: (confirmed: Bool, note: String)] = [:]
        for batch in batches {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let sql = "SELECT memory_id, is_confirmed, note FROM memory_confirmations WHERE memory_id IN (\(placeholders))"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                lastError = Self.errorMessage(db, fallback: "记忆确认查询无法准备")
                return [:]
            }
            for (index, id) in batch.enumerated() { bindText(statement, Int32(index + 1), id.uuidString) }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                if let id = UUID(uuidString: text(statement, 0) ?? "") {
                    result[id] = (sqlite3_column_int64(statement, 1) != 0, text(statement, 2) ?? "")
                }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                lastError = Self.errorMessage(db, fallback: "记忆确认查询未完成")
                return [:]
            }
        }
        return result
    }

    @discardableResult
    func setMemoryConfirmation(_ memoryID: UUID, confirmed: Bool, note: String = "") -> Bool {
        let confirmedAt = Date()
        let decision = RiverMemoryConfirmation(memoryID: memoryID, confirmed: confirmed, note: note, updatedAt: confirmedAt)
        let targetID = "memory:\(memoryID.uuidString.lowercased())"
        let current = StateOperationResolver.resolve(allStateOperations()).currentByField[
            "\(targetID)\u{1f}confirmation"
        ]
        let previousDecision = current.flatMap { try? JSONDecoder().decode(RiverMemoryConfirmation.self, from: $0.payload) }
        if previousDecision?.confirmed != confirmed || previousDecision?.note != note {
            guard let payload = encodeData(decision),
                  appendStateOperation(
                    targetID: targetID,
                    fieldKey: "confirmation",
                    operationType: "memory.confirmation.set",
                    payload: payload
                  ) != nil else { return false }
        }
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

    // MARK: Versioned AI artifacts

    @discardableResult
    func insertArtifactRevision(_ revision: RiverArtifactRevision) -> Bool {
        persistArtifactRevision(revision, importedObjectID: nil, ciphertextHash: nil)
    }

    @discardableResult
    func importArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        guard SHA256Hex.hash(revision.content) == revision.contentHash else {
            throw RiverSyncStoreError.persistence("Artifact 内容摘要不匹配：\(revision.id)")
        }
        guard persistArtifactRevision(revision, importedObjectID: objectID, ciphertextHash: ciphertextHash) else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法原子保存 Artifact 修订")
        }
        return true
    }

    func restoreOwnedEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == syncDeviceID else { return false }
        guard importEventBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash) else { return false }
        let prefix = SequenceScan(sequences: try syncSequences(
            table: "raw_events", ownerColumn: "origin_device_id", owner: batch.deviceID.rawValue
        )).contiguousThrough
        guard saveSyncValue(String(prefix), for: "owned.event.sequence.\(batch.deviceID.rawValue)") else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法恢复本机 Event 前沿")
        }
        for event in batch.events {
            if let stored = rawEvents(ids: [event.id]).first {
                _ = invalidateArtifacts(covering: stored)
            }
        }
        return true
    }

    func restoreOwnedStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == syncDeviceID else { return false }
        guard importStateOperationBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash) else { return false }
        let prefix = SequenceScan(sequences: try syncSequences(
            table: "state_operations", ownerColumn: "actor_device_id", owner: batch.deviceID.rawValue
        )).contiguousThrough
        guard saveSyncValue(String(prefix), for: "owned.operation.sequence.\(batch.deviceID.rawValue)") else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法恢复本机 State Operation 前沿")
        }
        if let latest = batch.operations.max(by: { $0.clock < $1.clock }) {
            let physical = max(UInt64(syncValue("hlc.physical.\(batch.deviceID.rawValue)") ?? "0") ?? 0, latest.clock.physicalMilliseconds)
            let logical = physical == latest.clock.physicalMilliseconds
                ? max(UInt32(syncValue("hlc.logical.\(batch.deviceID.rawValue)") ?? "0") ?? 0, latest.clock.logicalCounter)
                : (UInt32(syncValue("hlc.logical.\(batch.deviceID.rawValue)") ?? "0") ?? 0)
            guard saveSyncValue(String(physical), for: "hlc.physical.\(batch.deviceID.rawValue)"),
                  saveSyncValue(String(logical), for: "hlc.logical.\(batch.deviceID.rawValue)") else {
                throw RiverSyncStoreError.persistence(lastError ?? "无法恢复本机逻辑时钟")
            }
        }
        return true
    }

    func restoreOwnedArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        guard revision.originDeviceID == syncDeviceID else { return false }
        return try importArtifactRevision(revision, objectID: objectID, ciphertextHash: ciphertextHash)
    }

    func artifactRevisions(logicalKey: String, kind: RiverArtifactKind) -> [RiverArtifactRevision] {
        queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE logical_key = ? AND artifact_type = ? ORDER BY revision_number, artifact_id"
        ) { statement in
            bindText(statement, 1, logicalKey)
            bindText(statement, 2, kind.rawValue)
        }
    }

    func localArtifactRevisions() -> [RiverArtifactRevision] {
        guard let deviceID = localDeviceIdentifier() else { return [] }
        return queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE origin_device_id = ? ORDER BY logical_millis, logical_counter, artifact_id"
        ) { statement in bindText(statement, 1, deviceID.rawValue) }
    }

    func canonicalArtifactRevisions() -> [RiverArtifactRevision] {
        applyingArtifactInvalidations(to: queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE is_canonical = 1 ORDER BY logical_key, artifact_type"
        ) { _ in })
    }

    func staleArtifactRevisionCount() -> Int {
        applyingArtifactInvalidations(to: allArtifactRevisions()).filter { $0.status == .stale }.count
    }

    func canonicalArtifactRevision(logicalKey: String, kind: RiverArtifactKind) -> RiverArtifactRevision? {
        canonicalArtifactRevisions().first { $0.logicalKey == logicalKey && $0.kind == kind }
    }

    func nextArtifactRevisionNumber(logicalKey: String, kind: RiverArtifactKind) -> UInt64 {
        UInt64(artifactRevisions(logicalKey: logicalKey, kind: kind).map(\.revisionNumber).max() ?? 0) + 1
    }

    func currentInputFrontier() throws -> InputFrontier {
        var eventSequences: [String: UInt64] = [:]
        var operationSequences: [String: UInt64] = [:]
        for registration in try allDeviceRegistrations() where registration.lifecycle == .active {
            eventSequences[registration.id.rawValue] = registration.id == localDeviceIdentifier()
                ? ownedEventFrontier()
                : importedEventFrontier(for: registration.id)
            operationSequences[registration.id.rawValue] = registration.id == localDeviceIdentifier()
                ? UInt64(syncValue("owned.operation.sequence.\(registration.id.rawValue)") ?? "0") ?? 0
                : importedOperationFrontier(for: registration.id)
        }
        return try InputFrontier(sequences: eventSequences, operationSequences: operationSequences)
    }

    @discardableResult
    func invalidateArtifacts(dependingOn dependencyType: String, id: String) -> Bool {
        let candidates = allArtifactRevisions().filter { revision in
            revision.userState == .generated && revision.dependencies.contains {
                $0.type == dependencyType && $0.id == id
            }
        }
        return markArtifactsStale(candidates, cause: "\(dependencyType):\(id)")
    }

    @discardableResult
    func invalidateGeneratedArtifactsForDiagnostics() -> Int {
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        let candidates = allArtifactRevisions().filter {
            $0.userState == .generated && $0.status != .stale && !invalidated.contains($0.id)
        }
        guard !candidates.isEmpty, markArtifactsStale(candidates, cause: "developer-diagnostics.manual") else { return 0 }
        return candidates.count
    }

    private func invalidateArtifacts(covering event: RawEvent) -> Bool {
        guard let deviceID = event.originDeviceID, event.originSequence > 0 else { return true }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        let candidates = allArtifactRevisions().filter { revision in
            guard revision.userState == .generated,
                  !invalidated.contains(revision.id),
                  revision.inputFrontier.sequences[deviceID.rawValue, default: 0] < event.originSequence else { return false }
            return revision.dependencies.contains { dependency in
                guard let start = dependency.rangeStart, let end = dependency.rangeEnd else { return false }
                return start <= event.timestamp && event.timestamp < end
            }
        }
        return markArtifactsStale(candidates, cause: "event:\(event.id.uuidString.lowercased())")
    }

    private func invalidateArtifacts(covering operation: StateOperation) -> Bool {
        guard RiverStateOperationFreshness.changesAnalyticalState(operation) else { return true }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        let candidates = allArtifactRevisions().filter { revision in
            revision.userState == .generated
                && !invalidated.contains(revision.id)
                && revision.inputFrontier.operationSequences[operation.actorDeviceID.rawValue, default: 0] < operation.originSequence
        }
        return markArtifactsStale(candidates, cause: "operation:\(operation.id.uuidString.lowercased())")
    }

    private func markArtifactsStale(_ revisions: [RiverArtifactRevision], cause: String) -> Bool {
        guard !revisions.isEmpty else { return true }
        guard let actor = localDeviceIdentifier() else { return revisions.isEmpty }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        let payload = Data(cause.utf8)
        for revision in revisions where !invalidated.contains(revision.id) {
            let operationID = RiverStableIdentifier.uuid(
                namespace: "artifact-stale.\(actor.rawValue)",
                key: "\(revision.id)|\(cause)"
            )
            guard appendStateOperation(
                id: operationID,
                targetID: revision.id,
                fieldKey: "freshness",
                operationType: "artifact.stale",
                payload: payload
            ) != nil else { return false }
        }
        return rebuildCanonicalArtifactPointers()
    }

    private func applyingArtifactInvalidations(to revisions: [RiverArtifactRevision]) -> [RiverArtifactRevision] {
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        return revisions.map { revision in
            invalidated.contains(revision.id) && revision.userState == .generated
                ? revision.replacingStatus(.stale)
                : revision
        }
    }

    private func allArtifactRevisions() -> [RiverArtifactRevision] {
        queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts ORDER BY logical_key, artifact_type, artifact_id"
        ) { _ in }
    }

    private func rebuildCanonicalArtifactPointers() -> Bool {
        let effective = applyingArtifactInvalidations(to: allArtifactRevisions())
        let groups = Dictionary(grouping: effective) { "\($0.logicalKey)\u{1f}\($0.kind.rawValue)" }
        return transaction { [self] in
            guard execute("UPDATE artifacts SET is_canonical = 0") else { return false }
            for revisions in groups.values {
                guard let resolution = try? ArtifactResolver.resolve(revisions),
                      mutate("UPDATE artifacts SET is_canonical = 1 WHERE artifact_id = ?", binds: { statement in
                          bindText(statement, 1, resolution.canonical.id)
                      }) else { return false }
            }
            return true
        }
    }

    private func reconcileLateArtifactEvents() -> Bool {
        let revisions = allArtifactRevisions().filter { $0.userState == .generated }
        guard !revisions.isEmpty else { return true }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allStateOperations())
        let events = allRawEvents()
        for revision in revisions where !invalidated.contains(revision.id) {
            let lateEvent = events.first { event in
                guard let device = event.originDeviceID,
                      event.originSequence > revision.inputFrontier.sequences[device.rawValue, default: 0] else { return false }
                return revision.dependencies.contains { dependency in
                    guard let start = dependency.rangeStart, let end = dependency.rangeEnd else { return false }
                    return start <= event.timestamp && event.timestamp < end
                }
            }
            if let lateEvent, !invalidateArtifacts(covering: lateEvent) { return false }
        }
        return rebuildCanonicalArtifactPointers()
    }

    @discardableResult
    func rebuildPlaces() -> Bool {
        let replicaEvents = effectiveRawEvents().compactMap { $0.replica() }
        let resolved = PlaceClusterEngine.build(events: replicaEvents, userOperations: allStateOperations())
        return transaction { [self] in
            guard execute("DELETE FROM places") else { return false }
            for place in resolved {
                let sql = """
                INSERT INTO places(
                    place_id, latitude, longitude, radius_meters, map_name, map_address, poi_category,
                    map_provider, map_result_identifier, user_defined_name, semantic_type,
                    is_user_confirmed, confidence, first_seen, last_seen, visit_count, total_duration_seconds
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                guard mutate(sql, binds: { statement in
                    bindText(statement, 1, place.id)
                    sqlite3_bind_double(statement, 2, place.latitude)
                    sqlite3_bind_double(statement, 3, place.longitude)
                    sqlite3_bind_double(statement, 4, place.radiusMeters)
                    bindText(statement, 5, place.mapName)
                    bindText(statement, 6, place.mapAddress)
                    bindText(statement, 7, place.poiCategory)
                    bindText(statement, 8, place.mapProvider)
                    bindText(statement, 9, place.mapResultIdentifier)
                    bindText(statement, 10, place.userDefinedName)
                    bindText(statement, 11, place.semanticType)
                    sqlite3_bind_int64(statement, 12, place.isUserConfirmed ? 1 : 0)
                    sqlite3_bind_double(statement, 13, place.confidence)
                    sqlite3_bind_double(statement, 14, place.firstSeen.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 15, place.lastSeen.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 16, Int64(place.visitCount))
                    sqlite3_bind_double(statement, 17, place.totalDurationSeconds)
                }) else { return false }
            }
            return true
        }
    }

    func places() -> [RiverPlace] {
        guard let db else { return [] }
        let sql = "SELECT place_id, latitude, longitude, radius_meters, map_name, map_address, poi_category, map_provider, map_result_identifier, user_defined_name, semantic_type, is_user_confirmed, confidence, first_seen, last_seen, visit_count, total_duration_seconds FROM places ORDER BY first_seen, place_id"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [RiverPlace] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0) else { continue }
            result.append(RiverPlace(
                id: id,
                latitude: sqlite3_column_double(statement, 1),
                longitude: sqlite3_column_double(statement, 2),
                radiusMeters: sqlite3_column_double(statement, 3),
                mapName: text(statement, 4),
                mapAddress: text(statement, 5),
                poiCategory: text(statement, 6),
                mapProvider: text(statement, 7),
                mapResultIdentifier: text(statement, 8),
                userDefinedName: text(statement, 9),
                semanticType: text(statement, 10),
                isUserConfirmed: sqlite3_column_int64(statement, 11) != 0,
                confidence: sqlite3_column_double(statement, 12),
                firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13)),
                lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 14)),
                visitCount: Int(sqlite3_column_int64(statement, 15)),
                totalDurationSeconds: sqlite3_column_double(statement, 16)
            ))
        }
        return result
    }

    func sharedUserRecords() -> [RiverSharedStateRecord] {
        let operations = allStateOperations()
        let tombstones = StateOperationResolver.tombstonedObjectIDs(operations)
        return StateOperationResolver.resolve(operations).currentByField.values.compactMap { operation in
            guard operation.operationType == "shared.record.upsert", operation.fieldKey == "record",
                  let record = try? JSONDecoder().decode(RiverSharedStateRecord.self, from: operation.payload),
                  record.targetID == operation.targetID else { return nil }
            return record
        }.filter { record in
            guard record.kind == .quickCaptureMetadata,
                  let metadata = record.quickCaptureMetadata else { return true }
            return !tombstones.contains("event:\(metadata.eventID.uuidString)")
        }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult
    func saveSharedUserRecord(_ record: RiverSharedStateRecord) -> Bool {
        persistSharedUserRecord(record)
    }

    @discardableResult
    func resolvePendingTimelineConfirmation(annotationKey: String, annotation: TimelineAnnotation) -> Bool {
        guard annotation.isReviewed else { return true }
        guard let record = sharedUserRecords().first(where: {
            $0.kind == .pendingConfirmation && $0.status == "pending"
                && $0.pendingConfirmationContent?.targetType == "timelineCandidate"
                && $0.pendingConfirmationContent?.targetID == annotationKey
        }) else { return true }
        let correction = [annotation.title, annotation.activityLabel, annotation.note, annotation.placeName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let resolution: RiverPendingConfirmationResolution = correction.isEmpty ? .dismissed : .corrected
        guard let updated = record.resolving(
            resolution, correction: correction.isEmpty ? nil : correction,
            at: annotation.reviewedAt ?? annotation.updatedAt
        ) else { return false }
        return persistSharedUserRecord(updated)
    }

    @discardableResult
    func setMoodScore(dayKey: String, score: Int, updatedAt: Date) -> Bool {
        guard (0...100).contains(score), let deviceID = localDeviceIdentifier(),
              let payload = try? JSONEncoder().encode(RiverMoodScoreDecision(day: dayKey, score: score)) else { return false }
        let targetID = "mood:\(dayKey)"
        let current = StateOperationResolver.resolve(allStateOperations()).currentByField[
            "\(targetID)\u{1f}score"
        ]
        if current?.operationType == "mood.score.set", current?.payload == payload { return true }
        let operationID = RiverStableIdentifier.uuid(
            namespace: "mood.score.set.\(deviceID.rawValue)",
            key: "\(dayKey)|\(updatedAt.timeIntervalSince1970.bitPattern)|\(score)"
        )
        return appendStateOperation(
            id: operationID, targetID: targetID, fieldKey: "score",
            operationType: "mood.score.set", payload: payload
        ) != nil
    }

    @discardableResult
    func resetMoodScore(dayKey: String, updatedAt: Date) -> Bool {
        guard let deviceID = localDeviceIdentifier(),
              let payload = try? JSONEncoder().encode(RiverMoodScoreReset(day: dayKey)) else { return false }
        let targetID = "mood:\(dayKey)"
        let current = StateOperationResolver.resolve(allStateOperations()).currentByField[
            "\(targetID)\u{1f}score"
        ]
        if current?.operationType == "mood.score.reset", current?.payload == payload { return true }
        let operationID = RiverStableIdentifier.uuid(
            namespace: "mood.score.reset.\(deviceID.rawValue)",
            key: "\(dayKey)|\(updatedAt.timeIntervalSince1970.bitPattern)"
        )
        return appendStateOperation(
            id: operationID, targetID: targetID, fieldKey: "score",
            operationType: "mood.score.reset", payload: payload
        ) != nil
    }

    @discardableResult
    func resolvePendingConfirmation(_ record: RiverSharedStateRecord,
                                    as resolution: RiverPendingConfirmationResolution,
                                    correction: String? = nil,
                                    selectedCandidateID: String? = nil) -> Bool {
        guard let deviceID = localDeviceIdentifier(),
              let current = sharedUserRecords().first(where: { $0.id == record.id }) else {
            lastError = "这条待确认事项已在本机处理或已同步更新"
            return false
        }
        guard current.status == "pending" else { return rebuildPlaces() }
        guard let content = current.pendingConfirmationContent else {
            lastError = "待确认事项缺少有效内容"
            return false
        }
        let resolvedAt = Date()
        guard let updated = current.resolving(resolution, correction: correction,
                                             selectedCandidateID: selectedCandidateID, at: resolvedAt) else {
            lastError = "这条待确认事项已处理，或内容格式不受支持"
            return false
        }
        var drafts: [StateOperationDraft] = []
        if content.targetType == "place", let placeID = content.targetID, resolution != .dismissed {
            let name: String
            let semanticType: String
            switch resolution {
            case .confirmed:
                guard let candidate = content.candidate, !candidate.isEmpty else {
                    lastError = "地点候选名称为空，不能确认"
                    return false
                }
                name = candidate
                semanticType = places().first(where: { $0.id == placeID })?.poiCategory ?? "place"
            case .corrected:
                if let selectedCandidateID,
                   let selected = content.choices?.first(where: { $0.id == selectedCandidateID }) {
                    name = selected.name
                    semanticType = selected.suggestedKind ?? selected.category ?? "place"
                } else {
                    guard let value = correction?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                        lastError = "请填写地点名称后再保存"
                        return false
                    }
                    name = value
                    semanticType = "userDefined"
                }
            case .rejected, .dismissed:
                name = ""
                semanticType = ""
            }
            guard let payload = try? JSONEncoder().encode(RiverPlaceUserDecision(
                name: name, semanticType: semanticType,
                isConfirmed: resolution == .confirmed || resolution == .corrected
            )) else { return false }
            drafts.append(StateOperationDraft(
                id: RiverStableIdentifier.uuid(
                    namespace: "pending-confirmation.place.identity.\(deviceID.rawValue)",
                    key: "place:\(placeID)|\(SHA256Hex.hash(payload))"
                ),
                targetID: placeID,
                fieldKey: "identity",
                operationType: "place.identity.set",
                payload: payload
            ))
        } else if content.targetType == "timelineCandidate", let annotationKey = content.targetID {
            let title: String
            let note: String
            switch resolution {
            case .confirmed:
                title = content.candidate ?? ""
                note = "用户确认了这条时间线观察。"
            case .corrected:
                guard let value = correction?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    lastError = "请填写时间线说明后再保存"
                    return false
                }
                title = value
                note = "用户修正了 AI 的时间线观察。"
            case .rejected:
                title = ""
                note = "用户标记这条时间线观察不准确。"
            case .dismissed:
                title = ""
                note = "用户已查看这段记录，暂不需要补充。"
            }
            let annotation = TimelineAnnotation(
                title: title, note: note, isReviewed: true, reviewedAt: resolvedAt, updatedAt: resolvedAt
            )
            guard let payload = try? JSONEncoder().encode(annotation) else { return false }
            drafts.append(StateOperationDraft(
                id: RiverStableIdentifier.uuid(
                    namespace: "pending-confirmation.timeline.annotation.\(deviceID.rawValue)",
                    key: "\(annotationKey)|\(SHA256Hex.hash(payload))"
                ),
                targetID: annotationKey,
                fieldKey: "annotation",
                operationType: "timeline.annotation.set",
                payload: payload
            ))
        }

        guard let updatedPayloadText = encodeJSON(updated),
              let updatedPayload = updatedPayloadText.data(using: .utf8) else {
            lastError = "待确认事项无法序列化"
            return false
        }
        drafts.append(StateOperationDraft(
            id: RiverStableIdentifier.uuid(
                namespace: "shared.record.upsert.\(deviceID.rawValue)",
                key: "\(updated.id.uuidString.lowercased())|\(SHA256Hex.hash(updatedPayload))"
            ),
            targetID: updated.targetID,
            fieldKey: "record",
            operationType: "shared.record.upsert",
            payload: updatedPayload
        ))
        guard appendStateOperationsAtomically(drafts) != nil else { return false }
        return rebuildPlaces()
    }

    private func persistArtifactRevision(_ revision: RiverArtifactRevision, importedObjectID: String?, ciphertextHash: String?) -> Bool {
        guard db != nil, SHA256Hex.hash(revision.content) == revision.contentHash,
              let frontierJSON = encodeJSON(revision.inputFrontier) else {
            lastError = "Artifact 内容摘要或输入 frontier 无效"
            return false
        }
        return transaction { [self] in
            if let existing = artifactRevision(id: revision.id) {
                guard existing == revision else {
                    lastError = "Artifact 修订 ID 对应不同内容：\(revision.id)"
                    return false
                }
            } else {
                let sql = """
                INSERT INTO artifacts(
                    artifact_id, logical_key, artifact_type, revision_number, origin_device_id,
                    logical_millis, logical_counter, input_frontier_json, input_snapshot_hash,
                    pipeline_version, prompt_version, model_provider, model_identifier, content,
                    content_hash, status, user_state, is_canonical, supersedes_revision_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
                """
                guard mutate(sql, binds: { statement in
                    bindText(statement, 1, revision.id)
                    bindText(statement, 2, revision.logicalKey)
                    bindText(statement, 3, revision.kind.rawValue)
                    sqlite3_bind_int64(statement, 4, Int64(revision.revisionNumber))
                    bindText(statement, 5, revision.originDeviceID.rawValue)
                    sqlite3_bind_int64(statement, 6, Int64(revision.clock.physicalMilliseconds))
                    sqlite3_bind_int64(statement, 7, Int64(revision.clock.logicalCounter))
                    bindText(statement, 8, frontierJSON)
                    bindText(statement, 9, revision.inputSnapshotHash)
                    bindText(statement, 10, revision.pipelineVersion)
                    bindText(statement, 11, revision.promptVersion)
                    bindText(statement, 12, revision.modelProvider)
                    bindText(statement, 13, revision.modelIdentifier)
                    bindBlob(statement, 14, revision.content)
                    bindText(statement, 15, revision.contentHash)
                    bindText(statement, 16, revision.status.rawValue)
                    sqlite3_bind_int64(statement, 17, Int64(revision.userState.rawValue))
                    bindText(statement, 18, revision.supersedesRevisionID)
                    sqlite3_bind_double(statement, 19, Double(revision.clock.physicalMilliseconds) / 1_000)
                }) else { return false }
            }
            for dependency in revision.dependencies {
                let insertedDependency = mutate(
                    "INSERT OR IGNORE INTO artifact_dependencies(artifact_id, dependency_type, dependency_id, range_start, range_end) VALUES (?, ?, ?, ?, ?)",
                    binds: { statement in
                        bindText(statement, 1, revision.id)
                        bindText(statement, 2, dependency.type)
                        bindText(statement, 3, dependency.id)
                        if let start = dependency.rangeStart { sqlite3_bind_double(statement, 4, start.timeIntervalSince1970) }
                        else { sqlite3_bind_null(statement, 4) }
                        if let end = dependency.rangeEnd { sqlite3_bind_double(statement, 5, end.timeIntervalSince1970) }
                        else { sqlite3_bind_null(statement, 5) }
                    }
                )
                guard insertedDependency else { return false }
            }
            let candidates = applyingArtifactInvalidations(to: artifactRevisions(logicalKey: revision.logicalKey, kind: revision.kind))
            guard let resolution = try? ArtifactResolver.resolve(candidates),
                  mutate("UPDATE artifacts SET is_canonical = 0 WHERE logical_key = ? AND artifact_type = ?", binds: { statement in
                      bindText(statement, 1, revision.logicalKey)
                      bindText(statement, 2, revision.kind.rawValue)
                  }),
                  mutate("UPDATE artifacts SET is_canonical = 1 WHERE artifact_id = ?", binds: { statement in
                      bindText(statement, 1, resolution.canonical.id)
                  }) else {
                lastError = "Artifact canonical 指针切换失败：\(revision.logicalKey)"
                return false
            }
            if let importedObjectID, let ciphertextHash {
                if syncImportExists(importedObjectID) { return true }
                return mutate("INSERT INTO sync_imports(object_id, source_device_id, object_type, ciphertext_hash, imported_at) VALUES (?, ?, 'artifact_revision', ?, ?)") { statement in
                    bindText(statement, 1, importedObjectID)
                    bindText(statement, 2, revision.originDeviceID.rawValue)
                    bindText(statement, 3, ciphertextHash)
                    sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                }
            }
            return true
        }
    }

    private func artifactRevision(id: String) -> RiverArtifactRevision? {
        queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE artifact_id = ? LIMIT 1"
        ) { statement in bindText(statement, 1, id) }.first
    }

    private func queryArtifactRevisions(_ sql: String, binds: (OpaquePointer) -> Void) -> [RiverArtifactRevision] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        binds(statement!)
        var revisions: [RiverArtifactRevision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0), let logicalKey = text(statement, 1),
                  let kind = RiverArtifactKind(rawValue: text(statement, 2) ?? ""),
                  let deviceText = text(statement, 4),
                  let frontierData = text(statement, 7)?.data(using: .utf8),
                  let frontier = try? decoder.decode(InputFrontier.self, from: frontierData),
                  let content = blob(statement, 13),
                  let status = ArtifactStatus(rawValue: text(statement, 15) ?? "") else { continue }
            let deviceID = RiverDeviceID(rawValue: deviceText)
            revisions.append(RiverArtifactRevision(
                id: id,
                logicalKey: logicalKey,
                kind: kind,
                revisionNumber: UInt64(max(0, sqlite3_column_int64(statement, 3))),
                originDeviceID: deviceID,
                clock: HybridLogicalClock(
                    physicalMilliseconds: UInt64(max(0, sqlite3_column_int64(statement, 5))),
                    logicalCounter: UInt32(max(0, sqlite3_column_int64(statement, 6))),
                    deviceID: deviceID
                ),
                inputFrontier: frontier,
                inputSnapshotHash: text(statement, 8) ?? "",
                pipelineVersion: text(statement, 9) ?? "",
                promptVersion: text(statement, 10) ?? "",
                modelProvider: text(statement, 11) ?? "",
                modelIdentifier: text(statement, 12) ?? "",
                content: content,
                contentHash: text(statement, 14) ?? "",
                status: status,
                userState: ArtifactUserState(rawValue: Int(sqlite3_column_int64(statement, 16))) ?? .generated,
                supersedesRevisionID: text(statement, 17),
                dependencies: artifactDependencies(for: id)
            ))
        }
        return revisions
    }

    private func artifactDependencies(for artifactID: String) -> [ArtifactDependency] {
        guard let db else { return [] }
        let sql = "SELECT dependency_type, dependency_id, range_start, range_end FROM artifact_dependencies WHERE artifact_id = ? ORDER BY dependency_type, dependency_id"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bindText(statement, 1, artifactID)
        var result: [ArtifactDependency] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = text(statement, 0), let id = text(statement, 1) else { continue }
            let start = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let end = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            result.append(ArtifactDependency(type: type, id: id, rangeStart: start, rangeEnd: end))
        }
        return result
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
        guard db != nil else { return false }
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
        guard db != nil else { return false }
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

    @discardableResult
    func saveAnalysisJob(_ job: RiverAnalysisJob) -> Bool {
        guard let payloadJSON = encodeJSON(job),
              let frontierJSON = encodeJSON(job.inputFrontier) else { return false }
        let sql = """
        INSERT INTO analysis_jobs(job_id, logical_key, artifact_type, input_frontier_json, priority, status, created_at, started_at, finished_at, attempt, origin_device_id, pipeline_version, prompt_version, last_error, payload_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(job_id) DO UPDATE SET status=excluded.status, started_at=excluded.started_at, finished_at=excluded.finished_at, attempt=excluded.attempt, last_error=excluded.last_error, payload_json=excluded.payload_json
        """
        return mutate(sql) { statement in
            bindText(statement, 1, job.id.uuidString.lowercased())
            bindText(statement, 2, job.logicalKey)
            bindText(statement, 3, job.artifactType.rawValue)
            bindText(statement, 4, frontierJSON)
            sqlite3_bind_int64(statement, 5, Int64(job.priority))
            bindText(statement, 6, job.status.rawValue)
            sqlite3_bind_double(statement, 7, job.createdAt.timeIntervalSince1970)
            if let date = job.startedAt { sqlite3_bind_double(statement, 8, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 8) }
            if let date = job.finishedAt { sqlite3_bind_double(statement, 9, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 9) }
            sqlite3_bind_int64(statement, 10, Int64(job.attempt))
            bindText(statement, 11, job.originDeviceID.rawValue)
            bindText(statement, 12, job.pipelineVersion)
            bindText(statement, 13, job.promptVersion)
            bindText(statement, 14, job.lastError)
            bindText(statement, 15, payloadJSON)
        }
    }

    func analysisJobs() -> [RiverAnalysisJob] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT payload_json FROM analysis_jobs ORDER BY priority DESC, created_at, job_id", -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [RiverAnalysisJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let payload = text(statement, 0), let job = decodeJSON(RiverAnalysisJob.self, payload) else { continue }
            result.append(job)
        }
        return result
    }

    func latestAnalysisJob() -> RiverAnalysisJob? {
        analysisJobs().max { $0.createdAt < $1.createdAt }
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

    @discardableResult
    func setSharedHabitPreference(key: String, value: String) -> Bool {
        let target = "habit:preference:\(key)"
        guard let payload = try? JSONEncoder().encode(value) else { return false }
        let current = StateOperationResolver.resolve(allStateOperations()).currentByField[
            "\(target)\u{1f}value"
        ]
        if current?.operationType == "habit.preference.set", current?.payload == payload { return true }
        return appendStateOperation(
            targetID: target, fieldKey: "value", operationType: "habit.preference.set", payload: payload
        ) != nil
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
        let record = RiverSharedStateRecord(
            id: id, kind: .habitRule, status: status, logicalKey: id.uuidString.lowercased(),
            payloadJSON: payloadJSON, createdAt: updatedAt, updatedAt: updatedAt
        )
        guard persistSharedUserRecord(record) else { return false }
        return mutate(
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
        let record = RiverSharedStateRecord(
            id: id, kind: .habitCard, status: status, logicalKey: dedupKey,
            payloadJSON: payloadJSON, createdAt: updatedAt, updatedAt: updatedAt, batchID: batchID
        )
        guard persistSharedUserRecord(record) else { return false }
        return mutate(
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
        let record = RiverSharedStateRecord(
            id: id, kind: .habitBatch, status: shownAt == nil ? "created" : "shown",
            logicalKey: periodKey, payloadJSON: payloadJSON, createdAt: createdAt,
            updatedAt: shownAt ?? createdAt, shownAt: shownAt
        )
        guard persistSharedUserRecord(record) else { return false }
        return mutate(
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

    private func persistSharedUserRecord(_ record: RiverSharedStateRecord) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(record) else {
            lastError = "共享回顾记录序列化失败"
            return false
        }
        let current = StateOperationResolver.resolve(allStateOperations()).currentByField[
            "\(record.targetID)\u{1f}record"
        ]
        if let current,
           let existing = try? JSONDecoder().decode(RiverSharedStateRecord.self, from: current.payload),
           existing.id == record.id, existing.kind == record.kind, existing.status == record.status,
           existing.logicalKey == record.logicalKey, existing.payloadJSON == record.payloadJSON,
           existing.batchID == record.batchID, existing.shownAt == record.shownAt {
            return true
        }
        guard appendStateOperation(
            targetID: record.targetID,
            fieldKey: "record",
            operationType: "shared.record.upsert",
            payload: payload
        ) != nil else { return false }
        return true
    }

    private func reconcileLateArtifactOperations() -> Bool {
        let allOperations = allStateOperations()
        let operations = StateOperationResolver.currentAnalyticalOperations(allOperations)
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(allOperations)
        for revision in allArtifactRevisions()
        where revision.userState == .generated && !invalidated.contains(revision.id) {
            guard let operation = operations.first(where: {
                $0.originSequence > revision.inputFrontier.operationSequences[$0.actorDeviceID.rawValue, default: 0]
            }) else { continue }
            guard markArtifactsStale([revision], cause: "operation:\(operation.id.uuidString.lowercased())") else { return false }
        }
        return true
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

    /// 清除本机实时活动的有效视图：删除可重建投影，并为原始事件追加墓碑。
    /// 原始证据留在库中，墓碑与事件一起复制，避免另一台设备重新导入后复活。
    func clearActivityEvidence() -> Bool {
        let events = effectiveRawEvents().filter {
            $0.persistedSource == RawEventSource.systemApp.rawValue
                && $0.persistedKind == RawEventKind.appForeground.rawValue
        }
        for event in events {
            let deleted = Data("true".utf8)
            guard appendStateOperation(
                targetID: "event:\(event.id.uuidString)",
                fieldKey: "deleted",
                operationType: "object.tombstone",
                payload: deleted
            ) != nil else { return false }
            _ = invalidateArtifacts(dependingOn: "event", id: event.id.uuidString)
        }
        let cleaned = transaction {
            guard execute("DELETE FROM activities") else { return false }
            guard execute("DELETE FROM episodes") else { return false }
            return true
        }
        return cleaned
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

    /// Deduplicate shared references and respect this connection's actual bind limit.
    private func identifierBatches(_ ids: [UUID]) -> [ArraySlice<UUID>]? {
        guard let db else { return nil }
        let parameterLimit = Int(sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1))
        guard parameterLimit > 0 else {
            lastError = "数据库不允许带参数的 ID 查询"
            return nil
        }
        let values = Array(Set(ids))
        let batchSize = min(400, parameterLimit)
        return stride(from: 0, to: values.count, by: batchSize).map { offset in
            values[offset..<min(offset + batchSize, values.count)]
        }
    }

    /// 在单个事务里执行一组写入。V2Store 此前没有事务助手，"删除+插入"
    /// 这类多语句写各自跑在 autocommit 里——中间失败会永久丢掉旧结果。
    /// 传入的闭包返回 false 时回滚并返回 false（lastError 已由内部语句设置）。
    private func transaction(_ work: () -> Bool) -> Bool {
        guard db != nil else { return false }
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

    private func blob(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: c)
    }

    private func bindBlob(_ statement: OpaquePointer?, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
        }
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeData<T: Encodable>(_ value: T) -> Data? {
        try? encoder.encode(value)
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

extension V2Store: RiverSyncLocalStore {
    var syncDeviceID: RiverDeviceID? { localDeviceIdentifier() }

    func localEventBatches() throws -> [RiverEventBatch] { exportableRawEventBatches() }
    func localStateOperationBatches() throws -> [StateOperationBatch] { exportableStateOperationBatches() }

    func importedObjectExists(_ objectID: String) throws -> Bool { syncImportExists(objectID) }

    func ownedFrontier() throws -> StreamFrontier {
        guard let deviceID = localDeviceIdentifier() else { throw RiverSyncCoordinatorError.deviceIdentityUnavailable }
        return StreamFrontier(
            events: ownedEventFrontier(),
            operations: UInt64(syncValue("owned.operation.sequence.\(deviceID.rawValue)") ?? "0") ?? 0
        )
    }

    func importedFrontiers(for deviceIDs: Set<RiverDeviceID>) throws -> [String: StreamFrontier] {
        var result: [String: StreamFrontier] = [:]
        for deviceID in deviceIDs {
            result[deviceID.rawValue] = StreamFrontier(
                events: importedEventFrontier(for: deviceID),
                operations: UInt64(syncValue("imported.operation.prefix.\(deviceID.rawValue)") ?? "0") ?? 0
            )
        }
        return result
    }

    func sequenceGapDevices(expectedFrontiers: [String: StreamFrontier]) throws -> Set<RiverDeviceID> {
        var gaps = Set<RiverDeviceID>()
        for (deviceText, frontier) in expectedFrontiers {
            let deviceID = RiverDeviceID(rawValue: deviceText)
            let events = try syncSequences(table: "raw_events", ownerColumn: "origin_device_id", owner: deviceText)
            let operations = try syncSequences(table: "state_operations", ownerColumn: "actor_device_id", owner: deviceText)
            if SequenceScan(sequences: events).contiguousThrough < frontier.events
                || SequenceScan(sequences: operations).contiguousThrough < frontier.operations {
                gaps.insert(deviceID)
            }
        }
        return gaps
    }

    func sequenceGaps(expectedFrontiers: [String: StreamFrontier]) throws -> [SyncSequenceGap] {
        var result: [SyncSequenceGap] = []
        for (deviceText, frontier) in expectedFrontiers {
            let deviceID = RiverDeviceID(rawValue: deviceText)
            let streams: [(String, [UInt64], UInt64)] = [
                ("Events", try syncSequences(table: "raw_events", ownerColumn: "origin_device_id", owner: deviceText), frontier.events),
                ("Operations", try syncSequences(table: "state_operations", ownerColumn: "actor_device_id", owner: deviceText), frontier.operations)
            ]
            for (stream, values, expected) in streams where expected > 0 {
                var cursor: UInt64 = 1
                for sequence in Set(values.filter { $0 <= expected }).sorted() {
                    if sequence > cursor {
                        result.append(SyncSequenceGap(deviceID: deviceID, stream: stream, first: cursor, last: sequence - 1))
                    }
                    if sequence >= cursor { cursor = sequence == UInt64.max ? UInt64.max : sequence + 1 }
                }
                if cursor <= expected {
                    result.append(SyncSequenceGap(deviceID: deviceID, stream: stream, first: cursor, last: expected))
                }
            }
        }
        return result
    }

    func allDeviceRegistrations() throws -> [DeviceRegistration] {
        guard let db else { return [] }
        let sql = "SELECT device_id, display_name, platform, lifecycle, logical_millis, logical_counter FROM devices"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RiverSyncStoreError.persistence(Self.errorMessage(db, fallback: "读取设备登记失败"))
        }
        var result: [DeviceRegistration] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = text(statement, 0),
                  let lifecycle = DeviceLifecycle(rawValue: text(statement, 3) ?? "active") else { continue }
            let deviceID = RiverDeviceID(rawValue: id)
            result.append(DeviceRegistration(
                id: deviceID,
                displayName: text(statement, 1) ?? id,
                platform: text(statement, 2) ?? "unknown",
                lifecycle: lifecycle,
                clock: HybridLogicalClock(
                    physicalMilliseconds: UInt64(max(0, sqlite3_column_int64(statement, 4))),
                    logicalCounter: UInt32(max(0, sqlite3_column_int64(statement, 5))),
                    deviceID: deviceID
                )
            ))
        }
        return result
    }

    func mergeDeviceRegistrations(_ incoming: [DeviceRegistration]) throws {
        let merged = DeviceRegistry.merge(try allDeviceRegistrations() + incoming)
        let ok = transaction { [self] in
            for registration in merged {
                let sql = "INSERT OR REPLACE INTO devices(device_id, display_name, platform, lifecycle, logical_millis, logical_counter, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
                guard mutate(sql, binds: { statement in
                    bindText(statement, 1, registration.id.rawValue)
                    bindText(statement, 2, registration.displayName)
                    bindText(statement, 3, registration.platform)
                    bindText(statement, 4, registration.lifecycle.rawValue)
                    sqlite3_bind_int64(statement, 5, Int64(registration.clock.physicalMilliseconds))
                    sqlite3_bind_int64(statement, 6, Int64(registration.clock.logicalCounter))
                    sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
                }) else { return false }
            }
            return true
        }
        guard ok else { throw RiverSyncStoreError.persistence(lastError ?? "合并设备登记失败") }
    }

    func reconcileDeviceRegistryFromOperations() throws {
        let operations = allStateOperations().filter { $0.operationType == "device.lifecycle.set" }
        let resolved = StateOperationResolver.resolve(operations)
        let registrations = resolved.currentByField.values.compactMap { operation -> DeviceRegistration? in
            guard operation.targetID.hasPrefix("device:"),
                  let payload = try? decoder.decode(DeviceLifecyclePayload.self, from: operation.payload) else { return nil }
            let id = RiverDeviceID(rawValue: String(operation.targetID.dropFirst("device:".count)))
            return DeviceRegistration(
                id: id,
                displayName: payload.displayName,
                platform: payload.platform,
                lifecycle: payload.lifecycle,
                clock: operation.clock
            )
        }
        try mergeDeviceRegistrations(registrations)
    }

    func rebuildDerivedState() throws {
        guard saveSyncValue("1", for: Self.derivedRebuildRequiredKey) else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法标记派生状态需要重建")
        }
        try reconcileDerivedStateIfNeeded()
    }

    func reconcileDerivedStateIfNeeded() throws {
        guard syncValue(Self.derivedRebuildRequiredKey) != "0"
                || syncValue(Self.pendingEventInvalidationKey) != "0" else { return }
        guard rebuildPlaces() else {
            throw RiverSyncStoreError.persistence(lastError ?? "地点投影重建失败")
        }
        guard reconcileLateArtifactEvents() else {
            throw RiverSyncStoreError.persistence(lastError ?? "Artifact 依赖失效重建失败")
        }
        guard reconcileLateArtifactOperations() else {
            throw RiverSyncStoreError.persistence(lastError ?? "State Operation 依赖失效重建失败")
        }
        guard reconcileSharedUserRecordsFromOperations() else {
            throw RiverSyncStoreError.persistence(lastError ?? "共享用户状态投影重建失败")
        }
        guard saveSyncValue("0", for: Self.derivedRebuildRequiredKey) else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法完成派生状态核对")
        }
        guard saveSyncValue("0", for: Self.pendingEventInvalidationKey) else {
            throw RiverSyncStoreError.persistence(lastError ?? "无法完成本机 Event 失效核对")
        }
    }

    private func reconcileSharedUserRecordsFromOperations() -> Bool {
        let existingPreferences = Set(allStateOperations()
            .filter { $0.operationType == "habit.preference.set" }
            .map(\.targetID))
        for key in ["habit.review.cadence", "habit.review.timePreset"]
        where !existingPreferences.contains("habit:preference:\(key)") {
            if let value = userPref(key: key), !setSharedHabitPreference(key: key, value: value) { return false }
        }
        let resolvedOperations = StateOperationResolver.resolve(allStateOperations()).currentByField.values
        for operation in resolvedOperations where operation.operationType == "habit.preference.set" {
            guard operation.targetID.hasPrefix("habit:preference:"),
                  let value = try? JSONDecoder().decode(String.self, from: operation.payload) else { continue }
            let key = String(operation.targetID.dropFirst("habit:preference:".count))
            guard setUserPref(key: key, value: value) else { return false }
        }
        let alreadyShared = Set(allStateOperations()
            .filter { $0.operationType == "shared.record.upsert" && $0.fieldKey == "record" }
            .map(\.targetID))
        let legacyRecords = habitRuleRows().map { row in
            RiverSharedStateRecord(id: row.id, kind: .habitRule, status: row.status,
                                   logicalKey: row.id.uuidString.lowercased(), payloadJSON: row.payloadJSON,
                                   createdAt: row.createdAt, updatedAt: row.createdAt)
        } + habitCardRows().map { row in
            RiverSharedStateRecord(id: row.id, kind: .habitCard, status: row.status,
                                   logicalKey: row.dedupKey, payloadJSON: row.payloadJSON,
                                   createdAt: row.createdAt, updatedAt: row.createdAt, batchID: row.batchID)
        } + habitBatchRows().map { row in
            RiverSharedStateRecord(id: row.id, kind: .habitBatch, status: row.shownAt == nil ? "created" : "shown",
                                   logicalKey: row.periodKey, payloadJSON: row.payloadJSON,
                                   createdAt: row.createdAt, updatedAt: row.shownAt ?? row.createdAt,
                                   shownAt: row.shownAt)
        } + memories().map { memory in
            RiverSharedStateRecord(
                id: memory.id, kind: .memory, status: memory.isUserConfirmed ? "confirmed" : "candidate",
                logicalKey: memory.id.uuidString.lowercased(), payloadJSON: encodeJSON(memory) ?? "{}",
                createdAt: memory.createdAt, updatedAt: memory.lastConfirmedAt ?? memory.createdAt
            )
        }
        for record in legacyRecords where !alreadyShared.contains(record.targetID) {
            guard persistSharedUserRecord(record) else { return false }
        }

        let existingConfirmationTargets = Set(allStateOperations()
            .filter { $0.operationType == "memory.confirmation.set" && $0.fieldKey == "confirmation" }
            .map(\.targetID))
        let legacyMemories = memories()
        let storedConfirmations = memoryConfirmations(ids: legacyMemories.map(\.id))
        for memory in legacyMemories where !existingConfirmationTargets.contains("memory:\(memory.id.uuidString.lowercased())") {
            let legacyConfirmation = storedConfirmations[memory.id]
            let confirmed = legacyConfirmation?.confirmed ?? memory.isUserConfirmed
            guard confirmed || legacyConfirmation != nil else { continue }
            guard setMemoryConfirmation(memory.id, confirmed: confirmed, note: legacyConfirmation?.note ?? "") else { return false }
        }

        let current = StateOperationResolver.resolve(allStateOperations()).currentByField.values
            .filter { $0.operationType == "shared.record.upsert" && $0.fieldKey == "record" }
        for operation in current {
            guard let record = try? JSONDecoder().decode(RiverSharedStateRecord.self, from: operation.payload),
                  operation.targetID == record.targetID else {
                lastError = "共享习惯/复盘操作无法解码：\(operation.id.uuidString)"
                return false
            }
            let ok: Bool
            switch record.kind {
            case .habitRule:
                ok = mutate("INSERT OR REPLACE INTO habit_rules(id, status, payload_json, updated_at) VALUES (?, ?, ?, ?)") { statement in
                    bindText(statement, 1, record.id.uuidString)
                    bindText(statement, 2, record.status)
                    bindText(statement, 3, record.payloadJSON)
                    sqlite3_bind_double(statement, 4, record.updatedAt.timeIntervalSince1970)
                }
            case .habitCard:
                ok = mutate("INSERT OR REPLACE INTO habit_cards(id, batch_id, dedup_key, status, payload_json, updated_at) VALUES (?, ?, ?, ?, ?, ?)") { statement in
                    bindText(statement, 1, record.id.uuidString)
                    if let batchID = record.batchID { bindText(statement, 2, batchID.uuidString) }
                    else { sqlite3_bind_null(statement, 2) }
                    bindText(statement, 3, record.logicalKey)
                    bindText(statement, 4, record.status)
                    bindText(statement, 5, record.payloadJSON)
                    sqlite3_bind_double(statement, 6, record.updatedAt.timeIntervalSince1970)
                }
            case .habitBatch:
                ok = mutate("INSERT OR REPLACE INTO habit_batches(id, period_key, payload_json, created_at, shown_at) VALUES (?, ?, ?, ?, ?)") { statement in
                    bindText(statement, 1, record.id.uuidString)
                    bindText(statement, 2, record.logicalKey)
                    bindText(statement, 3, record.payloadJSON)
                    sqlite3_bind_double(statement, 4, record.createdAt.timeIntervalSince1970)
                    if let shownAt = record.shownAt { sqlite3_bind_double(statement, 5, shownAt.timeIntervalSince1970) }
                    else { sqlite3_bind_null(statement, 5) }
                }
            case .memory:
                if record.status == "deleted" {
                    ok = mutate("DELETE FROM memories WHERE id = ?") { statement in
                        bindText(statement, 1, record.id.uuidString)
                    }
                } else {
                    guard let memory = decodeJSON(Memory.self, record.payloadJSON) else {
                        lastError = "共享记忆记录无法解码：\(record.id.uuidString)"
                        return false
                    }
                    ok = mutate("INSERT OR REPLACE INTO memories(id, title, body, kind, confidence, source_episode_ids, evidence_refs_json, created_at, last_confirmed_at, is_user_confirmed) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)") { statement in
                        bindText(statement, 1, memory.id.uuidString)
                        bindText(statement, 2, memory.title)
                        bindText(statement, 3, memory.body)
                        bindText(statement, 4, memory.kind.rawValue)
                        sqlite3_bind_int64(statement, 5, Int64(memory.confidence))
                        bindText(statement, 6, JSONEncoder.uuids(memory.sourceEpisodeIDs))
                        bindText(statement, 7, encodeJSON(memory.evidenceRefs ?? []) ?? "[]")
                        sqlite3_bind_double(statement, 8, memory.createdAt.timeIntervalSince1970)
                        if let date = memory.lastConfirmedAt { sqlite3_bind_double(statement, 9, date.timeIntervalSince1970) }
                        else { sqlite3_bind_null(statement, 9) }
                        sqlite3_bind_int64(statement, 10, memory.isUserConfirmed ? 1 : 0)
                    }
                }
            case .pendingConfirmation, .journalEntry, .monthlyLetter, .monthlyLetterDraft, .quickCaptureMetadata, .unknown:
                // These records are read directly from the canonical operation projection.
                ok = true
            }
            guard ok else { return false }
        }

        let confirmations = StateOperationResolver.resolve(allStateOperations()).currentByField.values
            .filter { $0.operationType == "memory.confirmation.set" && $0.fieldKey == "confirmation" }
        for operation in confirmations {
            guard let decision = try? JSONDecoder().decode(RiverMemoryConfirmation.self, from: operation.payload),
                  operation.targetID == "memory:\(decision.memoryID.uuidString.lowercased())" else {
                lastError = "共享记忆决定无法解码：\(operation.id.uuidString)"
                return false
            }
            let updatedAt = decision.updatedAt
            let ok = transaction { [self] in
                mutate("INSERT OR REPLACE INTO memory_confirmations(memory_id, confirmed_at, is_confirmed, note) VALUES (?, ?, ?, ?)") { statement in
                    bindText(statement, 1, decision.memoryID.uuidString)
                    sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 3, decision.confirmed ? 1 : 0)
                    bindText(statement, 4, decision.note)
                } && mutate("UPDATE memories SET is_user_confirmed = ?, last_confirmed_at = ? WHERE id = ?") { statement in
                    sqlite3_bind_int64(statement, 1, decision.confirmed ? 1 : 0)
                    sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
                    bindText(statement, 3, decision.memoryID.uuidString)
                }
            }
            guard ok else { return false }
        }
        return true
    }

    @discardableResult
    func retireDevice(_ deviceID: RiverDeviceID) -> Bool {
        guard let localID = localDeviceIdentifier(), localID != deviceID,
              let current = (try? allDeviceRegistrations())?.first(where: { $0.id == deviceID }) else {
            lastError = "无法退役本机或未登记的设备"
            return false
        }
        guard let payload = encodeData(DeviceLifecyclePayload(
            displayName: current.displayName,
            platform: current.platform,
            lifecycle: .retired
        )) else { return false }
        guard appendStateOperation(
            targetID: "device:\(deviceID.rawValue)",
            fieldKey: "lifecycle",
            operationType: "device.lifecycle.set",
            payload: payload
        ) != nil else { return false }
        do {
            try reconcileDeviceRegistryFromOperations()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func canonicalStateDigest() throws -> String {
        let events = allRawEvents().compactMap { $0.replica() }
        let operations = allStateOperations()
        let artifacts = canonicalArtifactRevisions().map(\.canonicalDigestEntry)
        let registrations = try allDeviceRegistrations()
        var frontiers: [String: UInt64] = [:]
        for registration in registrations {
            let isLocal = registration.id == localDeviceIdentifier()
            frontiers["\(registration.id.rawValue):events"] = isLocal
                ? ownedEventFrontier()
                : importedEventFrontier(for: registration.id)
            frontiers["\(registration.id.rawValue):operations"] = isLocal
                ? UInt64(syncValue("owned.operation.sequence.\(registration.id.rawValue)") ?? "0") ?? 0
                : importedOperationFrontier(for: registration.id)
        }
        return CanonicalStateDigest.make(
            events: events,
            stateOperations: operations,
            canonicalArtifactDigests: artifacts,
            deviceFrontiers: frontiers
        )
    }

    func nextManifestStamp(
        after previousRevision: UInt64 = 0,
        observing remoteClock: HybridLogicalClock? = nil
    ) throws -> (revision: UInt64, clock: HybridLogicalClock) {
        guard let deviceID = localDeviceIdentifier() else { throw RiverSyncCoordinatorError.deviceIdentityUnavailable }
        let revisionKey = "owned.manifest.revision.\(deviceID.rawValue)"
        let physicalKey = "hlc.physical.\(deviceID.rawValue)"
        let logicalKey = "hlc.logical.\(deviceID.rawValue)"
        let currentRevision = max(UInt64(syncValue(revisionKey) ?? "0") ?? 0, previousRevision)
        guard currentRevision < UInt64(Int64.max) else {
            throw RiverSyncStoreError.persistence("Manifest 版本超出支持范围")
        }
        let currentPhysical = UInt64(syncValue(physicalKey) ?? "0") ?? 0
        let currentLogical = UInt32(syncValue(logicalKey) ?? "0") ?? 0
        var clock = HybridLogicalClock(physicalMilliseconds: currentPhysical, logicalCounter: currentLogical, deviceID: deviceID)
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        if let remoteClock { clock.observe(remoteClock, wallTimeMilliseconds: now) }
        clock.tick(wallTimeMilliseconds: now)
        let ok = transaction { [self] in
            saveSyncValue(String(currentRevision + 1), for: revisionKey)
                && saveSyncValue(String(clock.physicalMilliseconds), for: physicalKey)
                && saveSyncValue(String(clock.logicalCounter), for: logicalKey)
        }
        guard ok else { throw RiverSyncStoreError.persistence(lastError ?? "保存 Manifest 逻辑时钟失败") }
        return (currentRevision + 1, clock)
    }

    func lastPublishedManifestKey(for directoryID: String) throws -> String? {
        syncValue("manifest.key.\(directoryID)")
    }

    func savePublishedManifestKey(_ key: String, for directoryID: String) throws {
        guard saveSyncValue(key, for: "manifest.key.\(directoryID)") else {
            throw RiverSyncStoreError.persistence(lastError ?? "保存 Manifest 摘要失败")
        }
    }

    func recordVerification(isVerified: Bool, digest: String) throws {
        let ok = transaction { [self] in
            saveSyncValue(isVerified ? "1" : "0", for: "sync.verification.ok")
                && saveSyncValue(isVerified ? digest : "", for: "sync.verification.digest")
                && saveSyncValue(isVerified ? String(Date().timeIntervalSince1970) : "", for: "sync.verification.time")
        }
        guard ok else { throw RiverSyncStoreError.persistence(lastError ?? "保存收敛核对状态失败") }
    }

    func isCurrentStateVerified() -> Bool {
        guard let registrations = try? allDeviceRegistrations() else { return false }
        let activeCount = registrations.filter { $0.lifecycle == .active }.count
        if activeCount <= 1 { return true }
        guard syncValue("sync.verification.ok") == "1",
              let recorded = syncValue("sync.verification.digest") else { return false }
        return recorded == (try? canonicalStateDigest())
    }

    private func syncStringIDs(table: String, column: String, where filter: String = "1 = 1") throws -> [String] {
        guard let db else { return [] }
        let sql = "SELECT \(column) FROM \(table) WHERE \(filter) ORDER BY \(column)"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RiverSyncStoreError.persistence(Self.errorMessage(db, fallback: "读取同步对象摘要失败"))
        }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = text(statement, 0) { result.append(value) }
        }
        return result
    }

    private func syncSequences(table: String, ownerColumn: String, owner: String) throws -> [UInt64] {
        guard let db else { return [] }
        let sql = "SELECT origin_sequence FROM \(table) WHERE \(ownerColumn) = ? ORDER BY origin_sequence"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RiverSyncStoreError.persistence(Self.errorMessage(db, fallback: "读取同步序号失败"))
        }
        bindText(statement, 1, owner)
        var result: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(UInt64(max(0, sqlite3_column_int64(statement, 0))))
        }
        return result
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
