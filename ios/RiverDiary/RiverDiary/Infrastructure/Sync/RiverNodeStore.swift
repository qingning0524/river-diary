import Foundation
import CryptoKit
import RiverDiaryCore
import Security
import SwiftUI

struct RiverNodeDiagnosticsReport: Codable {
    let generatedAt: Date
    let deviceID: String
    let databaseSchemaVersion: Int
    let eventCount: Int
    let sessionCount: Int
    let placeCount: Int
    let stateOperationCount: Int
    let artifactCount: Int
    let canonicalArtifactCount: Int
    let staleArtifactCount: Int
    let pendingConfirmationStatus: String
    let importedObjectCount: Int
    let lastRunExportedEventBatches: Int
    let lastRunExportedOperationBatches: Int
    let lastRunExportedArtifactRevisions: Int
    let lastRunImportedEventBatches: Int
    let lastRunImportedOperationBatches: Int
    let lastRunImportedArtifactRevisions: Int
    let eventFrontier: UInt64
    let operationFrontier: UInt64
    let selectedDirectory: String
    let bookmarkStatus: String
    let lanReplicationStatus: String
    let lastSuccessfulExportAt: Date?
    let lastImportAt: Date?
    let lastReconciliationAt: Date?
    let lastVerifiedAt: Date?
    let canonicalDigest: String
    let missingSequenceDevices: [String]
    let missingSequenceRanges: [String]
    let integrityFailures: [String]
    let locationAuthorization: String
    let lastLocationEventAt: Date?
    let lastGeocodeAt: Date?
    let mapCandidateRecords: Int
    let lastAppActivityIntentAt: Date?
    let analysisJobStatus: String
}

@MainActor
final class RiverNodeStore: ObservableObject {
    @Published private(set) var database: RiverLocalDatabase?
    @Published private(set) var locationCollector: IPhoneLocationCollector?
    @Published private(set) var motionCollector: IPhoneMotionCollector?
    @Published private(set) var photoAnalyzer: IPhonePhotoAnalyzer?
    @Published private(set) var aiStore: IPhoneAIStore?
    @Published private(set) var initializationError: String?
    @Published private(set) var lastCaptureError: String?
    @Published private(set) var stateRevision: UInt64 = 0
    @Published private(set) var syncStatus = "未连接"
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var keyTransferCode: String?
    @Published private(set) var syncReport: SyncRunReport?
    @Published private(set) var lastSuccessfulExportAt: Date?
    @Published private(set) var lastImportAt: Date?
    @Published private(set) var lastVerifiedAt: Date?
    @Published private(set) var diagnosticActionMessage: String?
    @Published private(set) var habitActionMessage: String?
    @Published private(set) var isLANReplicating = false
    @Published private(set) var lanSyncStatus = "局域网复制未启动"
    private var localStateObserver: NSObjectProtocol?
    private var lanReplicator: RiverLANReplicator?
    private var lanFolderURL: URL?
    private var deferredSyncContext: (drive: ICloudDriveStore, moodScores: [String: Int])?
    private var pendingLegacyDiarySnapshot: DiaryData?
    private var legacyDiaryMigrationNeedsReconciliation = false
    @Published private(set) var isSyncing = false
    @Published private(set) var devices: [DeviceRegistration] = []
    @Published private(set) var unresolvedDecisionConflicts = 0
    @Published private(set) var backupMessage: String?
    var onMoodScoresChanged: (([String: Int], Set<String>) -> Void)?

    /// `opensImmediately: false` 用于首次未绑定账号的启动：只建观察者，不打开正式库。
    /// 登录后由 `openIfNeeded()` 打开并接上采集/AI。
    init(databaseURL: URL? = nil, testDeviceID: RiverDeviceID? = nil, opensImmediately: Bool = true) {
        localStateObserver = NotificationCenter.default.addObserver(
            forName: .riverLocalNodeStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markLocalStateChanged() }
        }
        guard opensImmediately else { return }
        openDatabase(databaseURL: databaseURL, testDeviceID: testDeviceID)
    }

    private func openDatabase(databaseURL: URL?, testDeviceID: RiverDeviceID?) {
        do {
            if let testDeviceID {
                database = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: testDeviceID)
            } else {
                database = try RiverLocalDatabase(databaseURL: databaseURL)
            }
            if let database {
                locationCollector = IPhoneLocationCollector(database: database)
                motionCollector = IPhoneMotionCollector(database: database)
                photoAnalyzer = IPhonePhotoAnalyzer(database: database)
                aiStore = IPhoneAIStore(database: database, photoAnalyzer: photoAnalyzer)
                refreshDevices()
                restoreDiagnosticTimestamps(deviceID: database.deviceID)
                retryPendingLegacyDiaryMigration()
            }
            initializationError = nil
        } catch {
            initializationError = error.localizedDescription
        }
    }

    /// 登录（或显式认领）后幂等打开此前被延迟的正式库。
    @discardableResult
    func openIfNeeded() -> Bool {
        if database == nil { retryOpen() }
        return database != nil
    }

    deinit {
        if let localStateObserver { NotificationCenter.default.removeObserver(localStateObserver) }
        lanReplicator?.stop()
        lanFolderURL?.stopAccessingSecurityScopedResource()
    }

    var deviceID: String { database?.deviceID.rawValue ?? "不可用" }

    /// 本机资料归属。绑定账号时写入；换机恢复后由数据库带回。
    var localProfileOwner: String? {
        try? database?.localProfileOwner()
    }

    func setLocalProfileOwner(_ userID: String) throws {
        guard let database else {
            throw RiverLocalDatabaseError.sql("本机资料库尚未打开，不能绑定账号")
        }
        try database.setLocalProfileOwner(userID)
    }
    var eventCount: Int { database?.timelineEvents.count ?? 0 }

    func retryOpen() {
        guard database == nil else { return }
        do {
            database = try RiverLocalDatabase()
            if let database {
                locationCollector = IPhoneLocationCollector(database: database)
                motionCollector = IPhoneMotionCollector(database: database)
                photoAnalyzer = IPhonePhotoAnalyzer(database: database)
                aiStore = IPhoneAIStore(database: database, photoAnalyzer: photoAnalyzer)
                refreshDevices()
                restoreDiagnosticTimestamps(deviceID: database.deviceID)
                retryPendingLegacyDiaryMigration()
            }
            initializationError = nil
        } catch {
            initializationError = error.localizedDescription
        }
    }

    /// 健康数据边界：默认只在本机读取/展示，不写入跨设备事实库，也不进入
    /// iCloud 加密复制。Apple 对 HealthKit 数据的云存储要求比普通日记更严格；
    /// 跨设备健康摘要不是 D0 的必需能力。旧版本已写入的健康事件不会被删除，
    /// 升级后不会再新增；正式上架前仍需做一次历史清理迁移。
    static var healthLocalOnly: Bool {
        UserDefaults.standard.object(forKey: "river.health.localOnly") as? Bool ?? true
    }

    func recordHealthSnapshot(nights: [SleepNight], exerciseDays: [ExerciseDay],
                              intervals: [ExerciseInterval] = [],
                              workouts: [WorkoutSummary] = [],
                              stateOfMind: [StateOfMindSummary] = []) {
        guard let database else { return }
        guard !Self.healthLocalOnly else {
            lastCaptureError = nil
            return
        }
        let dayKey: (Date) -> String = { date in
            let formatter = DateFormatter()
            formatter.calendar = Calendar.current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.current.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        var insertedHealthEvents: [RiverEvent] = []
        do {
            // 只有清醒/在床记录的夜晚是“未知”，不能写成 0 小时睡眠。
            for night in nights where night.hasAsleepSamples {
                let metrics = RiverEventMetrics(
                    sleepHours: night.totalHours,
                    coreSleepMinutes: Int((night.core / 60).rounded()),
                    deepSleepMinutes: Int((night.deep / 60).rounded()),
                    remSleepMinutes: Int((night.rem / 60).rounded()),
                    awakeMinutes: Int((night.awake / 60).rounded())
                )
                let payload = RiverEventPayload(metrics: metrics)
                let payloadData = try JSONEncoder().encode(payload)
                let hash = Self.sha256(payloadData)
                let key = "\(dayKey(night.date))|\(hash)"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: "health.sleep.\(database.deviceID.rawValue)", key: key),
                    source: "healthkit",
                    kind: "health.sleep.snapshot",
                    payload: payload,
                    observedAt: Calendar.current.startOfDay(for: night.date),
                    sourceHash: hash,
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedHealthEvents.append($0) }
                )
            }
            for day in exerciseDays {
                let metrics = RiverEventMetrics(
                    steps: Int(day.steps.rounded()),
                    distanceKm: day.distanceKilometers,
                    activeEnergyKcal: day.activeEnergyKilocalories
                )
                let payload = RiverEventPayload(metrics: metrics)
                let payloadData = try JSONEncoder().encode(payload)
                let hash = Self.sha256(payloadData)
                let key = "\(dayKey(day.date))|\(hash)"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: "health.exercise.\(database.deviceID.rawValue)", key: key),
                    source: "healthkit",
                    kind: "health.exercise.snapshot",
                    payload: payload,
                    observedAt: Calendar.current.startOfDay(for: day.date),
                    sourceHash: hash,
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedHealthEvents.append($0) }
                )
            }
            for interval in intervals {
                let metrics = RiverEventMetrics(
                    steps: interval.steps.map { Int($0.rounded()) },
                    distanceKm: interval.distanceKilometers,
                    activeEnergyKcal: interval.activeEnergyKilocalories
                )
                guard metrics.steps != nil || metrics.distanceKm != nil || metrics.activeEnergyKcal != nil else { continue }
                let payload = RiverEventPayload(intervalEnd: interval.end, metrics: metrics)
                let payloadData = try JSONEncoder().encode(payload)
                let hash = Self.sha256(payloadData)
                let bucket = Int(interval.start.timeIntervalSince1970 / 900)
                let key = "\(bucket)|\(hash)"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: "health.exercise.interval.\(database.deviceID.rawValue)", key: key),
                    source: "healthkit",
                    kind: "health.exercise.interval",
                    payload: payload,
                    observedAt: interval.start,
                    sourceHash: hash,
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedHealthEvents.append($0) }
                )
            }
            for workout in workouts {
                let durationMinutes = max(0, Int(workout.end.timeIntervalSince(workout.start) / 60))
                let metrics = RiverEventMetrics(
                    distanceKm: workout.distanceKm,
                    activeEnergyKcal: workout.energyKcal,
                    durationMinutes: durationMinutes
                )
                let payload = RiverEventPayload(
                    text: workout.activityName,
                    intervalEnd: workout.end,
                    metrics: metrics
                )
                let payloadData = try JSONEncoder().encode(payload)
                let hash = Self.sha256(payloadData)
                let key = "\(workout.id)|\(workout.start.timeIntervalSince1970)"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: "health.workout.\(database.deviceID.rawValue)", key: key),
                    source: "healthkit",
                    kind: "health.workout",
                    payload: payload,
                    observedAt: workout.start,
                    sourceHash: hash,
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedHealthEvents.append($0) }
                )
            }
            for entry in stateOfMind {
                let metrics = RiverEventMetrics(valence: entry.valence)
                let payload = RiverEventPayload(text: entry.kindLabel, metrics: metrics)
                let payloadData = try JSONEncoder().encode(payload)
                let hash = Self.sha256(payloadData)
                let key = "\(entry.id)|\(entry.date.timeIntervalSince1970)"
                _ = try database.append(
                    id: RiverStableIdentifier.uuid(namespace: "health.stateOfMind.\(database.deviceID.rawValue)", key: key),
                    source: "healthkit",
                    kind: "health.stateOfMind",
                    payload: payload,
                    observedAt: entry.date,
                    sourceHash: hash,
                    refreshTimelineAfterAppend: false,
                    notifyLocalStateChange: false,
                    invalidateArtifactsAfterAppend: false,
                    onInserted: { insertedHealthEvents.append($0) }
                )
            }
            if !insertedHealthEvents.isEmpty {
                try database.invalidateArtifactsForBatch(insertedHealthEvents)
                database.refreshTimeline()
                NotificationCenter.default.post(name: .riverLocalNodeStateDidChange, object: database.deviceID.rawValue)
            }
            lastCaptureError = nil
            IPhoneDayContextBuilder.publish(database: database)
        } catch {
            lastCaptureError = error.localizedDescription
        }
    }

    func refreshDayContext() {
        guard let database else { return }
        IPhoneDayContextBuilder.publish(database: database)
    }

    /// 网页镜像用：按设备+天取最新快照，最多 400 天。
    func dayContextSnapshotsForWeb(limit: Int = 400) -> [DayContextSnapshot] {
        guard let database, let events = try? database.allEvents() else { return [] }
        let contexts = events.filter { $0.kind == "dayContextSnapshot" }.compactMap { event -> (Date, DayContextSnapshot)? in
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload),
                  let json = payload.contextJSON,
                  let snapshot = DayContextSnapshot.decodeJSON(json) else { return nil }
            return (event.recordedAt, snapshot)
        }
        let latest = Dictionary(grouping: contexts) { "\($0.1.deviceID)|\($0.1.day)" }
            .values.compactMap { group in group.max { $0.0 < $1.0 }?.1 }
        return Array(latest.sorted { $0.day > $1.day }.prefix(limit))
    }

    func recordMoodCorrection(dayKey: String, score: Int, operationID: UUID = UUID()) {
        guard let database else { return }
        struct Payload: Codable { let day: String; let score: Int }
        do {
            let bytes = try JSONEncoder().encode(Payload(day: dayKey, score: score))
            _ = try database.appendStateOperation(
                id: operationID,
                targetID: "mood:\(dayKey)",
                fieldKey: "score",
                operationType: "mood.score.set",
                payload: bytes
            )
            stateRevision &+= 1
            publishMoodScores()
            refreshDevices()
            aiStore?.reloadDailyReview()
            lastCaptureError = nil
        } catch {
            lastCaptureError = error.localizedDescription
        }
    }

    func recordMoodReset(dayKey: String) {
        guard let database else { return }
        struct Payload: Codable { let day: String }
        do {
            let bytes = try JSONEncoder().encode(Payload(day: dayKey))
            _ = try database.appendStateOperation(
                targetID: "mood:\(dayKey)",
                fieldKey: "score",
                operationType: "mood.score.reset",
                payload: bytes
            )
            stateRevision &+= 1
            publishMoodScores()
            lastCaptureError = nil
        } catch {
            lastCaptureError = error.localizedDescription
        }
    }

    func migrateLegacyMoodScores(_ scores: [String: Int]) {
        let current = currentMoodState().scores
        guard let database else { return }
        for (day, score) in scores where current[day] != score {
            let operationID = RiverStableIdentifier.uuid(
                namespace: "legacy.mood.\(database.deviceID.rawValue)",
                key: "\(day)|\(score)"
            )
            recordMoodCorrection(dayKey: day, score: score, operationID: operationID)
        }
    }

    @discardableResult
    func savePlaceDecision(placeID: String, name: String, semanticType: String) -> Bool {
        guard let database else {
            lastCaptureError = initializationError ?? "本机记录库暂不可用。"
            return false
        }
        do {
            let decision = RiverPlaceUserDecision(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                semanticType: semanticType.trimmingCharacters(in: .whitespacesAndNewlines),
                isConfirmed: true
            )
            let payload = try JSONEncoder().encode(decision)
            _ = try database.appendStateOperation(
                targetID: placeID,
                fieldKey: "identity",
                operationType: "place.identity.set",
                payload: payload
            )
            try database.rebuildPlaces()
            try database.markPlaceConfirmationResolved(placeID: placeID, name: decision.name)
            database.refreshTimeline()
            stateRevision &+= 1
            habitActionMessage = "地点更正已保存在本机；连接共享文件夹后会继续同步。"
            lastCaptureError = nil
            return true
        } catch {
            lastCaptureError = error.localizedDescription
            return false
        }
    }

    func importSyncKey(_ code: String) {
        do {
            let key = try RiverSecureStore.importSyncKey(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            keyTransferCode = key.exportCode
            syncStatus = "同步密钥已导入"
            lastCaptureError = nil
        } catch {
            lastCaptureError = "同步密钥无效：\(error.localizedDescription)"
        }
    }

    func revealOrCreateSyncKey() {
        do {
            let key = try loadOrCreateSyncKey()
            keyTransferCode = key.exportCode
            syncStatus = "同步密钥已就绪；请在另一设备导入同一密钥。"
            lastCaptureError = nil
        } catch {
            lastCaptureError = "同步密钥无法安全读取：\(error.localizedDescription)"
        }
    }

    func makeEncryptedLocalBackup() throws -> Data {
        guard let database else { throw RiverLocalDatabaseError.open(initializationError ?? "本地事件库不可用") }
        let key = try loadOrCreateSyncKey()
        let backup = try database.makeLocalBackup()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(backup)
        let object = try EncryptedReplicationObject.seal(
            plaintext,
            id: "local-backup-\(database.deviceID.rawValue)-\(Int(Date().timeIntervalSince1970))",
            kind: "local_backup",
            using: key
        )
        return try encoder.encode(object)
    }

    func restoreEncryptedLocalBackup(_ data: Data) {
        guard let database else {
            backupMessage = initializationError ?? "本地事件库不可用"
            return
        }
        do {
            let object = try JSONDecoder().decode(EncryptedReplicationObject.self, from: data)
            guard object.kind == "local_backup",
                  object.protocolVersion == EncryptedReplicationObject.currentProtocolVersion else {
                throw RiverLocalDatabaseError.sql("文件不是受支持的 River Diary 本地备份。")
            }
            let key = try RiverSecureStore.loadSyncKey()
            let plaintext = try object.open(using: key)
            let backup = try JSONDecoder().decode(RiverNodeBackup.self, from: plaintext)
            try database.restoreLocalBackup(backup)
            refreshDevices()
            publishMoodScores()
            stateRevision &+= 1
            backupMessage = "备份中的事件、用户决定和 Artifact 已合并到本机。"
            lastCaptureError = nil
        } catch {
            backupMessage = "备份无法恢复：\(error.localizedDescription)"
        }
    }

    func setBackupMessage(_ message: String) {
        backupMessage = message
    }

    func setLANReplicationEnabled(_ enabled: Bool, using drive: ICloudDriveStore) {
        UserDefaults.standard.set(enabled, forKey: "river.lanReplication.enabled")
        if enabled {
            startLANReplication(using: drive)
            synchronize(using: drive)
        } else {
            stopLANReplication()
        }
    }

    func restoreLANReplicationPreference(using drive: ICloudDriveStore) {
        if UserDefaults.standard.bool(forKey: "river.lanReplication.enabled") {
            startLANReplication(using: drive)
        }
    }

    func startLANReplication(using drive: ICloudDriveStore) {
        guard let database else {
            lanSyncStatus = "本地事件库不可用"
            return
        }
        guard let folder = drive.resolvedFolderURLForSync(), drive.hasAccess else {
            if drive.lastError != nil {
                stopLANReplication()
                lanSyncStatus = "复制文件夹授权失效；重新选择文件夹后再启用局域网复制"
            } else {
                lanSyncStatus = "先连接共享复制文件夹"
            }
            return
        }
        if isLANReplicating, lanFolderURL == folder { return }
        stopLANReplication()
        guard folder.startAccessingSecurityScopedResource() else {
            drive.markAccessLost()
            lanSyncStatus = "复制文件夹授权失效；重新选择文件夹后再启用局域网复制"
            return
        }
        do {
            let key = try RiverSecureStore.loadSyncKey()
            let replicator = RiverLANReplicator(
                deviceID: database.deviceID,
                directory: ReplicationDirectory(rootURL: folder),
                key: key
            )
            replicator.onStatusChange = { [weak self] value in
                Task { @MainActor [weak self] in self?.lanSyncStatus = value }
            }
            replicator.onObjectsReceived = { [weak self] in
                Task { @MainActor [weak self] in self?.synchronize(using: drive) }
            }
            lanFolderURL = folder
            lanReplicator = replicator
            isLANReplicating = true
            lanSyncStatus = "正在查找同一 River Diary 的局域网设备"
            replicator.start()
        } catch {
            folder.stopAccessingSecurityScopedResource()
            lanSyncStatus = "局域网复制未启动：请先导入同步密钥（\(error.localizedDescription)）"
        }
    }

    func stopLANReplication() {
        lanReplicator?.stop()
        lanReplicator = nil
        if let lanFolderURL { lanFolderURL.stopAccessingSecurityScopedResource() }
        lanFolderURL = nil
        isLANReplicating = false
        lanSyncStatus = UserDefaults.standard.bool(forKey: "river.lanReplication.enabled")
            ? "等待局域网复制重新连接"
            : "局域网复制未启动"
    }

    private func markLocalStateChanged() {
        guard let database else { return }
        if let syncReport, (try? database.canonicalStateDigest()) == syncReport.canonicalStateDigest { return }
        setSyncStatus("本机状态已更新，等待加密同步和核对")
    }

    private func setSyncStatus(_ value: String) {
        guard syncStatus != value else { return }
        syncStatus = value
    }

    func synchronize(using drive: ICloudDriveStore, localMoodScores: [String: Int] = [:]) {
        guard database != nil else {
            syncStatus = "本地事件库不可用"
            return
        }
        retryPendingLegacyDiaryMigration()
        guard drive.hasAccess else {
            if drive.lastError != nil {
                stopLANReplication()
                syncStatus = "共享文件夹授权失效，请重新选择文件夹。"
                lastCaptureError = "本机事件仍已保留；重新授权后可继续同步。"
            } else {
                syncStatus = "请先选择共享文件夹"
            }
            return
        }
        guard let folder = drive.resolvedFolderURLForSync(), drive.hasAccess else {
            stopLANReplication()
            syncStatus = "共享文件夹授权失效，请重新选择 iCloud Drive 文件夹。"
            lastCaptureError = "本机事件仍已保留；重新授权后可继续同步。"
            return
        }
        if isSyncing {
            deferredSyncContext = (drive, localMoodScores)
            return
        }

        isSyncing = true
        drive.beginSyncActivity()
        setSyncStatus("正在加密同步")
        Task { @MainActor [weak self] in
            guard let self else {
                drive.endSyncActivity()
                return
            }
            await self.performSynchronization(using: drive, folder: folder, localMoodScores: localMoodScores)
        }
    }

    private func performSynchronization(
        using drive: ICloudDriveStore,
        folder: URL,
        localMoodScores: [String: Int]
    ) async {
        defer {
            isSyncing = false
            drive.endSyncActivity()
            if let deferredSyncContext {
                self.deferredSyncContext = nil
                Task { @MainActor [weak self] in
                    await Task.yield()
                    self?.synchronize(using: deferredSyncContext.drive, localMoodScores: deferredSyncContext.moodScores)
                }
            }
        }

        guard let database else {
            syncStatus = "本地事件库不可用"
            return
        }
        let accessed = folder.startAccessingSecurityScopedResource()
        guard accessed else {
            drive.markAccessLost()
            stopLANReplication()
            syncStatus = "共享文件夹授权失效，请重新选择 iCloud Drive 文件夹。"
            lastCaptureError = "本机事件仍已保留；重新授权后可继续同步。"
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        do {
            try await importLegacyUserData(from: drive, localMoodScores: localMoodScores)
            let key = try loadOrCreateSyncKey()
            keyTransferCode = key.exportCode
            let coordinator = try RiverSyncCoordinator(
                store: database,
                directory: ReplicationDirectory(rootURL: folder),
                key: key
            )
            let report = try await coordinator.synchronizeAsynchronously()
            lanReplicator?.broadcast()
            syncReport = report
            let importedEventBatches = report.importedEventBatches
            let importedOperationBatches = report.importedOperationBatches
            let importedArtifactRevisions = report.importedArtifactRevisions
            let syncDate = Date()
            lastSyncAt = syncDate
            lastSuccessfulExportAt = syncDate
            saveDiagnosticTimestamp(syncDate, key: "lastExport")
            saveDiagnosticTimestamp(syncDate, key: "lastReconciliation")
            if report.importedEventBatches + report.importedOperationBatches + report.importedArtifactRevisions > 0 {
                lastImportAt = syncDate
                saveDiagnosticTimestamp(syncDate, key: "lastImport")
            }
            if report.isVerified {
                lastVerifiedAt = syncDate
                saveDiagnosticTimestamp(syncDate, key: "lastVerified")
            }
            if importedEventBatches + importedOperationBatches + importedArtifactRevisions > 0 {
                database.refreshTimeline()
                stateRevision &+= 1
            }
            if importedOperationBatches > 0 { publishMoodScores() }
            if !report.integrityFailures.isEmpty {
                setSyncStatus("同步对象校验失败：\(report.integrityFailures.count) 项")
            } else if report.needsProtocolUpgrade {
                setSyncStatus("另一设备需要升级 River Diary")
            } else if report.isVerified {
                setSyncStatus("已验证 · 所有登记设备状态一致")
            } else {
                setSyncStatus("已复制本机变化，等待其他设备导入并确认")
            }
            lastCaptureError = nil
        } catch {
            database.refreshTimeline()
            syncStatus = "同步失败"
            lastCaptureError = error.localizedDescription
        }
    }

    func importLegacyUserData(from drive: ICloudDriveStore, localMoodScores: [String: Int]) async throws {
        let snapshot: UserDataSnapshot?
        do {
            snapshot = try await drive.readLegacyUserDataAsynchronously()
        } catch {
            lastCaptureError = "旧版共享摘要暂时无法读取：\(error.localizedDescription)"
            throw error
        }
        guard let snapshot else { return }
        let importedKey = "river.sync.legacySnapshot.updatedAt"
        let previous = UserDefaults.standard.double(forKey: importedKey)
        guard snapshot.updatedAt.timeIntervalSince1970 > previous else { return }
        guard let database else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        for night in snapshot.sleepNights {
            guard let day = formatter.date(from: night.date) else { continue }
            let payload = RiverEventPayload(metrics: RiverEventMetrics(
                sleepHours: night.totalHours,
                deepSleepMinutes: Int(night.deepMinutes.rounded()),
                remSleepMinutes: Int(night.remMinutes.rounded()),
                awakeMinutes: Int(night.awakeMinutes.rounded())
            ))
            let bytes = try JSONEncoder().encode(payload)
            let hash = Self.sha256(bytes)
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: "legacy.health.sleep.\(database.deviceID.rawValue)", key: "\(night.date)|\(hash)"),
                source: "legacy-icloud",
                kind: "health.sleep.snapshot",
                payload: payload,
                observedAt: day,
                sourceHash: hash
            )
        }
        for exercise in snapshot.exerciseDays {
            guard let day = formatter.date(from: exercise.date) else { continue }
            let payload = RiverEventPayload(metrics: RiverEventMetrics(
                steps: Int(exercise.steps.rounded()),
                distanceKm: exercise.distanceKilometers,
                activeEnergyKcal: exercise.activeEnergyKilocalories
            ))
            let bytes = try JSONEncoder().encode(payload)
            let hash = Self.sha256(bytes)
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: "legacy.health.exercise.\(database.deviceID.rawValue)", key: "\(exercise.date)|\(hash)"),
                source: "legacy-icloud",
                kind: "health.exercise.snapshot",
                payload: payload,
                observedAt: day,
                sourceHash: hash
            )
        }
        for note in snapshot.quickNotes {
            let payload = RiverEventPayload(text: note.text)
            let bytes = try JSONEncoder().encode(payload)
            let hash = Self.sha256(bytes)
            let key = "\(note.date)|\(note.createdAt.timeIntervalSince1970)|\(hash)"
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: "legacy.quick-note.\(database.deviceID.rawValue)", key: key),
                source: "legacy-icloud",
                kind: "manual.quickCapture",
                payload: payload,
                observedAt: note.createdAt,
                sourceHash: hash
            )
        }
        for (day, score) in snapshot.moodScores where localMoodScores[day] == nil {
            let key = "\(day)|\(score)"
            recordMoodCorrection(
                dayKey: day,
                score: score,
                operationID: RiverStableIdentifier.uuid(namespace: "legacy.mood.\(database.deviceID.rawValue)", key: key)
            )
        }
        try database.rebuildPlaces()
        database.refreshTimeline()
        UserDefaults.standard.set(snapshot.updatedAt.timeIntervalSince1970, forKey: importedKey)
        lastCaptureError = nil
    }

    /// Migrate the legacy iCloud diary body into canonical shared journal
    /// records. Newer user-authored records and tombstones always keep priority.
    func importLegacyDiarySnapshot(_ snapshot: DiaryData) {
        pendingLegacyDiarySnapshot = snapshot
        retryPendingLegacyDiaryMigration()
    }

    private func retryPendingLegacyDiaryMigration() {
        guard let snapshot = pendingLegacyDiarySnapshot else { return }
        guard let database else { return }
        let snapshotUpdatedAt = Self.legacyDiarySnapshotDate(snapshot.generated)
        var existingByDay: [String: RiverSharedStateRecord] = [:]
        for record in database.sharedUserRecords where record.kind == .journalEntry {
            existingByDay[record.logicalKey] = record
        }

        var recordsToSave: [RiverSharedStateRecord] = []
        var seenDays = Set<String>()
        for entry in snapshot.entries {
            guard seenDays.insert(entry.date).inserted,
                  let body = Self.legacyDiaryBody(entry),
                  !body.isEmpty else { continue }
            let updatedAt = snapshotUpdatedAt
                ?? DiaryEntry.dateFormatter.date(from: entry.date)
                ?? Date(timeIntervalSince1970: 0)
            let content = RiverJournalEntryContent(
                dayKey: entry.date,
                body: body,
                moodScore: entry.score.map { Int($0.rounded()) },
                energyScore: entry.metrics?.energy.map { Int($0.rounded()) },
                focusScore: entry.metrics?.focus.map { Int($0.rounded()) },
                outputScore: entry.metrics?.output.map { Int($0.rounded()) },
                category: entry.tags?.first,
                tags: entry.tags ?? [],
                source: "legacy-data.json",
                updatedAt: updatedAt
            )
            guard let shared = RiverSharedStateRecord.journalEntry(content) else { continue }

            if let existing = existingByDay[entry.date] {
                guard existing.status == "current",
                      let current = existing.journalEntryContent,
                      current.source == "legacy-data.json",
                      current.updatedAt < content.updatedAt else { continue }
                let contentIsUnchanged = current.body == content.body
                    && current.moodScore == content.moodScore
                    && current.energyScore == content.energyScore
                    && current.focusScore == content.focusScore
                    && current.outputScore == content.outputScore
                    && current.category == content.category
                    && current.tags == content.tags
                if contentIsUnchanged { continue }
            }
            recordsToSave.append(shared)
        }

        do {
            if !recordsToSave.isEmpty {
                legacyDiaryMigrationNeedsReconciliation = true
                try database.saveSharedUserRecords(recordsToSave)
            }
            if legacyDiaryMigrationNeedsReconciliation {
                try database.rebuildDerivedState()
                database.refreshTimeline()
                legacyDiaryMigrationNeedsReconciliation = false
                stateRevision &+= 1
            }
            pendingLegacyDiarySnapshot = nil
            lastCaptureError = nil
        } catch {
            lastCaptureError = "旧版日记正文迁移失败：\(error.localizedDescription)"
        }
    }

    private static func legacyDiarySnapshotDate(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: raw)
    }

    private static func legacyDiaryBody(_ entry: DiaryEntry) -> String? {
        var sections: [String] = []
        func add(_ heading: String, _ values: [String]) {
            let content = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !content.isEmpty { sections.append("\(heading)\n\(content)") }
        }

        if let overview = entry.overview { add("回顾", [overview]) }
        add("想法", entry.thoughts ?? [])
        add("备忘", entry.memos ?? [])
        let body = sections.joined(separator: "\n\n")
        return body.isEmpty ? nil : body
    }

    private func loadOrCreateSyncKey() throws -> SyncEncryptionKey {
        do {
            return try RiverSecureStore.loadSyncKey()
        } catch SecureStoreError.keychainStatus(errSecItemNotFound) {
            let key = SyncEncryptionKey()
            try RiverSecureStore.saveSyncKey(key)
            return key
        }
    }

    private func restoreDiagnosticTimestamps(deviceID: RiverDeviceID) {
        let prefix = "river.diagnostics.\(deviceID.rawValue)."
        let defaults = UserDefaults.standard
        func date(_ name: String) -> Date? {
            let value = defaults.double(forKey: prefix + name)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        lastSuccessfulExportAt = date("lastExport")
        lastImportAt = date("lastImport")
        lastSyncAt = date("lastReconciliation")
        lastVerifiedAt = date("lastVerified")
    }

    private func saveDiagnosticTimestamp(_ date: Date, key: String) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "river.diagnostics.\(deviceID).\(key)")
    }

    func currentMoodState() -> (scores: [String: Int], resets: Set<String>) {
        guard let database else { return ([:], []) }
        let allOperations = (try? database.allStateOperations()) ?? []
        unresolvedDecisionConflicts = StateOperationResolver.resolve(allOperations).conflicts.count
        let operations = allOperations.filter {
            $0.operationType == "mood.score.set" || $0.operationType == "mood.score.reset"
        }
        let resolution = StateOperationResolver.resolve(operations)
        struct ScorePayload: Decodable { let day: String; let score: Int }
        struct ResetPayload: Decodable { let day: String }
        var result: [String: Int] = [:]
        var resets = Set<String>()
        for operation in resolution.currentByField.values {
            switch operation.operationType {
            case "mood.score.set":
                guard let payload = try? JSONDecoder().decode(ScorePayload.self, from: operation.payload) else { continue }
                result[payload.day] = payload.score
                resets.remove(payload.day)
            case "mood.score.reset":
                guard let payload = try? JSONDecoder().decode(ResetPayload.self, from: operation.payload) else { continue }
                result.removeValue(forKey: payload.day)
                resets.insert(payload.day)
            default: break
            }
        }
        return (result, resets)
    }

    private func publishMoodScores() {
        let state = currentMoodState()
        onMoodScoresChanged?(state.scores, state.resets)
    }

    func refreshDevices() {
        devices = (try? database?.allDeviceRegistrations()) ?? []
        devices = DeviceRegistry.merge(devices)
        unresolvedDecisionConflicts = StateOperationResolver.resolve((try? database?.allStateOperations()) ?? []).conflicts.count
    }

    func retireDevice(_ deviceID: RiverDeviceID) {
        guard let database else { return }
        do {
            try database.retireDevice(deviceID)
            refreshDevices()
            stateRevision &+= 1
            syncStatus = "设备已退役；状态会在下一次同步传播。"
            lastCaptureError = nil
        } catch {
            lastCaptureError = error.localizedDescription
        }
    }

    func generateDiagnosticTestEvent() {
        guard let database else { return }
        do {
            _ = try database.append(
                source: "developer-diagnostics",
                kind: "diagnostic.test",
                payload: RiverEventPayload(text: "Developer Diagnostics test event")
            )
            database.refreshTimeline()
            stateRevision &+= 1
            diagnosticActionMessage = "已写入一条本机测试 Event。"
        } catch {
            diagnosticActionMessage = "测试 Event 写入失败：\(error.localizedDescription)"
        }
    }

    func rebuildDiagnosticProjection() {
        guard let database else { return }
        do {
            try database.rebuildDerivedState()
            database.refreshTimeline()
            stateRevision &+= 1
            diagnosticActionMessage = "地点、会话和 Timeline 派生视图已重建。"
        } catch {
            diagnosticActionMessage = "重建失败：\(error.localizedDescription)"
        }
    }

    func invalidateArtifactsForDiagnostics() {
        guard let database else { return }
        do {
            let count = try database.invalidateGeneratedArtifactsForDiagnostics()
            stateRevision &+= 1
            diagnosticActionMessage = count == 0 ? "没有需要失效的 AI Artifact。" : "已追加失效操作：\(count) 个生成结果需要重新分析。"
        } catch {
            diagnosticActionMessage = "Artifact 失效操作失败：\(error.localizedDescription)"
        }
    }

    func setDiagnosticActionMessage(_ message: String) {
        diagnosticActionMessage = message
    }

    func runDiagnosticSync(using drive: ICloudDriveStore, label: String) {
        guard drive.hasAccess else {
            diagnosticActionMessage = "\(label)需要先授权共享 iCloud Drive 文件夹。"
            return
        }
        diagnosticActionMessage = "\(label)会运行完整复制、扫描、导入、重建和完整性核对流程。"
        synchronize(using: drive)
        if let report = syncReport {
            diagnosticActionMessage = "\(label)已执行完整同步流程：导出 Event \(report.exportedEventBatches) 批、Operation \(report.exportedOperationBatches) 批、Artifact \(report.exportedArtifactRevisions) 个；导入 Event \(report.importedEventBatches) 批、Operation \(report.importedOperationBatches) 批、Artifact \(report.importedArtifactRevisions) 个；\(report.isVerified ? "已验证" : "等待收敛")."
        }
    }

    func reportDeveloperDiagnostics(selectedDirectory: String?, bookmarkAvailable: Bool,
                                    locationAuthorization: String) -> Data? {
        guard let database,
              let events = try? database.allEvents(),
              let operations = try? database.allStateOperations(),
              let artifactCount = try? database.allArtifactRevisionCount(),
              let canonicalArtifacts = try? database.canonicalArtifactRevisions(),
              let sessions = try? database.allSessions(),
              let importedCount = try? database.importedReplicationObjectCount(),
              let frontier = try? database.ownedFrontier(),
              let digest = try? database.canonicalStateDigest() else { return nil }
        let latestLocation = events.filter { $0.kind.hasPrefix("location.") }.max { $0.observedAt < $1.observedAt }
        let latestGeocode = events.filter { $0.kind == "location.placeCandidate" }.max { $0.observedAt < $1.observedAt }
        let latestIntent = events.filter { $0.source == "shortcuts" }.max { $0.recordedAt < $1.recordedAt }
        let latestJob = try? database.latestAnalysisJob()
        let pendingHabitCount = database.sharedUserRecords.filter {
            $0.kind == .habitCard && ($0.status == "bundled" || $0.status == "shown")
        }.count
        let pendingMemoryCount = database.sharedUserRecords.filter {
            $0.kind == .memory && database.memoryConfirmation(for: $0.id)?.confirmed != true
        }.count
        let pendingGenericCount = database.sharedUserRecords.filter {
            $0.kind == .pendingConfirmation && $0.status == "pending"
        }.count
        let staleCount = (try? database.staleArtifactCount()) ?? 0
        let snapshot = RiverNodeDiagnosticsReport(
            generatedAt: Date(),
            deviceID: database.deviceID.rawValue,
            databaseSchemaVersion: 4,
            eventCount: events.count,
            sessionCount: sessions.count,
            placeCount: database.places.count,
            stateOperationCount: operations.count,
            artifactCount: artifactCount,
            canonicalArtifactCount: canonicalArtifacts.count,
            staleArtifactCount: staleCount,
            pendingConfirmationStatus: "习惯卡 \(pendingHabitCount) 张、记忆 \(pendingMemoryCount) 条、地点 \(pendingGenericCount) 条待确认",
            importedObjectCount: importedCount,
            lastRunExportedEventBatches: syncReport?.exportedEventBatches ?? 0,
            lastRunExportedOperationBatches: syncReport?.exportedOperationBatches ?? 0,
            lastRunExportedArtifactRevisions: syncReport?.exportedArtifactRevisions ?? 0,
            lastRunImportedEventBatches: syncReport?.importedEventBatches ?? 0,
            lastRunImportedOperationBatches: syncReport?.importedOperationBatches ?? 0,
            lastRunImportedArtifactRevisions: syncReport?.importedArtifactRevisions ?? 0,
            eventFrontier: frontier.events,
            operationFrontier: frontier.operations,
            selectedDirectory: selectedDirectory ?? "未选择",
            bookmarkStatus: bookmarkAvailable ? "可访问" : "未授权或已失效",
            lanReplicationStatus: isLANReplicating ? lanSyncStatus : "未启用",
            lastSuccessfulExportAt: lastSuccessfulExportAt,
            lastImportAt: lastImportAt,
            lastReconciliationAt: lastSyncAt,
            lastVerifiedAt: lastVerifiedAt,
            canonicalDigest: digest,
            missingSequenceDevices: (syncReport?.sequenceGapDevices ?? []).map(\.rawValue),
            missingSequenceRanges: (syncReport?.missingSequenceGaps ?? []).map {
                "\($0.deviceID.rawValue)/\($0.stream): \($0.first)-\($0.last)"
            },
            integrityFailures: syncReport?.integrityFailures ?? [],
            locationAuthorization: locationAuthorization,
            lastLocationEventAt: latestLocation?.observedAt,
            lastGeocodeAt: latestGeocode?.recordedAt,
            mapCandidateRecords: events.filter { $0.kind == "location.placeCandidate" }.count,
            lastAppActivityIntentAt: latestIntent?.recordedAt,
            analysisJobStatus: latestJob.map { "\($0.status.rawValue) · \($0.logicalKey) · attempt \($0.attempt)" } ?? "暂无已记录任务"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(snapshot)
    }

    func answerSharedHabitCard(_ record: RiverSharedStateRecord, decision: String) {
        guard record.kind == .habitCard, record.status == "bundled" || record.status == "shown",
              let database,
              let bytes = record.payloadJSON.data(using: .utf8),
              var card = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            habitActionMessage = "这张回顾卡已经处理，或数据格式不受支持。"
            return
        }
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let examples = card["examples"] as? [[String: Any]] ?? []
        let exampleKeys = examples.compactMap { $0["sourceKey"] as? String }
        var status: String
        switch decision {
        case "skip":
            status = "skipped"
            card["answerKind"] = "skip"
            card["answerScopeText"] = "暂时不确定；有新线索前不再问"
        case "longTermRule":
            status = "answered"
            card["answerKind"] = "longTermRule"
            card["answerScopeText"] = "已确认从现在起沿用这个分类"
        default:
            status = "answered"
            card["answerKind"] = "onlyTheseExamples"
            card["answerScopeText"] = "只确认这次列出的 \(exampleKeys.count) 条记录，不建立长期规则"
            card["markedExampleKeys"] = exampleKeys
        }
        card["status"] = status
        card["answeredAt"] = iso

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if decision == "longTermRule" {
                let place = card["placeKey"] as? String
                let appName = card["appName"] as? String ?? "应用"
                let category = card["proposedCategory"] as? String ?? "个人习惯"
                let scope = [appName, place.map { $0 + "附近" }].compactMap { $0 }.joined(separator: " · ")
                let ruleID = UUID()
                var rule: [String: Any] = [
                    "id": ruleID.uuidString,
                    "dedupKey": card["dedupKey"] as? String ?? record.logicalKey,
                    "conditionBundleID": card["bundleID"] as? String ?? "",
                    "conditionAppName": appName,
                    "conclusionCategory": category,
                    "scopeText": scope,
                    "status": "active",
                    "origin": "userConfirmed",
                    "recordedAt": iso,
                    "validFrom": iso,
                    "supportingExampleKeys": exampleKeys,
                    "createdFromCardID": record.id.uuidString
                ]
                if let place { rule["conditionPlaceKey"] = place }
                guard JSONSerialization.isValidJSONObject(rule),
                      let ruleBytes = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]),
                      let ruleJSON = String(data: ruleBytes, encoding: .utf8) else {
                    throw RiverLocalDatabaseError.sql("无法创建习惯规则记录。")
                }
                try database.saveSharedUserRecord(RiverSharedStateRecord(
                    id: ruleID, kind: .habitRule, status: "active",
                    logicalKey: card["dedupKey"] as? String ?? record.logicalKey,
                    payloadJSON: ruleJSON, createdAt: now, updatedAt: now
                ))
                card["createdRuleID"] = ruleID.uuidString
            }
            guard JSONSerialization.isValidJSONObject(card),
                  let updatedBytes = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys]),
                  let updatedJSON = String(data: updatedBytes, encoding: .utf8) else {
                throw RiverLocalDatabaseError.sql("无法保存回顾卡决定。")
            }
            try database.saveSharedUserRecord(RiverSharedStateRecord(
                id: record.id, kind: .habitCard, status: status, logicalKey: record.logicalKey,
                payloadJSON: updatedJSON, createdAt: record.createdAt, updatedAt: now,
                batchID: record.batchID, shownAt: record.shownAt
            ))
            stateRevision &+= 1
            habitActionMessage = decision == "skip"
                ? "已保存你的决定；连接共享文件夹后会继续同步。"
                : "已保存你的回顾决定；连接共享文件夹后会继续同步。"
        } catch {
            habitActionMessage = "回顾决定保存失败：\(error.localizedDescription)"
        }
    }

    func answerSharedHabitCard(_ record: RiverSharedStateRecord,
                               naturalLanguage: String,
                               saveAsLongTermRule: Bool = false) {
        let answer = naturalLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard record.kind == .habitCard,
              record.status == "bundled" || record.status == "shown",
              !answer.isEmpty,
              let database,
              let bytes = record.payloadJSON.data(using: .utf8),
              var card = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            habitActionMessage = "这张回顾卡已经处理，或回答内容无法保存。"
            return
        }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        var conversation = card["conversation"] as? [[String: Any]] ?? []
        conversation.append(["role": "user", "text": answer, "createdAt": timestamp])
        card["conversation"] = conversation
        card["answerKind"] = saveAsLongTermRule ? "longTermRule" : "conversation"
        card["answerScopeText"] = saveAsLongTermRule ? "已确认并记住：\(answer)" : "你补充的理解：\(answer)"
        card["conversationResolved"] = true
        card["status"] = "answered"
        card["answeredAt"] = timestamp

        do {
            var updates: [RiverSharedStateRecord] = []
            if saveAsLongTermRule {
                let ruleID = UUID()
                let examples = card["examples"] as? [[String: Any]] ?? []
                var rule: [String: Any] = [
                    "id": ruleID.uuidString,
                    "dedupKey": card["dedupKey"] as? String ?? record.logicalKey,
                    "conditionBundleID": card["bundleID"] as? String ?? "",
                    "conditionAppName": card["appName"] as? String ?? "应用",
                    "naturalLanguageRule": answer,
                    "supportingEvidenceRefs": card["evidenceRefs"] as? [String] ?? [],
                    "conclusionCategory": "个人习惯",
                    "scopeText": answer,
                    "status": "active",
                    "origin": "userConfirmed",
                    "recordedAt": timestamp,
                    "validFrom": timestamp,
                    "supportingExampleKeys": examples.compactMap { $0["sourceKey"] as? String },
                    "createdFromCardID": record.id.uuidString
                ]
                if let place = card["placeKey"] as? String { rule["conditionPlaceKey"] = place }
                guard JSONSerialization.isValidJSONObject(rule),
                      let ruleBytes = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]),
                      let ruleJSON = String(data: ruleBytes, encoding: .utf8) else {
                    throw RiverLocalDatabaseError.sql("无法保存这条自然语言习惯规则。")
                }
                updates.append(RiverSharedStateRecord(
                    id: ruleID, kind: .habitRule, status: "active",
                    logicalKey: card["dedupKey"] as? String ?? record.logicalKey,
                    payloadJSON: ruleJSON, createdAt: now, updatedAt: now
                ))
                card["createdRuleID"] = ruleID.uuidString
            }
            guard JSONSerialization.isValidJSONObject(card),
                  let updatedBytes = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys]),
                  let updatedJSON = String(data: updatedBytes, encoding: .utf8) else {
                throw RiverLocalDatabaseError.sql("无法保存你的自然语言回答。")
            }
            updates.append(RiverSharedStateRecord(
                id: record.id, kind: .habitCard, status: "answered", logicalKey: record.logicalKey,
                payloadJSON: updatedJSON, createdAt: record.createdAt, updatedAt: now,
                batchID: record.batchID, shownAt: record.shownAt
            ))
            try database.saveSharedUserRecordsAtomically(updates)
            stateRevision &+= 1
            habitActionMessage = saveAsLongTermRule
                ? "你的回答和习惯规则已保存；连接共享文件夹后会继续同步。"
                : "你的回答和上下文已保存；连接共享文件夹后会继续同步。"
        } catch {
            habitActionMessage = "回答保存失败：\(error.localizedDescription)"
        }
    }

    func undoSharedHabitCard(_ record: RiverSharedStateRecord) {
        guard record.kind == .habitCard,
              ["answered", "skipped"].contains(record.status),
              let database,
              let bytes = record.payloadJSON.data(using: .utf8),
              var card = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            habitActionMessage = "这张回顾卡当前不能撤销，或已在另一台设备更新。"
            return
        }
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now)
        var updates: [RiverSharedStateRecord] = []
        if let ruleIDText = card["createdRuleID"] as? String {
            guard let ruleID = UUID(uuidString: ruleIDText),
                  let ruleRecord = database.sharedUserRecords.first(where: { $0.id == ruleID && $0.kind == .habitRule }) else {
                habitActionMessage = "关联习惯规则尚未完整同步；撤销暂未保存。"
                return
            }
            if ruleRecord.status == "active" {
                guard let ruleBytes = ruleRecord.payloadJSON.data(using: .utf8),
                      var rule = try? JSONSerialization.jsonObject(with: ruleBytes) as? [String: Any] else {
                    habitActionMessage = "关联习惯规则无法读取；撤销暂未保存。"
                    return
                }
                rule["status"] = "retired"
                rule["validTo"] = timestamp
                guard JSONSerialization.isValidJSONObject(rule),
                      let payload = try? JSONSerialization.data(withJSONObject: rule, options: [.sortedKeys]),
                      let payloadJSON = String(data: payload, encoding: .utf8) else {
                    habitActionMessage = "关联习惯规则无法更新；撤销暂未保存。"
                    return
                }
                updates.append(RiverSharedStateRecord(
                    id: ruleRecord.id, kind: .habitRule, status: "retired", logicalKey: ruleRecord.logicalKey,
                    payloadJSON: payloadJSON, createdAt: ruleRecord.createdAt, updatedAt: now
                ))
            }
        }
        card["status"] = "shown"
        card["userReopenedAt"] = timestamp
        card["conversationResolved"] = false
        card["markedExampleKeys"] = []
        card.removeValue(forKey: "answeredAt")
        card.removeValue(forKey: "answerKind")
        card.removeValue(forKey: "answerScopeText")
        card.removeValue(forKey: "createdRuleID")
        do {
            guard JSONSerialization.isValidJSONObject(card),
                  let payload = try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys]),
                  let payloadJSON = String(data: payload, encoding: .utf8) else {
                throw RiverLocalDatabaseError.sql("无法重开这张回顾卡。")
            }
            updates.append(RiverSharedStateRecord(
                id: record.id, kind: .habitCard, status: "shown", logicalKey: record.logicalKey,
                payloadJSON: payloadJSON, createdAt: record.createdAt, updatedAt: now,
                batchID: record.batchID, shownAt: record.shownAt ?? now
            ))
            try database.saveSharedUserRecordsAtomically(updates)
            stateRevision &+= 1
            habitActionMessage = "已撤销刚才的回答；问题重新进入待确认。历史操作仍会保留并同步。"
        } catch {
            habitActionMessage = "撤销回答失败：\(error.localizedDescription)"
        }
    }

    func setSharedMemoryConfirmation(_ record: RiverSharedStateRecord, confirmed: Bool) {
        guard let database else { return }
        do {
            try database.setSharedMemoryConfirmation(for: record, confirmed: confirmed)
            stateRevision &+= 1
            habitActionMessage = confirmed
                ? "已确认这条共享记忆；连接共享文件夹后会继续同步。"
                : "已撤销这条记忆的确认；连接共享文件夹后会继续同步。"
        } catch {
            habitActionMessage = "记忆决定保存失败：\(error.localizedDescription)"
        }
    }

    func resolveSharedPendingConfirmation(_ record: RiverSharedStateRecord,
                                          as resolution: RiverPendingConfirmationResolution,
                                          correction: String? = nil,
                                          selectedCandidateID: String? = nil) {
        guard let database else { return }
        do {
            try database.resolvePendingConfirmation(record, as: resolution, correction: correction,
                                                    selectedCandidateID: selectedCandidateID)
            stateRevision &+= 1
            habitActionMessage = switch resolution {
            case .confirmed: "已确认并保存在本机；连接共享文件夹后会继续同步。"
            case .rejected: "已标记为不准确并保存在本机；连接共享文件夹后会继续同步。"
            case .corrected: "已保存你的更正；连接共享文件夹后会继续同步。"
            case .dismissed: "已关闭这条待确认事项并保存在本机。"
            }
        } catch {
            habitActionMessage = "待确认事项更新失败：\(error.localizedDescription)"
        }
    }

    func reopenSharedPendingConfirmation(_ record: RiverSharedStateRecord) {
        guard let database, let reopened = record.reopened() else {
            habitActionMessage = "这条问题无法重开，或已在另一台设备更新。"
            return
        }
        do {
            try database.saveSharedUserRecord(reopened)
            stateRevision &+= 1
            habitActionMessage = "问题已重新放入待确认队列；上次回答保留在共享操作历史中。"
        } catch {
            habitActionMessage = "重开问题失败：\(error.localizedDescription)"
        }
    }

    func correctSharedMemory(_ record: RiverSharedStateRecord, title: String, body: String) {
        guard record.kind == .memory, record.status != "deleted", let database,
              let bytes = record.payloadJSON.data(using: .utf8),
              var memory = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            habitActionMessage = "这条记忆无法编辑，或已经删除。"
            return
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            habitActionMessage = "记忆标题不能为空。"
            return
        }
        let now = Date()
        memory["title"] = cleanTitle
        memory["body"] = body.trimmingCharacters(in: .whitespacesAndNewlines)
        memory["isUserConfirmed"] = true
        memory["lastConfirmedAt"] = now.timeIntervalSinceReferenceDate
        do {
            guard JSONSerialization.isValidJSONObject(memory),
                  let updatedBytes = try? JSONSerialization.data(withJSONObject: memory, options: [.sortedKeys]),
                  let payloadJSON = String(data: updatedBytes, encoding: .utf8) else {
                throw RiverLocalDatabaseError.sql("无法序列化更正后的记忆。")
            }
            try database.saveSharedUserRecord(RiverSharedStateRecord(
                id: record.id, kind: .memory, status: "confirmed", logicalKey: record.logicalKey,
                payloadJSON: payloadJSON, createdAt: record.createdAt, updatedAt: now
            ))
            stateRevision &+= 1
            habitActionMessage = "你的更正已作为用户确认保存在本机；连接共享文件夹后会继续同步。"
        } catch {
            habitActionMessage = "记忆更正保存失败：\(error.localizedDescription)"
        }
    }

    func deleteSharedMemory(_ record: RiverSharedStateRecord) {
        guard record.kind == .memory, record.status != "deleted", let database else {
            habitActionMessage = "这条记忆已经删除，或当前不可用。"
            return
        }
        let now = Date()
        do {
            try database.saveSharedUserRecord(RiverSharedStateRecord(
                id: record.id, kind: .memory, status: "deleted", logicalKey: record.logicalKey,
                payloadJSON: record.payloadJSON, createdAt: record.createdAt, updatedAt: now
            ))
            stateRevision &+= 1
            habitActionMessage = "这条记忆已从本机隐藏并记录删除决定；连接共享文件夹后会继续同步。"
        } catch {
            habitActionMessage = "记忆删除失败：\(error.localizedDescription)"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
