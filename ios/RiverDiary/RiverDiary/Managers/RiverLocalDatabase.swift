import Foundation
import RiverDiaryCore
import SQLite3
import SwiftUI
import CryptoKit

extension Notification.Name {
    static let riverLocalNodeStateDidChange = Notification.Name("river.localNodeStateDidChange")
}

enum RiverLocalDatabaseError: LocalizedError {
    case open(String)
    case sql(String)
    case missingIdentity(String)
    case immutableEventConflict(String)

    var errorDescription: String? {
        switch self {
        case .open(let detail): "River Diary 本地数据库无法打开：\(detail)"
        case .sql(let detail): "River Diary 本地数据库操作失败：\(detail)"
        case .missingIdentity(let detail): "设备身份无法安全保存到钥匙串：\(detail)"
        case .immutableEventConflict(let id): "同一事件 ID 对应了不同内容：\(id)"
        }
    }
}

struct RiverTimelineEvent: Identifiable, Hashable {
    let event: RiverEvent
    let payload: RiverEventPayload

    var id: UUID { event.id }
}

@MainActor
final class RiverLocalDatabase: ObservableObject {
    private static let supportedSchemaVersion: Int32 = 4
    @Published private(set) var timelineEvents: [RiverTimelineEvent] = []
    @Published private(set) var timelineSessions: [RiverAppSession] = []
    @Published private(set) var places: [RiverPlace] = []
    @Published private(set) var sharedUserRecords: [RiverSharedStateRecord] = []
    @Published private(set) var dataRevision: UInt64 = 0
    @Published private(set) var deviceID: RiverDeviceID
    @Published private(set) var lastError: String?

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) throws {
        do {
            deviceID = try RiverSecureStore.loadOrCreateDeviceID(kind: "iphone")
        } catch {
            throw RiverLocalDatabaseError.missingIdentity(error.localizedDescription)
        }
        let url = try databaseURL ?? Self.defaultDatabaseURL()
        try Self.protectDirectory(url.deletingLastPathComponent())
        let status = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite returned \(status)"
            sqlite3_close(db)
            self.db = nil
            throw RiverLocalDatabaseError.open(detail)
        }
        sqlite3_busy_timeout(db, 5_000)
        try Self.createSchema(on: db)
        Self.protectFile(url)
        try registerLocalDevice()
        try rebuildSharedUserRecords()
        refreshTimeline()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static func defaultDatabaseURL() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw RiverLocalDatabaseError.open("Application Support 目录不可用")
        }
        return base.appendingPathComponent("RiverDiary", isDirectory: true)
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("river-node.sqlite")
    }

    private static func protectDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func protectFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func createSchema(on db: OpaquePointer) throws {
        let version = try schemaVersion(on: db)
        guard version <= supportedSchemaVersion else {
            throw RiverLocalDatabaseError.sql("本地数据库由更新版本创建；请先升级 River Diary。")
        }
        let statements = [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=FULL",
            "PRAGMA secure_delete=ON",
            """
            CREATE TABLE IF NOT EXISTS raw_events (
                id TEXT PRIMARY KEY,
                origin_device_id TEXT NOT NULL,
                origin_sequence INTEGER NOT NULL,
                timestamp REAL NOT NULL,
                recorded_at REAL NOT NULL,
                observed_timezone TEXT,
                source TEXT NOT NULL,
                kind TEXT NOT NULL,
                source_hash TEXT NOT NULL DEFAULT '',
                payload_json TEXT NOT NULL DEFAULT '{}',
                UNIQUE(origin_device_id, origin_sequence)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_river_events_time ON raw_events(timestamp, origin_device_id, origin_sequence)",
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
            "CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, display_name TEXT NOT NULL, platform TEXT NOT NULL, lifecycle TEXT NOT NULL, logical_millis INTEGER NOT NULL DEFAULT 0, logical_counter INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS sync_imports (object_id TEXT PRIMARY KEY, source_device_id TEXT NOT NULL, object_type TEXT NOT NULL, ciphertext_hash TEXT NOT NULL, imported_at REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS sync_exports (object_id TEXT PRIMARY KEY, source_device_id TEXT NOT NULL, object_type TEXT NOT NULL, ciphertext_hash TEXT NOT NULL, exported_at REAL NOT NULL)",
            "CREATE TABLE IF NOT EXISTS sync_state (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '')",
            "CREATE TABLE IF NOT EXISTS artifact_dependencies (artifact_id TEXT NOT NULL, dependency_type TEXT NOT NULL, dependency_id TEXT NOT NULL, range_start REAL, range_end REAL, PRIMARY KEY(artifact_id, dependency_type, dependency_id))",
            "CREATE TABLE IF NOT EXISTS analysis_jobs (job_id TEXT PRIMARY KEY, logical_key TEXT NOT NULL, artifact_type TEXT NOT NULL, input_frontier_json TEXT NOT NULL, priority INTEGER NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, started_at REAL, finished_at REAL, attempt INTEGER NOT NULL, origin_device_id TEXT NOT NULL, pipeline_version TEXT NOT NULL, prompt_version TEXT NOT NULL, last_error TEXT, payload_json TEXT NOT NULL)",
            "CREATE INDEX IF NOT EXISTS idx_analysis_jobs_queue ON analysis_jobs(status, priority DESC, created_at)",
            "CREATE TABLE IF NOT EXISTS shared_user_records (record_id TEXT PRIMARY KEY, record_kind TEXT NOT NULL, status TEXT NOT NULL, logical_key TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL, batch_id TEXT, shown_at REAL)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_river_event_idempotency ON raw_events(id)",
            "CREATE INDEX IF NOT EXISTS idx_river_place_candidate_recent ON raw_events(kind, recorded_at)",
            "CREATE INDEX IF NOT EXISTS idx_river_operation_target ON state_operations(target_id, field_key, logical_millis, logical_counter)",
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_river_operation_origin_sequence ON state_operations(actor_device_id, origin_sequence)",
            "CREATE INDEX IF NOT EXISTS idx_river_artifact_key ON artifacts(logical_key, artifact_type, revision_number)",
            "PRAGMA user_version = 4"
        ]
        for sql in statements {
            var error: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
                let detail = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(error)
                throw RiverLocalDatabaseError.sql(detail)
            }
        }
    }

    private static func schemaVersion(on db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw RiverLocalDatabaseError.sql("无法读取本地数据库版本。")
        }
        return sqlite3_column_int(statement, 0)
    }

    @discardableResult
    func append(id: UUID = UUID(), source: String, kind: String, payload: RiverEventPayload,
                observedAt: Date = Date(), sourceHash: String = "") throws -> RiverEvent {
        let payloadData = try encode(payload)
        var inserted = false
        let event = try transaction { [self] in
            if let existing = try lookupEvent(id: id) {
                guard existing.source == source, existing.kind == kind,
                      existing.payload == payloadData, existing.sourceHash == sourceHash else {
                    throw RiverLocalDatabaseError.immutableEventConflict(id.uuidString)
                }
                return existing
            }
            let counterKey = "owned.event.sequence.\(deviceID.rawValue)"
            let current = UInt64(try stateValue(counterKey) ?? "0") ?? 0
            guard current < UInt64(Int64.max) else { throw RiverLocalDatabaseError.sql("事件序号已超出支持范围") }
            let sequence = current + 1
            let next = RiverEvent(
                id: id,
                originDeviceID: deviceID,
                originSequence: sequence,
                observedAt: observedAt,
                source: source,
                kind: kind,
                sourceHash: sourceHash,
                payload: payloadData
            )
            try insert(next)
            try setStateValue(String(sequence), for: counterKey)
            inserted = true
            return next
        }
        _ = try invalidateArtifacts(covering: event)
        refreshTimeline()
        if inserted { NotificationCenter.default.post(name: .riverLocalNodeStateDidChange, object: deviceID.rawValue) }
        return event
    }

    func eventBatches(maximumEvents: Int = 128) throws -> [RiverEventBatch] {
        guard maximumEvents > 0 else { return [] }
        let local = try allEvents().filter { $0.originDeviceID == deviceID }.sorted { $0.originSequence < $1.originSequence }
        var result: [RiverEventBatch] = []
        var batch: [RiverEvent] = []
        for event in local {
            if let last = batch.last, event.originSequence != last.originSequence + 1 {
                result.append(try RiverEventBatch(deviceID: deviceID, events: batch))
                batch.removeAll(keepingCapacity: true)
            }
            batch.append(event)
            if batch.count == maximumEvents {
                result.append(try RiverEventBatch(deviceID: deviceID, events: batch))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { result.append(try RiverEventBatch(deviceID: deviceID, events: batch)) }
        return result
    }

    @discardableResult
    func importBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        let imported = try transaction { [self] in
            if try hasImportedObject(objectID) { return true }
            for event in batch.events {
                guard event.originDeviceID == batch.deviceID, event.originSequence > 0 else {
                    throw RiverLocalDatabaseError.sql("事件批次中的设备 ID 或序号无效")
                }
                if let existing = try lookupEvent(id: event.id) {
                    guard existing == event else { throw RiverLocalDatabaseError.immutableEventConflict(event.id.uuidString) }
                    continue
                }
                try insert(event)
            }
            let prefix = try contiguousEventPrefix(for: batch.deviceID)
            try setStateValue(String(prefix), for: "imported.event.prefix.\(batch.deviceID.rawValue)")
            try recordImport(objectID, deviceID: batch.deviceID, kind: "events", hash: ciphertextHash)
            return true
        }
        if imported {
            for event in batch.events { _ = try invalidateArtifacts(covering: event) }
        }
        return imported
    }

    func importedEventFrontier(for id: RiverDeviceID) throws -> UInt64 {
        UInt64(try stateValue("imported.event.prefix.\(id.rawValue)") ?? "0") ?? 0
    }

    func ownedEventFrontier() throws -> UInt64 {
        UInt64(try stateValue("owned.event.sequence.\(deviceID.rawValue)") ?? "0") ?? 0
    }

    func currentInputFrontier() throws -> InputFrontier {
        var events: [String: UInt64] = [:]
        var operations: [String: UInt64] = [:]
        for registration in try allDeviceRegistrations() where registration.lifecycle == .active {
            let id = registration.id
            events[id.rawValue] = id == deviceID
                ? try ownedEventFrontier()
                : try importedEventFrontier(for: id)
            operations[id.rawValue] = id == deviceID
                ? UInt64(try stateValue("owned.operation.sequence.\(id.rawValue)") ?? "0") ?? 0
                : UInt64(try stateValue("imported.operation.prefix.\(id.rawValue)") ?? "0") ?? 0
        }
        return try InputFrontier(sequences: events, operationSequences: operations)
    }

    func appendStateOperation(id: UUID = UUID(), targetID: String, fieldKey: String, operationType: String, payload: Data) throws -> StateOperation {
        var inserted = false
        let operation = try transaction {
            if let existing = try lookupOperation(id: id) {
                guard existing.targetID == targetID, existing.fieldKey == fieldKey,
                      existing.operationType == operationType, existing.payload == payload,
                      existing.actorDeviceID == deviceID else {
                    throw RiverLocalDatabaseError.immutableEventConflict(id.uuidString)
                }
                return existing
            }
            let sequenceKey = "owned.operation.sequence.\(deviceID.rawValue)"
            let current = UInt64(try stateValue(sequenceKey) ?? "0") ?? 0
            guard current < UInt64(Int64.max) else { throw RiverLocalDatabaseError.sql("用户状态操作序号超出支持范围") }
            var clock = HybridLogicalClock(
                physicalMilliseconds: UInt64(try stateValue("hlc.physical.\(deviceID.rawValue)") ?? "0") ?? 0,
                logicalCounter: UInt32(try stateValue("hlc.logical.\(deviceID.rawValue)") ?? "0") ?? 0,
                deviceID: deviceID
            )
            clock.tick(wallTimeMilliseconds: UInt64(max(0, Date().timeIntervalSince1970 * 1_000)))
            let frontierValues = try operationFrontiers(localSequence: current)
            let operation = StateOperation(
                id: id,
                actorDeviceID: deviceID,
                originSequence: current + 1,
                clock: clock,
                causalFrontier: try InputFrontier(operationSequences: frontierValues),
                targetID: targetID,
                fieldKey: fieldKey,
                operationType: operationType,
                payload: payload
            )
            try insert(operation)
            try setStateValue(String(operation.originSequence), for: sequenceKey)
            try setStateValue(String(clock.physicalMilliseconds), for: "hlc.physical.\(deviceID.rawValue)")
            try setStateValue(String(clock.logicalCounter), for: "hlc.logical.\(deviceID.rawValue)")
            inserted = true
            return operation
        }
        if inserted {
            if RiverStateOperationFreshness.changesAnalyticalState(operation) {
                _ = try invalidateArtifacts(covering: operation)
            }
            NotificationCenter.default.post(name: .riverLocalNodeStateDidChange, object: deviceID.rawValue)
        }
        return operation
    }

    func allStateOperations() throws -> [StateOperation] {
        let sql = "SELECT operation_id, actor_device_id, origin_sequence, logical_millis, logical_counter, target_id, field_key, operation_type, payload, causal_frontier_json FROM state_operations ORDER BY actor_device_id, origin_sequence"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        var result: [StateOperation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: string(statement, 0) ?? ""),
                  let actorText = string(statement, 1),
                  let target = string(statement, 5),
                  let field = string(statement, 6),
                  let operationType = string(statement, 7),
                  let payload = data(statement, 8),
                  let frontierData = string(statement, 9)?.data(using: .utf8),
                  let frontier = try? decoder.decode(InputFrontier.self, from: frontierData) else { continue }
            let actor = RiverDeviceID(rawValue: actorText)
            result.append(StateOperation(
                id: id,
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
                operationType: operationType,
                payload: payload
            ))
        }
        return result
    }

    func stateOperationBatches(maximumOperations: Int = 128) throws -> [StateOperationBatch] {
        guard maximumOperations > 0 else { return [] }
        let operations = try allStateOperations().filter { $0.actorDeviceID == deviceID }
        var groups: [StateOperationBatch] = []
        var batch: [StateOperation] = []
        for operation in operations {
            if let last = batch.last,
               last.originSequence == UInt64.max || operation.originSequence != last.originSequence + 1 {
                groups.append(try StateOperationBatch(deviceID: deviceID, operations: batch))
                batch.removeAll(keepingCapacity: true)
            }
            batch.append(operation)
            if batch.count == maximumOperations {
                groups.append(try StateOperationBatch(deviceID: deviceID, operations: batch))
                batch.removeAll(keepingCapacity: true)
            }
        }
        if !batch.isEmpty { groups.append(try StateOperationBatch(deviceID: deviceID, operations: batch)) }
        return groups
    }

    func importStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        try transaction {
            if try hasImportedObject(objectID) { return true }
            for operation in batch.operations {
                guard operation.actorDeviceID == batch.deviceID, operation.originSequence > 0,
                      operation.originSequence <= UInt64(Int64.max) else {
                    throw RiverLocalDatabaseError.sql("状态操作批次的来源设备或序号无效")
                }
                if let existing = try lookupOperation(id: operation.id) {
                    guard existing == operation else { throw RiverLocalDatabaseError.immutableEventConflict(operation.id.uuidString) }
                    continue
                }
                try insert(operation)
            }
            let prefix = try contiguousOperationPrefix(for: batch.deviceID)
            try setStateValue(String(prefix), for: "imported.operation.prefix.\(batch.deviceID.rawValue)")
            try recordImport(objectID, deviceID: batch.deviceID, kind: "state_operations", hash: ciphertextHash)
            return true
        }
    }

    func insertArtifactRevision(_ revision: RiverArtifactRevision) throws {
        guard try persistArtifactRevision(revision, importedObjectID: nil, ciphertextHash: nil) else {
            throw RiverLocalDatabaseError.sql("无法保存 Artifact 修订。")
        }
    }

    func importArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        guard Self.sha256(revision.content) == revision.contentHash else {
            throw RiverLocalDatabaseError.sql("Artifact 内容摘要不匹配：\(revision.id)")
        }
        return try persistArtifactRevision(revision, importedObjectID: objectID, ciphertextHash: ciphertextHash)
    }

    func restoreOwnedEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == deviceID else { return false }
        guard try importBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash) else { return false }
        let prefix = try contiguousEventPrefix(for: deviceID)
        try setStateValue(String(prefix), for: "owned.event.sequence.\(deviceID.rawValue)")
        for event in batch.events { _ = try invalidateArtifacts(covering: event) }
        return true
    }

    func restoreOwnedStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == deviceID else { return false }
        guard try importStateOperationBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash) else { return false }
        let prefix = try contiguousOperationPrefix(for: deviceID)
        try setStateValue(String(prefix), for: "owned.operation.sequence.\(deviceID.rawValue)")
        if let latest = batch.operations.max(by: { $0.clock < $1.clock }) {
            let physicalKey = "hlc.physical.\(deviceID.rawValue)"
            let logicalKey = "hlc.logical.\(deviceID.rawValue)"
            let currentPhysical = UInt64(try stateValue(physicalKey) ?? "0") ?? 0
            let currentLogical = UInt32(try stateValue(logicalKey) ?? "0") ?? 0
            let physical = max(currentPhysical, latest.clock.physicalMilliseconds)
            let logical = physical == latest.clock.physicalMilliseconds
                ? max(currentLogical, latest.clock.logicalCounter)
                : currentLogical
            try setStateValue(String(physical), for: physicalKey)
            try setStateValue(String(logical), for: logicalKey)
        }
        return true
    }

    func restoreOwnedArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        guard revision.originDeviceID == deviceID else { return false }
        return try importArtifactRevision(revision, objectID: objectID, ciphertextHash: ciphertextHash)
    }

    func localArtifactRevisions() throws -> [RiverArtifactRevision] {
        try queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE origin_device_id = ? ORDER BY logical_millis, logical_counter, artifact_id",
            binds: { statement in bind(deviceID.rawValue, to: statement, at: 1) }
        )
    }

    func canonicalArtifactRevisions() throws -> [RiverArtifactRevision] {
        try applyingArtifactInvalidations(to: queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE is_canonical = 1 ORDER BY logical_key, artifact_type"
        ) { _ in })
    }

    func analysisJobs() throws -> [RiverAnalysisJob] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = "SELECT payload_json FROM analysis_jobs ORDER BY priority DESC, created_at, job_id"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        var jobs: [RiverAnalysisJob] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let json = string(statement, 0), let data = json.data(using: .utf8),
                  let job = try? decoder.decode(RiverAnalysisJob.self, from: data) else { continue }
            jobs.append(job)
        }
        return jobs
    }

    func latestAnalysisJob() throws -> RiverAnalysisJob? {
        try analysisJobs().max { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func saveAnalysisJob(_ job: RiverAnalysisJob) throws -> Bool {
        let payload = try encode(job)
        let payloadJSON = String(data: payload, encoding: .utf8) ?? "{}"
        let frontierJSON = String(data: try encode(job.inputFrontier), encoding: .utf8) ?? "{}"
        return try transaction {
            let sql = """
            INSERT INTO analysis_jobs(job_id, logical_key, artifact_type, input_frontier_json, priority, status, created_at, started_at, finished_at, attempt, origin_device_id, pipeline_version, prompt_version, last_error, payload_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(job_id) DO UPDATE SET status=excluded.status, started_at=excluded.started_at, finished_at=excluded.finished_at, attempt=excluded.attempt, last_error=excluded.last_error, payload_json=excluded.payload_json
            """
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
            bind(job.id.uuidString.lowercased(), to: statement, at: 1)
            bind(job.logicalKey, to: statement, at: 2)
            bind(job.artifactType.rawValue, to: statement, at: 3)
            bind(frontierJSON, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, Int64(job.priority))
            bind(job.status.rawValue, to: statement, at: 6)
            sqlite3_bind_double(statement, 7, job.createdAt.timeIntervalSince1970)
            if let date = job.startedAt { sqlite3_bind_double(statement, 8, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 8) }
            if let date = job.finishedAt { sqlite3_bind_double(statement, 9, date.timeIntervalSince1970) } else { sqlite3_bind_null(statement, 9) }
            sqlite3_bind_int64(statement, 10, Int64(job.attempt))
            bind(job.originDeviceID.rawValue, to: statement, at: 11)
            bind(job.pipelineVersion, to: statement, at: 12)
            bind(job.promptVersion, to: statement, at: 13)
            bind(job.lastError, to: statement, at: 14)
            bind(payloadJSON, to: statement, at: 15)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
            return true
        }
    }

    func artifactRevisions(logicalKey: String, kind: RiverArtifactKind) throws -> [RiverArtifactRevision] {
        try queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE logical_key = ? AND artifact_type = ? ORDER BY revision_number, artifact_id"
        ) { statement in
            bind(logicalKey, to: statement, at: 1)
            bind(kind.rawValue, to: statement, at: 2)
        }
    }

    func nextArtifactRevisionNumber(logicalKey: String, kind: RiverArtifactKind) throws -> UInt64 {
        (try artifactRevisions(logicalKey: logicalKey, kind: kind).map(\.revisionNumber).max() ?? 0) + 1
    }

    func allEvents() throws -> [RiverEvent] {
        let sql = "SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone, source, kind, source_hash, payload_json FROM raw_events ORDER BY timestamp, origin_device_id, origin_sequence"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        var values: [RiverEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(try decodeEvent(statement))
        }
        return values
    }

    func makeLocalBackup() throws -> RiverNodeBackup {
        RiverNodeBackup(
            sourceDeviceID: deviceID,
            events: try allEvents(),
            stateOperations: try allStateOperations(),
            artifactRevisions: try allArtifactRevisions(),
            deviceRegistrations: try allDeviceRegistrations()
        )
    }

    /// Merge a backup into the current node. It never clears existing local
    /// state, and each immutable stream batch can be safely retried after an
    /// interrupted restore.
    func restoreLocalBackup(_ backup: RiverNodeBackup) throws {
        guard backup.format == "river-node-backup",
              backup.protocolVersion <= 1,
              backup.schemaVersion <= Self.supportedSchemaVersion else {
            throw RiverLocalDatabaseError.sql("备份格式或版本高于当前应用支持范围。")
        }
        guard Set(backup.events.map(\.id)).count == backup.events.count,
              Set(backup.stateOperations.map(\.id)).count == backup.stateOperations.count,
              Set(backup.artifactRevisions.map(\.id)).count == backup.artifactRevisions.count else {
            throw RiverLocalDatabaseError.sql("备份中有重复的不可变对象 ID。")
        }

        for batch in try backupEventBatches(backup.events) {
            let objectID = "backup-\(backup.sourceDeviceID.rawValue)-\(batch.id)"
            _ = try importBatch(batch, objectID: objectID, ciphertextHash: Self.sha256(try encode(batch)))
        }
        for batch in try backupOperationBatches(backup.stateOperations) {
            let objectID = "backup-\(backup.sourceDeviceID.rawValue)-\(batch.id)"
            _ = try importStateOperationBatch(batch, objectID: objectID, ciphertextHash: Self.sha256(try encode(batch)))
        }
        for revision in backup.artifactRevisions {
            try insertArtifactRevision(revision)
        }
        try mergeDeviceRegistrations(backup.deviceRegistrations)
        try reconcileDeviceRegistryFromOperations()

        let ownedEvents = try sequences(table: "raw_events", column: "origin_sequence", ownerColumn: "origin_device_id", owner: deviceID.rawValue)
        let ownedOperations = try sequences(table: "state_operations", column: "origin_sequence", ownerColumn: "actor_device_id", owner: deviceID.rawValue)
        try setStateValue(String(SequenceScan(sequences: ownedEvents).contiguousThrough), for: "owned.event.sequence.\(deviceID.rawValue)")
        try setStateValue(String(SequenceScan(sequences: ownedOperations).contiguousThrough), for: "owned.operation.sequence.\(deviceID.rawValue)")
        if let latestOwnOperation = try allStateOperations()
            .filter({ $0.actorDeviceID == deviceID })
            .max(by: { $0.clock < $1.clock }) {
            let physicalKey = "hlc.physical.\(deviceID.rawValue)"
            let logicalKey = "hlc.logical.\(deviceID.rawValue)"
            let currentPhysical = UInt64(try stateValue(physicalKey) ?? "0") ?? 0
            let currentLogical = UInt32(try stateValue(logicalKey) ?? "0") ?? 0
            if latestOwnOperation.clock.physicalMilliseconds > currentPhysical
                || (latestOwnOperation.clock.physicalMilliseconds == currentPhysical
                    && latestOwnOperation.clock.logicalCounter > currentLogical) {
                try setStateValue(String(latestOwnOperation.clock.physicalMilliseconds), for: physicalKey)
                try setStateValue(String(latestOwnOperation.clock.logicalCounter), for: logicalKey)
            }
        }
        try rebuildDerivedState()
        refreshTimeline()
    }

    private func backupEventBatches(_ events: [RiverEvent], maximumBatchSize: Int = 128) throws -> [RiverEventBatch] {
        var result: [RiverEventBatch] = []
        let groups = Dictionary(grouping: events, by: \.originDeviceID)
        for (device, deviceEvents) in groups {
            var current: [RiverEvent] = []
            for event in deviceEvents.sorted(by: { $0.originSequence < $1.originSequence }) {
                if let last = current.last, last.originSequence == UInt64.max || event.originSequence != last.originSequence + 1 {
                    result.append(try RiverEventBatch(deviceID: device, events: current))
                    current.removeAll(keepingCapacity: true)
                }
                current.append(event)
                if current.count == maximumBatchSize {
                    result.append(try RiverEventBatch(deviceID: device, events: current))
                    current.removeAll(keepingCapacity: true)
                }
            }
            if !current.isEmpty { result.append(try RiverEventBatch(deviceID: device, events: current)) }
        }
        return result.sorted { $0.id < $1.id }
    }

    private func backupOperationBatches(_ operations: [StateOperation], maximumBatchSize: Int = 128) throws -> [StateOperationBatch] {
        var result: [StateOperationBatch] = []
        let groups = Dictionary(grouping: operations, by: \.actorDeviceID)
        for (device, deviceOperations) in groups {
            var current: [StateOperation] = []
            for operation in deviceOperations.sorted(by: { $0.originSequence < $1.originSequence }) {
                if let last = current.last, last.originSequence == UInt64.max || operation.originSequence != last.originSequence + 1 {
                    result.append(try StateOperationBatch(deviceID: device, operations: current))
                    current.removeAll(keepingCapacity: true)
                }
                current.append(operation)
                if current.count == maximumBatchSize {
                    result.append(try StateOperationBatch(deviceID: device, operations: current))
                    current.removeAll(keepingCapacity: true)
                }
            }
            if !current.isEmpty { result.append(try StateOperationBatch(deviceID: device, operations: current)) }
        }
        return result.sorted { $0.id < $1.id }
    }

    func events(from start: Date, to end: Date) throws -> [RiverEvent] {
        let sql = "SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone, source, kind, source_hash, payload_json FROM raw_events WHERE timestamp >= ? AND timestamp < ? ORDER BY timestamp, origin_device_id, origin_sequence"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)
        var values: [RiverEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(try decodeEvent(statement)) }
        let deleted = try deletedEventIDs()
        return values.filter { !deleted.contains("event:\($0.id.uuidString)") }
    }

    func hasRecentPlaceCandidate(near latitude: Double, longitude: Double, since cutoff: Date, withinMeters radius: Double = 250) -> Bool {
        guard latitude.isFinite, longitude.isFinite else { return false }
        let sql = "SELECT payload_json FROM raw_events WHERE kind = ? AND recorded_at >= ? ORDER BY recorded_at DESC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        bind("location.placeCandidate", to: statement, at: 1)
        sqlite3_bind_double(statement, 2, cutoff.timeIntervalSince1970)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0),
                  let data = String(cString: text).data(using: .utf8),
                  let payload = try? decoder.decode(RiverEventPayload.self, from: data),
                  let candidateLatitude = payload.latitude,
                  let candidateLongitude = payload.longitude else { continue }
            if Self.distanceMeters(latitude, longitude, candidateLatitude, candidateLongitude) <= radius {
                return true
            }
        }
        return false
    }

    private static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earth = 6_371_000.0
        let latitude1 = lat1 * .pi / 180
        let latitude2 = lat2 * .pi / 180
        let deltaLatitude = (lat2 - lat1) * .pi / 180
        let deltaLongitude = (lon2 - lon1) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return earth * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    func effectiveEvents() throws -> [RiverEvent] {
        let deleted = try deletedEventIDs()
        return try allEvents().filter { !deleted.contains("event:\($0.id.uuidString)") }
    }

    func allSessions() throws -> [RiverAppSession] {
        try SessionBuilder.build(effectiveEvents())
    }

    func importedReplicationObjectCount() throws -> Int {
        try scalarCount("SELECT COUNT(*) FROM sync_imports")
    }

    func staleArtifactCount() throws -> Int {
        try applyingArtifactInvalidations(to: allArtifactRevisions()).filter { $0.status == .stale }.count
    }

    func allArtifactRevisionCount() throws -> Int {
        try allArtifactRevisions().count
    }

    @discardableResult
    func invalidateGeneratedArtifactsForDiagnostics() throws -> Int {
        let current = try allArtifactRevisions().filter { $0.userState == .generated && $0.status != .stale }
        guard !current.isEmpty else { return 0 }
        _ = try markArtifactsStale(current, cause: "developer-diagnostics.manual")
        return current.count
    }

    private func scalarCount(_ sql: String) throws -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw databaseError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func deletedEventIDs() throws -> Set<String> {
        StateOperationResolver.tombstonedObjectIDs(try allStateOperations())
    }

    func sessions(from start: Date, to end: Date) throws -> [RiverAppSession] {
        try SessionBuilder.build(effectiveEvents()).filter { session in
            guard session.start < end else { return false }
            if let sessionEnd = session.end { return sessionEnd > start }
            return session.start >= start
        }
    }

    func rebuildDerivedState() throws {
        try reconcileLateArtifactEvents()
        try reconcileLateArtifactOperations()
        try rebuildPlaces()
        try rebuildCanonicalArtifactPointers()
        try rebuildSharedUserRecords()
    }

    func saveSharedUserRecord(_ record: RiverSharedStateRecord) throws {
        let payload = try encode(record)
        _ = try appendStateOperation(
            targetID: record.targetID,
            fieldKey: "record",
            operationType: "shared.record.upsert",
            payload: payload
        )
        try rebuildSharedUserRecords()
    }

    func memoryConfirmation(for id: UUID) -> RiverMemoryConfirmation? {
        let target = "memory:\(id.uuidString.lowercased())"
        guard let operation = StateOperationResolver.resolve((try? allStateOperations()) ?? [])
            .currentByField["\(target)\u{1f}confirmation"],
              operation.operationType == "memory.confirmation.set" else { return nil }
        return try? decoder.decode(RiverMemoryConfirmation.self, from: operation.payload)
    }

    func setSharedMemoryConfirmation(for record: RiverSharedStateRecord, confirmed: Bool, note: String = "") throws {
        guard record.kind == .memory else { throw RiverLocalDatabaseError.sql("目标不是记忆记录。") }
        let decision = RiverMemoryConfirmation(memoryID: record.id, confirmed: confirmed, note: note)
        _ = try appendStateOperation(
            targetID: "memory:\(record.id.uuidString.lowercased())",
            fieldKey: "confirmation",
            operationType: "memory.confirmation.set",
            payload: try encode(decision)
        )
    }

    func resolvePendingConfirmation(_ record: RiverSharedStateRecord,
                                    as resolution: RiverPendingConfirmationResolution,
                                    correction: String? = nil) throws {
        guard sharedUserRecords.first(where: { $0.id == record.id })?.status == "pending" else {
            throw RiverLocalDatabaseError.sql("这条待确认事项已在本机处理或已同步更新。")
        }
        guard let updated = record.resolving(resolution, correction: correction) else {
            throw RiverLocalDatabaseError.sql("这条待确认事项已处理，或内容格式不受支持。")
        }
        guard let content = record.pendingConfirmationContent else {
            throw RiverLocalDatabaseError.sql("待确认事项缺少有效内容。")
        }
        if content.targetType == "place", let placeID = content.targetID {
            let name: String
            let semanticType: String
            switch resolution {
            case .confirmed:
                guard let candidate = content.candidate, !candidate.isEmpty else {
                    throw RiverLocalDatabaseError.sql("地点候选名称为空，不能确认。")
                }
                name = candidate
                semanticType = places.first(where: { $0.id == placeID })?.poiCategory ?? "place"
            case .corrected:
                guard let value = correction?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw RiverLocalDatabaseError.sql("请填写地点名称后再保存。")
                }
                name = value
                semanticType = "userDefined"
            case .rejected, .dismissed:
                name = ""
                semanticType = ""
            }
            if resolution == .confirmed || resolution == .corrected {
                let decision = RiverPlaceUserDecision(name: name, semanticType: semanticType, isConfirmed: true)
                _ = try appendStateOperation(
                    targetID: placeID,
                    fieldKey: "identity",
                    operationType: "place.identity.set",
                    payload: try encoder.encode(decision)
                )
            }
        } else if content.targetType == "timelineCandidate", let annotationKey = content.targetID {
            let title: String
            let note: String
            switch resolution {
            case .confirmed:
                title = content.candidate ?? ""
                note = "用户确认了这条时间线观察。"
            case .corrected:
                guard let value = correction?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    throw RiverLocalDatabaseError.sql("请填写时间线说明后再保存。")
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
            let now = Date()
            let annotation = RiverTimelineAnnotation(
                title: title, note: note, isReviewed: true, reviewedAt: now, updatedAt: now
            )
            _ = try appendStateOperation(
                targetID: annotationKey, fieldKey: "annotation",
                operationType: "timeline.annotation.set", payload: try encoder.encode(annotation)
            )
        }
        try saveSharedUserRecord(updated)
        try rebuildPlaces()
        refreshTimeline()
    }

    func markPlaceConfirmationResolved(placeID: String, name: String) throws {
        guard let record = sharedUserRecords.first(where: {
            $0.kind == .pendingConfirmation && $0.status == "pending"
                && $0.pendingConfirmationContent?.targetType == "place"
                && $0.pendingConfirmationContent?.targetID == placeID
        }) else { return }
        let resolution: RiverPendingConfirmationResolution = record.pendingConfirmationContent?.candidate == name
            ? .confirmed : .corrected
        guard let updated = record.resolving(resolution, correction: resolution == .corrected ? name : nil) else { return }
        try saveSharedUserRecord(updated)
    }

    private func rebuildSharedUserRecords() throws {
        let operations = try allStateOperations()
        let tombstones = StateOperationResolver.tombstonedObjectIDs(operations)
        let records = StateOperationResolver.resolve(operations).currentByField.values.compactMap { operation -> RiverSharedStateRecord? in
            guard operation.operationType == "shared.record.upsert", operation.fieldKey == "record",
                  let record = try? decoder.decode(RiverSharedStateRecord.self, from: operation.payload),
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
        try transaction {
            try execute("DELETE FROM shared_user_records", bindings: [])
            for record in records {
                let sql = "INSERT INTO shared_user_records(record_id, record_kind, status, logical_key, payload_json, created_at, updated_at, batch_id, shown_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
                bind(record.id.uuidString.lowercased(), to: statement, at: 1)
                bind(record.kind.rawValue, to: statement, at: 2)
                bind(record.status, to: statement, at: 3)
                bind(record.logicalKey, to: statement, at: 4)
                bind(record.payloadJSON, to: statement, at: 5)
                sqlite3_bind_double(statement, 6, record.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(statement, 7, record.updatedAt.timeIntervalSince1970)
                bind(record.batchID?.uuidString.lowercased(), to: statement, at: 8)
                if let shownAt = record.shownAt { sqlite3_bind_double(statement, 9, shownAt.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 9) }
                let step = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard step == SQLITE_DONE else { throw databaseError() }
            }
        }
        sharedUserRecords = records
    }

    func rebuildPlaces() throws {
        let resolved = PlaceClusterEngine.build(events: try effectiveEvents(), userOperations: try allStateOperations())
        try transaction {
            try execute("DELETE FROM places", bindings: [])
            for place in resolved {
                let sql = "INSERT INTO places(place_id, latitude, longitude, radius_meters, map_name, map_address, poi_category, map_provider, map_result_identifier, user_defined_name, semantic_type, is_user_confirmed, confidence, first_seen, last_seen, visit_count, total_duration_seconds) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
                bind(place.id, to: statement, at: 1)
                sqlite3_bind_double(statement, 2, place.latitude)
                sqlite3_bind_double(statement, 3, place.longitude)
                sqlite3_bind_double(statement, 4, place.radiusMeters)
                bind(place.mapName, to: statement, at: 5)
                bind(place.mapAddress, to: statement, at: 6)
                bind(place.poiCategory, to: statement, at: 7)
                bind(place.mapProvider, to: statement, at: 8)
                bind(place.mapResultIdentifier, to: statement, at: 9)
                bind(place.userDefinedName, to: statement, at: 10)
                bind(place.semanticType, to: statement, at: 11)
                sqlite3_bind_int64(statement, 12, place.isUserConfirmed ? 1 : 0)
                sqlite3_bind_double(statement, 13, place.confidence)
                sqlite3_bind_double(statement, 14, place.firstSeen.timeIntervalSince1970)
                sqlite3_bind_double(statement, 15, place.lastSeen.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 16, Int64(place.visitCount))
                sqlite3_bind_double(statement, 17, place.totalDurationSeconds)
                let step = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard step == SQLITE_DONE else { throw databaseError() }
            }
        }
        places = resolved
        let existingConfirmationIDs = Set(sharedUserRecords
            .filter { $0.kind == .pendingConfirmation }
            .map(\.id))
        for place in resolved where !existingConfirmationIDs.contains(
            RiverStableIdentifier.uuid(namespace: "place-confirmation", key: place.id)
        ) {
            guard let record = RiverSharedStateRecord.placeCandidate(place) else { continue }
            try saveSharedUserRecord(record)
        }
    }

    func refreshTimeline(for date: Date = .now) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        do {
            timelineEvents = try events(from: start, to: end).compactMap { event in
                guard let payload = try? decoder.decode(RiverEventPayload.self, from: event.payload) else { return nil }
                return RiverTimelineEvent(event: event, payload: payload)
            }
            timelineSessions = try sessions(from: start, to: end)
            try rebuildPlaces()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        dataRevision &+= 1
    }

    private func allArtifactRevisions() throws -> [RiverArtifactRevision] {
        try queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts ORDER BY logical_key, artifact_type, artifact_id"
        ) { _ in }
    }

    private func applyingArtifactInvalidations(to revisions: [RiverArtifactRevision]) throws -> [RiverArtifactRevision] {
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        return revisions.map { revision in
            invalidated.contains(revision.id) && revision.userState == .generated
                ? revision.replacingStatus(.stale)
                : revision
        }
    }

    private func invalidateArtifacts(covering event: RiverEvent) throws -> Bool {
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        let candidates = try allArtifactRevisions().filter { revision in
            guard revision.userState == .generated,
                  !invalidated.contains(revision.id),
                  revision.inputFrontier.sequences[event.originDeviceID.rawValue, default: 0] < event.originSequence else { return false }
            return revision.dependencies.contains { dependency in
                guard let start = dependency.rangeStart, let end = dependency.rangeEnd else { return false }
                return start <= event.observedAt && event.observedAt < end
            }
        }
        return try markArtifactsStale(candidates, cause: "event:\(event.id.uuidString.lowercased())")
    }

    private func markArtifactsStale(_ revisions: [RiverArtifactRevision], cause: String) throws -> Bool {
        guard !revisions.isEmpty else { return true }
        let alreadyInvalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        for revision in revisions where !alreadyInvalidated.contains(revision.id) {
            let id = RiverStableIdentifier.uuid(
                namespace: "artifact-stale.\(deviceID.rawValue)",
                key: "\(revision.id)|\(cause)"
            )
            _ = try appendStateOperation(
                id: id,
                targetID: revision.id,
                fieldKey: "freshness",
                operationType: "artifact.stale",
                payload: Data(cause.utf8)
            )
        }
        try rebuildCanonicalArtifactPointers()
        return true
    }

    private func invalidateArtifacts(covering operation: StateOperation) throws -> Bool {
        guard RiverStateOperationFreshness.changesAnalyticalState(operation) else { return true }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        let candidates = try allArtifactRevisions().filter {
            $0.userState == .generated
                && !invalidated.contains($0.id)
                && $0.inputFrontier.operationSequences[operation.actorDeviceID.rawValue, default: 0] < operation.originSequence
        }
        return try markArtifactsStale(candidates, cause: "operation:\(operation.id.uuidString.lowercased())")
    }

    private func reconcileLateArtifactOperations() throws {
        let operations = try allStateOperations().filter {
            RiverStateOperationFreshness.changesAnalyticalState($0)
        }
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        for revision in try allArtifactRevisions()
        where revision.userState == .generated && !invalidated.contains(revision.id) {
            guard let operation = operations.first(where: {
                $0.originSequence > revision.inputFrontier.operationSequences[$0.actorDeviceID.rawValue, default: 0]
            }) else { continue }
            _ = try markArtifactsStale([revision], cause: "operation:\(operation.id.uuidString.lowercased())")
        }
    }

    private func reconcileLateArtifactEvents() throws {
        let invalidated = StateOperationResolver.invalidatedArtifactIDs(try allStateOperations())
        let events = try allEvents()
        for revision in try allArtifactRevisions()
        where revision.userState == .generated && !invalidated.contains(revision.id) {
            guard let lateEvent = events.first(where: { event in
                event.originSequence > revision.inputFrontier.sequences[event.originDeviceID.rawValue, default: 0]
                    && revision.dependencies.contains { dependency in
                        guard let start = dependency.rangeStart, let end = dependency.rangeEnd else { return false }
                        return start <= event.observedAt && event.observedAt < end
                    }
            }) else { continue }
            _ = try markArtifactsStale([revision], cause: "event:\(lateEvent.id.uuidString.lowercased())")
        }
    }

    private func rebuildCanonicalArtifactPointers() throws {
        let resolvedInputs = try applyingArtifactInvalidations(to: allArtifactRevisions())
        let groups = Dictionary(grouping: resolvedInputs) { "\($0.logicalKey)\u{1f}\($0.kind.rawValue)" }
        try transaction {
            try execute("UPDATE artifacts SET is_canonical = 0", bindings: [])
            for revisions in groups.values {
                let resolution = try ArtifactResolver.resolve(revisions)
                try execute("UPDATE artifacts SET is_canonical = 1 WHERE artifact_id = ?", bindings: [resolution.canonical.id])
            }
        }
    }

    private func registerLocalDevice() throws {
        let sql = "INSERT OR IGNORE INTO devices(device_id, display_name, platform, lifecycle, updated_at) VALUES (?, ?, 'iOS', 'active', ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(deviceID.rawValue, to: statement, at: 1)
        bind(UIDevice.current.name, to: statement, at: 2)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func insert(_ event: RiverEvent) throws {
        let payload = String(decoding: event.payload, as: UTF8.self)
        let sql = "INSERT OR IGNORE INTO raw_events(id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone, source, kind, source_hash, payload_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(event.id.uuidString, to: statement, at: 1)
        bind(event.originDeviceID.rawValue, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, Int64(event.originSequence))
        sqlite3_bind_double(statement, 4, event.observedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, event.recordedAt.timeIntervalSince1970)
        bind(event.observedTimeZoneIdentifier, to: statement, at: 6)
        bind(event.source, to: statement, at: 7)
        bind(event.kind, to: statement, at: 8)
        bind(event.sourceHash, to: statement, at: 9)
        bind(payload, to: statement, at: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
        guard sqlite3_changes(db) == 1 else { throw RiverLocalDatabaseError.immutableEventConflict(event.id.uuidString) }
    }

    private func insert(_ operation: StateOperation) throws {
        let frontier = String(decoding: try encode(operation.causalFrontier), as: UTF8.self)
        let sql = "INSERT OR IGNORE INTO state_operations(operation_id, actor_device_id, origin_sequence, logical_millis, logical_counter, target_id, field_key, operation_type, payload, causal_frontier_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(operation.id.uuidString, to: statement, at: 1)
        bind(operation.actorDeviceID.rawValue, to: statement, at: 2)
        sqlite3_bind_int64(statement, 3, Int64(operation.originSequence))
        sqlite3_bind_int64(statement, 4, Int64(operation.clock.physicalMilliseconds))
        sqlite3_bind_int64(statement, 5, Int64(operation.clock.logicalCounter))
        bind(operation.targetID, to: statement, at: 6)
        bind(operation.fieldKey, to: statement, at: 7)
        bind(operation.operationType, to: statement, at: 8)
        bind(operation.payload, to: statement, at: 9)
        bind(frontier, to: statement, at: 10)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else {
            throw RiverLocalDatabaseError.immutableEventConflict(operation.id.uuidString)
        }
    }

    private func lookupOperation(id: UUID) throws -> StateOperation? {
        try allStateOperations().first(where: { $0.id == id })
    }

    private func persistArtifactRevision(_ revision: RiverArtifactRevision, importedObjectID: String?, ciphertextHash: String?) throws -> Bool {
        guard Self.sha256(revision.content) == revision.contentHash else {
            throw RiverLocalDatabaseError.sql("Artifact 内容摘要不匹配：\(revision.id)")
        }
        return try transaction {
            if let existing = try artifactRevision(id: revision.id) {
                guard existing == revision else { throw RiverLocalDatabaseError.immutableEventConflict(revision.id) }
            } else {
                let sql = "INSERT INTO artifacts(artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, is_canonical, supersedes_revision_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
                bind(revision.id, to: statement, at: 1)
                bind(revision.logicalKey, to: statement, at: 2)
                bind(revision.kind.rawValue, to: statement, at: 3)
                sqlite3_bind_int64(statement, 4, Int64(revision.revisionNumber))
                bind(revision.originDeviceID.rawValue, to: statement, at: 5)
                sqlite3_bind_int64(statement, 6, Int64(revision.clock.physicalMilliseconds))
                sqlite3_bind_int64(statement, 7, Int64(revision.clock.logicalCounter))
                bind(String(decoding: try encode(revision.inputFrontier), as: UTF8.self), to: statement, at: 8)
                bind(revision.inputSnapshotHash, to: statement, at: 9)
                bind(revision.pipelineVersion, to: statement, at: 10)
                bind(revision.promptVersion, to: statement, at: 11)
                bind(revision.modelProvider, to: statement, at: 12)
                bind(revision.modelIdentifier, to: statement, at: 13)
                bind(revision.content, to: statement, at: 14)
                bind(revision.contentHash, to: statement, at: 15)
                bind(revision.status.rawValue, to: statement, at: 16)
                sqlite3_bind_int64(statement, 17, Int64(revision.userState.rawValue))
                bind(revision.supersedesRevisionID, to: statement, at: 18)
                sqlite3_bind_double(statement, 19, Double(revision.clock.physicalMilliseconds) / 1_000)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    sqlite3_finalize(statement)
                    throw databaseError()
                }
                sqlite3_finalize(statement)
            }

            for dependency in revision.dependencies {
                let sql = "INSERT OR IGNORE INTO artifact_dependencies(artifact_id, dependency_type, dependency_id, range_start, range_end) VALUES (?, ?, ?, ?, ?)"
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
                bind(revision.id, to: statement, at: 1)
                bind(dependency.type, to: statement, at: 2)
                bind(dependency.id, to: statement, at: 3)
                if let start = dependency.rangeStart { sqlite3_bind_double(statement, 4, start.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 4) }
                if let end = dependency.rangeEnd { sqlite3_bind_double(statement, 5, end.timeIntervalSince1970) }
                else { sqlite3_bind_null(statement, 5) }
                let result = sqlite3_step(statement)
                sqlite3_finalize(statement)
                guard result == SQLITE_DONE else { throw databaseError() }
            }

            let candidates = try applyingArtifactInvalidations(to: queryArtifactRevisions(
                "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE logical_key = ? AND artifact_type = ?",
                binds: { statement in
                    bind(revision.logicalKey, to: statement, at: 1)
                    bind(revision.kind.rawValue, to: statement, at: 2)
                }
            ))
            let resolution = try ArtifactResolver.resolve(candidates)
            try execute("UPDATE artifacts SET is_canonical = 0 WHERE logical_key = ? AND artifact_type = ?", bindings: [revision.logicalKey, revision.kind.rawValue])
            try execute("UPDATE artifacts SET is_canonical = 1 WHERE artifact_id = ?", bindings: [resolution.canonical.id])
            if let importedObjectID, let ciphertextHash {
                if try hasImportedObject(importedObjectID) { return true }
                try recordImport(importedObjectID, deviceID: revision.originDeviceID, kind: "artifact_revision", hash: ciphertextHash)
            }
            return true
        }
    }

    private func artifactRevision(id: String) throws -> RiverArtifactRevision? {
        try queryArtifactRevisions(
            "SELECT artifact_id, logical_key, artifact_type, revision_number, origin_device_id, logical_millis, logical_counter, input_frontier_json, input_snapshot_hash, pipeline_version, prompt_version, model_provider, model_identifier, content, content_hash, status, user_state, supersedes_revision_id FROM artifacts WHERE artifact_id = ? LIMIT 1"
        ) { statement in bind(id, to: statement, at: 1) }.first
    }

    private func queryArtifactRevisions(_ sql: String, binds: (OpaquePointer) -> Void) throws -> [RiverArtifactRevision] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        binds(statement)
        var result: [RiverArtifactRevision] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0), let logicalKey = string(statement, 1),
                  let kind = RiverArtifactKind(rawValue: string(statement, 2) ?? ""),
                  let owner = string(statement, 4),
                  let frontierString = string(statement, 7), let frontierData = frontierString.data(using: .utf8),
                  let frontier = try? decoder.decode(InputFrontier.self, from: frontierData),
                  let content = data(statement, 13),
                  let status = ArtifactStatus(rawValue: string(statement, 15) ?? "") else { continue }
            let ownerID = RiverDeviceID(rawValue: owner)
            let dependencies = try artifactDependencies(id)
            result.append(RiverArtifactRevision(
                id: id,
                logicalKey: logicalKey,
                kind: kind,
                revisionNumber: UInt64(max(0, sqlite3_column_int64(statement, 3))),
                originDeviceID: ownerID,
                clock: HybridLogicalClock(
                    physicalMilliseconds: UInt64(max(0, sqlite3_column_int64(statement, 5))),
                    logicalCounter: UInt32(max(0, sqlite3_column_int64(statement, 6))),
                    deviceID: ownerID
                ),
                inputFrontier: frontier,
                inputSnapshotHash: string(statement, 8) ?? "",
                pipelineVersion: string(statement, 9) ?? "",
                promptVersion: string(statement, 10) ?? "",
                modelProvider: string(statement, 11) ?? "",
                modelIdentifier: string(statement, 12) ?? "",
                content: content,
                contentHash: string(statement, 14) ?? "",
                status: status,
                userState: ArtifactUserState(rawValue: Int(sqlite3_column_int64(statement, 16))) ?? .generated,
                supersedesRevisionID: string(statement, 17),
                dependencies: dependencies
            ))
        }
        return result
    }

    private func artifactDependencies(_ artifactID: String) throws -> [ArtifactDependency] {
        let sql = "SELECT dependency_type, dependency_id, range_start, range_end FROM artifact_dependencies WHERE artifact_id = ? ORDER BY dependency_type, dependency_id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(artifactID, to: statement, at: 1)
        var result: [ArtifactDependency] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let type = string(statement, 0), let id = string(statement, 1) else { continue }
            let start = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let end = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            result.append(ArtifactDependency(type: type, id: id, rangeStart: start, rangeEnd: end))
        }
        return result
    }

    private func execute(_ sql: String, bindings: [String]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() { bind(value, to: statement, at: Int32(index + 1)) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func operationFrontiers(localSequence: UInt64) throws -> [String: UInt64] {
        var result: [String: UInt64] = [deviceID.rawValue: localSequence]
        for registration in try allDeviceRegistrations() where registration.id != deviceID {
            result[registration.id.rawValue] = UInt64(try stateValue("imported.operation.prefix.\(registration.id.rawValue)") ?? "0") ?? 0
        }
        return result
    }

    private func contiguousOperationPrefix(for id: RiverDeviceID) throws -> UInt64 {
        let sql = "SELECT origin_sequence FROM state_operations WHERE actor_device_id = ? ORDER BY origin_sequence"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(id.rawValue, to: statement, at: 1)
        var sequences: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW { sequences.append(UInt64(max(0, sqlite3_column_int64(statement, 0)))) }
        let previous = UInt64(try stateValue("imported.operation.prefix.\(id.rawValue)") ?? "0") ?? 0
        return SequenceScan(sequences: sequences, startingAfter: previous).contiguousThrough
    }

    private func lookupEvent(id: UUID) throws -> RiverEvent? {
        let sql = "SELECT id, origin_device_id, origin_sequence, timestamp, recorded_at, observed_timezone, source, kind, source_hash, payload_json FROM raw_events WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeEvent(statement)
    }

    private func decodeEvent(_ statement: OpaquePointer) throws -> RiverEvent {
        guard let id = UUID(uuidString: string(statement, 0) ?? ""),
              let origin = string(statement, 1),
              let source = string(statement, 6),
              let kind = string(statement, 7),
              let payload = string(statement, 9)?.data(using: .utf8) else {
            throw RiverLocalDatabaseError.sql("数据库中存在无法解析的事件行")
        }
        return RiverEvent(
            id: id,
            originDeviceID: RiverDeviceID(rawValue: origin),
            originSequence: UInt64(max(0, sqlite3_column_int64(statement, 2))),
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            recordedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            observedTimeZoneIdentifier: string(statement, 5),
            source: source,
            kind: kind,
            sourceHash: string(statement, 8) ?? "",
            payload: payload
        )
    }

    private func contiguousEventPrefix(for id: RiverDeviceID) throws -> UInt64 {
        let sql = "SELECT origin_sequence FROM raw_events WHERE origin_device_id = ? ORDER BY origin_sequence"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(id.rawValue, to: statement, at: 1)
        var sequences: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW { sequences.append(UInt64(max(0, sqlite3_column_int64(statement, 0)))) }
        let previous = UInt64(try stateValue("imported.event.prefix.\(id.rawValue)") ?? "0") ?? 0
        return SequenceScan(sequences: sequences, startingAfter: previous).contiguousThrough
    }

    private func hasImportedObject(_ objectID: String) throws -> Bool {
        let sql = "SELECT 1 FROM sync_imports WHERE object_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(objectID, to: statement, at: 1)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func recordImport(_ objectID: String, deviceID: RiverDeviceID, kind: String, hash: String) throws {
        let sql = "INSERT INTO sync_imports(object_id, source_device_id, object_type, ciphertext_hash, imported_at) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(objectID, to: statement, at: 1)
        bind(deviceID.rawValue, to: statement, at: 2)
        bind(kind, to: statement, at: 3)
        bind(hash, to: statement, at: 4)
        sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func stateValue(_ key: String) throws -> String? {
        let sql = "SELECT value FROM sync_state WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return string(statement, 0)
    }

    private func setStateValue(_ value: String, for key: String) throws {
        let sql = "INSERT OR REPLACE INTO sync_state(key, value) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(key, to: statement, at: 1)
        bind(value, to: statement, at: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        do {
            let result = try body()
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
            return result
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private func string(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private func databaseError() -> RiverLocalDatabaseError {
        RiverLocalDatabaseError.sql(db.map { String(cString: sqlite3_errmsg($0)) } ?? "数据库连接已关闭")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension RiverLocalDatabase: RiverSyncLocalStore {
    var syncDeviceID: RiverDeviceID? { deviceID }

    func localEventBatches() throws -> [RiverEventBatch] { try eventBatches() }
    func localStateOperationBatches() throws -> [StateOperationBatch] { try stateOperationBatches() }

    func importEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        let changed = try importBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash)
        refreshTimeline()
        return changed
    }

    func importedObjectExists(_ objectID: String) throws -> Bool {
        try hasImportedObject(objectID)
    }

    func ownedFrontier() throws -> StreamFrontier {
        StreamFrontier(
            events: try ownedEventFrontier(),
            operations: UInt64(try stateValue("owned.operation.sequence.\(deviceID.rawValue)") ?? "0") ?? 0
        )
    }

    func importedFrontiers(for deviceIDs: Set<RiverDeviceID>) throws -> [String: StreamFrontier] {
        var result: [String: StreamFrontier] = [:]
        for id in deviceIDs {
            result[id.rawValue] = StreamFrontier(
                events: try importedEventFrontier(for: id),
                operations: UInt64(try stateValue("imported.operation.prefix.\(id.rawValue)") ?? "0") ?? 0
            )
        }
        return result
    }

    func sequenceGapDevices(expectedFrontiers: [String: StreamFrontier]) throws -> Set<RiverDeviceID> {
        var gaps = Set<RiverDeviceID>()
        for (deviceText, frontier) in expectedFrontiers {
            let deviceID = RiverDeviceID(rawValue: deviceText)
            let eventSequences = try sequences(table: "raw_events", column: "origin_sequence", ownerColumn: "origin_device_id", owner: deviceText)
            let operationSequences = try sequences(table: "state_operations", column: "origin_sequence", ownerColumn: "actor_device_id", owner: deviceText)
            if SequenceScan(sequences: eventSequences).contiguousThrough < frontier.events
                || SequenceScan(sequences: operationSequences).contiguousThrough < frontier.operations {
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
                ("Events", try sequences(table: "raw_events", column: "origin_sequence", ownerColumn: "origin_device_id", owner: deviceText), frontier.events),
                ("Operations", try sequences(table: "state_operations", column: "origin_sequence", ownerColumn: "actor_device_id", owner: deviceText), frontier.operations)
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
        let sql = "SELECT device_id, display_name, platform, lifecycle, logical_millis, logical_counter FROM devices"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        var result: [DeviceRegistration] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, 0),
                  let lifecycle = DeviceLifecycle(rawValue: string(statement, 3) ?? "active") else { continue }
            result.append(DeviceRegistration(
                id: RiverDeviceID(rawValue: id),
                displayName: string(statement, 1) ?? id,
                platform: string(statement, 2) ?? "unknown",
                lifecycle: lifecycle,
                clock: HybridLogicalClock(
                    physicalMilliseconds: UInt64(max(0, sqlite3_column_int64(statement, 4))),
                    logicalCounter: UInt32(max(0, sqlite3_column_int64(statement, 5))),
                    deviceID: RiverDeviceID(rawValue: id)
                )
            ))
        }
        return result
    }

    func mergeDeviceRegistrations(_ incoming: [DeviceRegistration]) throws {
        for registration in DeviceRegistry.merge(try allDeviceRegistrations() + incoming) {
            let sql = "INSERT OR REPLACE INTO devices(device_id, display_name, platform, lifecycle, logical_millis, logical_counter, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
            bind(registration.id.rawValue, to: statement, at: 1)
            bind(registration.displayName, to: statement, at: 2)
            bind(registration.platform, to: statement, at: 3)
            bind(registration.lifecycle.rawValue, to: statement, at: 4)
            sqlite3_bind_int64(statement, 5, Int64(registration.clock.physicalMilliseconds))
            sqlite3_bind_int64(statement, 6, Int64(registration.clock.logicalCounter))
            sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
            let status = sqlite3_step(statement)
            sqlite3_finalize(statement)
            guard status == SQLITE_DONE else { throw databaseError() }
        }
    }

    func reconcileDeviceRegistryFromOperations() throws {
        let operations = try allStateOperations().filter { $0.operationType == "device.lifecycle.set" }
        let resolved = StateOperationResolver.resolve(operations)
        let registrations = resolved.currentByField.values.compactMap { operation -> DeviceRegistration? in
            guard operation.targetID.hasPrefix("device:"),
                  let payload = try? decoder.decode(DeviceLifecyclePayload.self, from: operation.payload) else { return nil }
            let deviceID = RiverDeviceID(rawValue: String(operation.targetID.dropFirst("device:".count)))
            return DeviceRegistration(
                id: deviceID,
                displayName: payload.displayName,
                platform: payload.platform,
                lifecycle: payload.lifecycle,
                clock: operation.clock
            )
        }
        try mergeDeviceRegistrations(registrations)
    }

    func retireDevice(_ target: RiverDeviceID) throws {
        guard target != deviceID,
              let current = try allDeviceRegistrations().first(where: { $0.id == target }) else {
            throw RiverLocalDatabaseError.sql("无法退役本机或未登记的设备")
        }
        let payload = try encode(DeviceLifecyclePayload(
            displayName: current.displayName,
            platform: current.platform,
            lifecycle: .retired
        ))
        _ = try appendStateOperation(
            targetID: "device:\(target.rawValue)",
            fieldKey: "lifecycle",
            operationType: "device.lifecycle.set",
            payload: payload
        )
        try reconcileDeviceRegistryFromOperations()
    }

    func canonicalStateDigest() throws -> String {
        let events = try allEvents()
        let operations = try allStateOperations()
        let artifacts = try canonicalArtifactRevisions().map(\.canonicalDigestEntry)
        let registrations = try allDeviceRegistrations()
        var frontiers: [String: UInt64] = [:]
        for device in registrations {
            let local = device.id == deviceID
            let eventFrontier = local
                ? try ownedEventFrontier()
                : try importedEventFrontier(for: device.id)
            let operationFrontier = local
                ? UInt64(try stateValue("owned.operation.sequence.\(device.id.rawValue)") ?? "0") ?? 0
                : UInt64(try stateValue("imported.operation.prefix.\(device.id.rawValue)") ?? "0") ?? 0
            frontiers["\(device.id.rawValue):events"] = eventFrontier
            frontiers["\(device.id.rawValue):operations"] = operationFrontier
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
        let revisionKey = "owned.manifest.revision.\(deviceID.rawValue)"
        let revision = max(UInt64(try stateValue(revisionKey) ?? "0") ?? 0, previousRevision)
        guard revision < UInt64(Int64.max) else { throw RiverLocalDatabaseError.sql("Manifest 版本超出支持范围") }
        let nextRevision = revision + 1

        let physicalKey = "hlc.physical.\(deviceID.rawValue)"
        let logicalKey = "hlc.logical.\(deviceID.rawValue)"
        let physical = UInt64(try stateValue(physicalKey) ?? "0") ?? 0
        let logical = UInt32(try stateValue(logicalKey) ?? "0") ?? 0
        var clock = HybridLogicalClock(physicalMilliseconds: physical, logicalCounter: logical, deviceID: deviceID)
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        if let remoteClock { clock.observe(remoteClock, wallTimeMilliseconds: now) }
        clock.tick(wallTimeMilliseconds: now)
        try transaction {
            try setStateValue(String(nextRevision), for: revisionKey)
            try setStateValue(String(clock.physicalMilliseconds), for: physicalKey)
            try setStateValue(String(clock.logicalCounter), for: logicalKey)
        }
        return (nextRevision, clock)
    }

    func lastPublishedManifestKey(for directoryID: String) throws -> String? {
        try stateValue("manifest.key.\(directoryID)")
    }

    func savePublishedManifestKey(_ key: String, for directoryID: String) throws {
        try setStateValue(key, for: "manifest.key.\(directoryID)")
    }

    func recordVerification(isVerified: Bool, digest: String) throws {
        try transaction {
            try setStateValue(isVerified ? "1" : "0", for: "sync.verification.ok")
            try setStateValue(isVerified ? digest : "", for: "sync.verification.digest")
            try setStateValue(isVerified ? String(Date().timeIntervalSince1970) : "", for: "sync.verification.time")
        }
    }

    func isCurrentStateVerified() -> Bool {
        guard let registrations = try? allDeviceRegistrations() else { return false }
        if registrations.filter({ $0.lifecycle == .active }).count <= 1 { return true }
        guard let verified = try? stateValue("sync.verification.ok"), verified == "1",
              let saved = try? stateValue("sync.verification.digest") else { return false }
        return (try? canonicalStateDigest()) == saved
    }

    private func stringIDs(in table: String, column: String, whereClause: String = "1 = 1") throws -> [String] {
        let sql = "SELECT \(column) FROM \(table) WHERE \(whereClause) ORDER BY \(column)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let value = string(statement, 0) { result.append(value) }
        }
        return result
    }

    private func sequences(table: String, column: String, ownerColumn: String, owner: String) throws -> [UInt64] {
        let sql = "SELECT \(column) FROM \(table) WHERE \(ownerColumn) = ? ORDER BY \(column)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(owner, to: statement, at: 1)
        var values: [UInt64] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(UInt64(max(0, sqlite3_column_int64(statement, 0)))) }
        return values
    }
}
