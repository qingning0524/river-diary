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
    @Published private(set) var isSyncing = false
    @Published private(set) var devices: [DeviceRegistration] = []
    @Published private(set) var unresolvedDecisionConflicts = 0
    @Published private(set) var backupMessage: String?
    var onMoodScoresChanged: (([String: Int], Set<String>) -> Void)?

    init(databaseURL: URL? = nil) {
        localStateObserver = NotificationCenter.default.addObserver(
            forName: .riverLocalNodeStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markLocalStateChanged() }
        }
        do {
            database = try RiverLocalDatabase(databaseURL: databaseURL)
            if let database {
                locationCollector = IPhoneLocationCollector(database: database)
                aiStore = IPhoneAIStore(database: database)
                refreshDevices()
                restoreDiagnosticTimestamps(deviceID: database.deviceID)
            }
        } catch {
            initializationError = error.localizedDescription
        }
    }

    deinit {
        if let localStateObserver { NotificationCenter.default.removeObserver(localStateObserver) }
        lanReplicator?.stop()
        lanFolderURL?.stopAccessingSecurityScopedResource()
    }

    var deviceID: String { database?.deviceID.rawValue ?? "不可用" }
    var eventCount: Int { database?.timelineEvents.count ?? 0 }

    func retryOpen() {
        guard database == nil else { return }
        do {
            database = try RiverLocalDatabase()
            if let database {
                locationCollector = IPhoneLocationCollector(database: database)
                aiStore = IPhoneAIStore(database: database)
                refreshDevices()
                restoreDiagnosticTimestamps(deviceID: database.deviceID)
            }
            initializationError = nil
        } catch {
            initializationError = error.localizedDescription
        }
    }

    func recordHealthSnapshot(nights: [SleepNight], exerciseDays: [ExerciseDay]) {
        guard let database else { return }
        let dayKey: (Date) -> String = { date in
            let formatter = DateFormatter()
            formatter.calendar = Calendar.current
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = Calendar.current.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        do {
            for night in nights {
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
                    sourceHash: hash
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
                    sourceHash: hash
                )
            }
            database.refreshTimeline()
            lastCaptureError = nil
        } catch {
            lastCaptureError = error.localizedDescription
        }
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

    func savePlaceDecision(placeID: String, name: String, semanticType: String) {
        guard let database else { return }
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
            lastCaptureError = nil
        } catch {
            lastCaptureError = error.localizedDescription
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
        if enabled { startLANReplication(using: drive) }
        else { stopLANReplication() }
    }

    func restoreLANReplicationPreference(using drive: ICloudDriveStore) {
        if UserDefaults.standard.bool(forKey: "river.lanReplication.enabled") {
            startLANReplication(using: drive)
        }
    }

    func startLANReplication(using drive: ICloudDriveStore) {
        guard drive.hasAccess, let folder = drive.resolvedFolderURLForSync(), let database else {
            lanSyncStatus = "先连接共享复制文件夹"
            return
        }
        if isLANReplicating, lanFolderURL == folder { return }
        stopLANReplication()
        guard folder.startAccessingSecurityScopedResource() else {
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
            synchronize(using: drive)
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
        syncStatus = "本机状态已更新，等待加密同步和核对"
    }

    func synchronize(using drive: ICloudDriveStore, localMoodScores: [String: Int] = [:]) {
        guard let database else {
            syncStatus = "本地事件库不可用"
            return
        }
        guard drive.hasAccess, let folder = drive.resolvedFolderURLForSync() else {
            syncStatus = "请先选择共享文件夹"
            return
        }
        if isSyncing {
            deferredSyncContext = (drive, localMoodScores)
            return
        }

        isSyncing = true
        drive.beginSyncActivity()
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

        let accessed = folder.startAccessingSecurityScopedResource()
        guard accessed else {
            syncStatus = "共享文件夹授权失效，请重新选择 iCloud Drive 文件夹。"
            lastCaptureError = "本机事件仍已保留；重新授权后可继续同步。"
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            try importLegacyUserData(from: drive, localMoodScores: localMoodScores)
            let key = try loadOrCreateSyncKey()
            keyTransferCode = key.exportCode
            let coordinator = try RiverSyncCoordinator(
                store: database,
                directory: ReplicationDirectory(rootURL: folder),
                key: key
            )
            let report = try coordinator.synchronize()
            lanReplicator?.broadcast()
            syncReport = report
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
            database.refreshTimeline()
            stateRevision &+= 1
            publishMoodScores()
            if !report.integrityFailures.isEmpty {
                syncStatus = "同步对象校验失败：\(report.integrityFailures.count) 项"
            } else if report.needsProtocolUpgrade {
                syncStatus = "另一设备需要升级 River Diary"
            } else if report.isVerified {
                syncStatus = "已验证 · 所有登记设备状态一致"
            } else {
                syncStatus = "已复制本机变化，等待其他设备导入并确认"
            }
            lastCaptureError = nil
        } catch {
            syncStatus = "同步失败"
            lastCaptureError = error.localizedDescription
        }
    }

    func importLegacyUserData(from drive: ICloudDriveStore, localMoodScores: [String: Int]) throws {
        let snapshot: UserDataSnapshot?
        do {
            snapshot = try drive.readLegacyUserData()
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
            habitActionMessage = decision == "skip" ? "已跳过这张回顾卡；决定会随加密同步复制。" : "已保存你的回顾决定；会随加密同步复制到 Mac。"
        } catch {
            habitActionMessage = "回顾决定保存失败：\(error.localizedDescription)"
        }
    }

    func setSharedMemoryConfirmation(_ record: RiverSharedStateRecord, confirmed: Bool) {
        guard let database else { return }
        do {
            try database.setSharedMemoryConfirmation(for: record, confirmed: confirmed)
            stateRevision &+= 1
            habitActionMessage = confirmed ? "已确认这条共享记忆；决定会同步到 Mac。" : "已撤销这条记忆的确认；决定会同步到 Mac。"
        } catch {
            habitActionMessage = "记忆决定保存失败：\(error.localizedDescription)"
        }
    }

    func resolveSharedPendingConfirmation(_ record: RiverSharedStateRecord,
                                          as resolution: RiverPendingConfirmationResolution,
                                          correction: String? = nil) {
        guard let database else { return }
        do {
            try database.resolvePendingConfirmation(record, as: resolution, correction: correction)
            stateRevision &+= 1
            habitActionMessage = switch resolution {
            case .confirmed: "已确认；决定会通过加密同步传播。"
            case .rejected: "已标记为不正确；这条事项会通过加密同步关闭。"
            case .corrected: "已保存你的修改；决定会通过加密同步传播。"
            case .dismissed: "已关闭这条待确认事项。"
            }
        } catch {
            habitActionMessage = "待确认事项更新失败：\(error.localizedDescription)"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
