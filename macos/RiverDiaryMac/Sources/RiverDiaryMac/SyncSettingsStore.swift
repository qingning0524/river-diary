import AppKit
import Foundation
import RiverDiaryCore
import Security

struct RiverMacDiagnosticsReport: Codable {
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
    let exportedEventBatches: Int
    let exportedOperationBatches: Int
    let exportedArtifactRevisions: Int
    let importedEventBatches: Int
    let importedOperationBatches: Int
    let importedArtifactRevisions: Int
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

extension Notification.Name {
    static let riverCanonicalSyncDidChange = Notification.Name("river.canonicalSyncDidChange")
    static let riverLocalCanonicalStateDidChange = Notification.Name("river.localCanonicalStateDidChange")
}

@MainActor
final class SyncSettingsStore: ObservableObject {
    @Published private(set) var folderName: String?
    @Published private(set) var status = "未配置"
    @Published private(set) var transferCode: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var isVerified = false
    @Published private(set) var lastVerifiedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var devices: [DeviceRegistration] = []
    @Published private(set) var unresolvedDecisionConflicts = 0
    @Published private(set) var places: [RiverPlace] = []
    @Published private(set) var lastReport: SyncRunReport?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var lastSuccessfulExportAt: Date?
    @Published private(set) var lastImportAt: Date?
    @Published private(set) var diagnosticActionMessage: String?
    @Published private(set) var isLANReplicating = false
    @Published private(set) var lanSyncStatus = "局域网复制未启动"
    private var localStateObserver: NSObjectProtocol?
    private var lanReplicator: RiverLANReplicator?
    private var lanFolderURL: URL?
    private var deferredSyncRequested = false

    private let database: V2Store
    private let preferences: UserDefaults
    private var bookmark: Data?

    init(database: V2Store, preferences: UserDefaults = .standard) {
        self.database = database
        self.preferences = preferences
        bookmark = preferences.data(forKey: "river.sync.directory.bookmark.v1")
        if let bookmark, let resolved = try? SecurityScopedBookmark.resolve(bookmark) {
            folderName = resolved.url.lastPathComponent
            status = "已连接文件夹，等待同步"
        }
        refreshDevices()
        if preferences.bool(forKey: "river.lanReplication.enabled") {
            startLANReplication()
        }
        localStateObserver = NotificationCenter.default.addObserver(
            forName: .riverLocalCanonicalStateDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.markLocalStateChanged() }
        }
        if let deviceID = database.localDeviceIdentifier() {
            let prefix = "river.diagnostics.\(deviceID.rawValue)."
            func date(_ key: String) -> Date? {
                let value = preferences.double(forKey: prefix + key)
                return value > 0 ? Date(timeIntervalSince1970: value) : nil
            }
            lastSuccessfulExportAt = date("lastExport")
            lastImportAt = date("lastImport")
            lastRunAt = date("lastReconciliation")
            lastVerifiedAt = date("lastVerified")
        }
    }

    deinit {
        if let localStateObserver { NotificationCenter.default.removeObserver(localStateObserver) }
        lanReplicator?.stop()
        lanFolderURL?.stopAccessingSecurityScopedResource()
    }

    var hasKey: Bool { RiverSecureStore.hasSyncKey() }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 River Diary 的 iCloud Drive 文件夹"
        panel.message = "在 iCloud Drive 中选择或新建 River Diary 文件夹，并在 iPhone 上选择同一个文件夹。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in self?.saveFolderBookmark(url) }
        }
    }

    func revealOrCreateKey() {
        do {
            let key: SyncEncryptionKey
            do {
                key = try RiverSecureStore.loadSyncKey()
            } catch SecureStoreError.keychainStatus(errSecItemNotFound) {
                key = SyncEncryptionKey()
                try RiverSecureStore.saveSyncKey(key)
            }
            transferCode = key.exportCode
            lastError = nil
            status = "密钥已保存在本机钥匙串；请把同一密钥导入 iPhone。"
            if preferences.bool(forKey: "river.lanReplication.enabled") { startLANReplication() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importKey(_ code: String) {
        do {
            let key = try RiverSecureStore.importSyncKey(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            transferCode = key.exportCode
            lastError = nil
            status = "同步密钥已导入"
            if preferences.bool(forKey: "river.lanReplication.enabled") { startLANReplication() }
        } catch {
            lastError = "同步密钥无效：\(error.localizedDescription)"
        }
    }

    func synchronize() {
        if isSyncing {
            deferredSyncRequested = true
            return
        }
        guard let bookmark else {
            status = "请先选择 iCloud Drive 文件夹"
            return
        }
        guard database.localDeviceIdentifier() != nil else {
            status = "本机设备身份不可用"
            lastError = database.lastError
            return
        }
        do {
            let resolved = try SecurityScopedBookmark.resolve(bookmark)
            let folder = resolved.url
            if resolved.isStale { saveFolderBookmark(folder) }
            let hasAccess = folder.startAccessingSecurityScopedResource()
            defer { if hasAccess { folder.stopAccessingSecurityScopedResource() } }
            guard hasAccess else { throw RiverSyncStoreError.persistence("共享文件夹授权已失效，请重新选择该文件夹。") }
            isSyncing = true
            isVerified = false
            defer {
                isSyncing = false
                if deferredSyncRequested {
                    deferredSyncRequested = false
                    Task { @MainActor [weak self] in
                        await Task.yield()
                        self?.synchronize()
                    }
                }
            }
            let key: SyncEncryptionKey
            do {
                key = try RiverSecureStore.loadSyncKey()
            } catch SecureStoreError.keychainStatus(errSecItemNotFound) {
                key = SyncEncryptionKey()
                try RiverSecureStore.saveSyncKey(key)
                transferCode = key.exportCode
            }
            let coordinator = try RiverSyncCoordinator(
                store: database,
                directory: ReplicationDirectory(rootURL: folder),
                key: key
            )
            let report = try coordinator.synchronize()
            lanReplicator?.broadcast()
            lastReport = report
            let syncDate = Date()
            lastRunAt = syncDate
            lastSuccessfulExportAt = syncDate
            if let deviceID = database.localDeviceIdentifier() {
                let prefix = "river.diagnostics.\(deviceID.rawValue)."
                preferences.set(syncDate.timeIntervalSince1970, forKey: prefix + "lastExport")
                preferences.set(syncDate.timeIntervalSince1970, forKey: prefix + "lastReconciliation")
            }
            if report.importedEventBatches + report.importedOperationBatches + report.importedArtifactRevisions > 0 {
                lastImportAt = syncDate
                if let deviceID = database.localDeviceIdentifier() {
                    preferences.set(syncDate.timeIntervalSince1970, forKey: "river.diagnostics.\(deviceID.rawValue).lastImport")
                }
            }
            if report.isVerified {
                lastVerifiedAt = syncDate
                if let deviceID = database.localDeviceIdentifier() {
                    preferences.set(syncDate.timeIntervalSince1970, forKey: "river.diagnostics.\(deviceID.rawValue).lastVerified")
                }
            }
            refreshDevices()
            NotificationCenter.default.post(name: .riverCanonicalSyncDidChange, object: report)
            if !report.integrityFailures.isEmpty {
                status = "同步对象校验失败：\(report.integrityFailures.count) 项"
                lastError = report.integrityFailures.joined(separator: "\n")
            } else if report.needsProtocolUpgrade {
                status = "另一设备需要升级 River Diary"
                lastError = nil
            } else if report.isVerified {
                status = "已验证 · 所有登记设备状态一致"
                lastVerifiedAt = Date()
                isVerified = true
                lastError = nil
            } else {
                status = "本机变化已复制，等待其他设备导入并确认"
                lastError = nil
            }
        } catch {
            status = "同步失败"
            lastError = error.localizedDescription
        }
    }

    func setLANReplicationEnabled(_ enabled: Bool) {
        preferences.set(enabled, forKey: "river.lanReplication.enabled")
        if enabled { startLANReplication() }
        else { stopLANReplication() }
    }

    func startLANReplication() {
        guard let bookmark,
              database.localDeviceIdentifier() != nil else {
            lanSyncStatus = "先连接共享复制文件夹并登记本机设备"
            return
        }
        do {
            let resolved = try SecurityScopedBookmark.resolve(bookmark)
            let folder = resolved.url
            if resolved.isStale {
                self.bookmark = try SecurityScopedBookmark.create(for: folder)
                preferences.set(self.bookmark, forKey: "river.sync.directory.bookmark.v1")
            }
            if isLANReplicating, lanFolderURL == folder { return }
            stopLANReplication()
            guard folder.startAccessingSecurityScopedResource() else {
                lanSyncStatus = "复制文件夹授权失效；重新选择文件夹后再启用局域网复制"
                return
            }
            let key: SyncEncryptionKey
            do { key = try RiverSecureStore.loadSyncKey() }
            catch {
                folder.stopAccessingSecurityScopedResource()
                throw error
            }
            guard let deviceID = database.localDeviceIdentifier() else {
                folder.stopAccessingSecurityScopedResource()
                lanSyncStatus = "本机设备身份不可用"
                return
            }
            let replicator = RiverLANReplicator(
                deviceID: deviceID,
                directory: ReplicationDirectory(rootURL: folder),
                key: key
            )
            replicator.onStatusChange = { [weak self] value in
                Task { @MainActor [weak self] in self?.lanSyncStatus = value }
            }
            replicator.onObjectsReceived = { [weak self] in
                Task { @MainActor [weak self] in self?.synchronize() }
            }
            lanFolderURL = folder
            lanReplicator = replicator
            isLANReplicating = true
            lanSyncStatus = "正在查找同一 River Diary 的局域网设备"
            replicator.start()
            synchronize()
        } catch {
            lanSyncStatus = "局域网复制未启动：\(error.localizedDescription)"
        }
    }

    func stopLANReplication() {
        lanReplicator?.stop()
        lanReplicator = nil
        if let lanFolderURL { lanFolderURL.stopAccessingSecurityScopedResource() }
        lanFolderURL = nil
        isLANReplicating = false
        lanSyncStatus = preferences.bool(forKey: "river.lanReplication.enabled")
            ? "等待局域网复制重新连接"
            : "局域网复制未启动"
    }

    var localDeviceID: RiverDeviceID? { database.localDeviceIdentifier() }

    func refreshDevices() {
        devices = (try? DeviceRegistry.merge(database.allDeviceRegistrations())) ?? []
        unresolvedDecisionConflicts = database.stateOperationResolution().conflicts.count
        places = database.places()
    }

    func retireDevice(_ id: RiverDeviceID) {
        guard database.retireDevice(id) else {
            lastError = database.lastError ?? "无法退役设备"
            return
        }
        refreshDevices()
        status = "设备已标记退役；状态会随下一次同步传播。"
        isVerified = false
    }

    func savePlaceDecision(_ place: RiverPlace, name: String, semanticType: String) {
        guard let payload = try? JSONEncoder().encode(RiverPlaceUserDecision(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            semanticType: semanticType.trimmingCharacters(in: .whitespacesAndNewlines),
            isConfirmed: true
        )),
        database.appendStateOperation(
            targetID: place.id,
            fieldKey: "identity",
            operationType: "place.identity.set",
            payload: payload
        ) != nil else {
            lastError = database.lastError ?? "地点确认无法保存"
            return
        }
        guard database.rebuildPlaces() else {
            lastError = database.lastError ?? "地点投影重建失败"
            return
        }
        refreshDevices()
        isVerified = false
        status = "地点决定已保存；会随下次同步传播。"
    }

    func runDiagnosticSyncAction(_ label: String) {
        diagnosticActionMessage = "\(label)会运行完整复制、扫描、导入、重建和完整性核对流程。"
        synchronize()
        if let report = lastReport {
            diagnosticActionMessage = "\(label)已执行完整同步流程：导出 Event \(report.exportedEventBatches) 批、Operation \(report.exportedOperationBatches) 批、Artifact \(report.exportedArtifactRevisions) 个；导入 Event \(report.importedEventBatches) 批、Operation \(report.importedOperationBatches) 批、Artifact \(report.importedArtifactRevisions) 个；\(report.isVerified ? "已验证" : "等待收敛")."
        }
    }

    func setDiagnosticActionMessage(_ message: String) {
        diagnosticActionMessage = message
    }

    private func markLocalStateChanged() {
        if isSyncing { return }
        if let lastReport, (try? database.canonicalStateDigest()) == lastReport.canonicalStateDigest { return }
        isVerified = false
        status = "本机数据或用户决定已更新，等待同步核对"
    }

    func invalidateArtifactsForDiagnostics() {
        let count = database.invalidateGeneratedArtifactsForDiagnostics()
        diagnosticActionMessage = count == 0 ? "没有需要失效的 AI Artifact。" : "已追加失效操作：\(count) 个生成结果需要重新分析。"
        isVerified = false
        refreshDevices()
    }

    func rebuildDiagnosticProjections(activity: ActivityStore) {
        do {
            let sessionCount = try activity.rebuildDiagnosticProjections()
            diagnosticActionMessage = "已重建地点和 Artifact 状态，并重新计算 \(sessionCount) 个会话；Timeline 已通知刷新。"
            refreshDevices()
        } catch {
            diagnosticActionMessage = "重建失败：\(error.localizedDescription)"
        }
    }

    func makeDiagnosticsReport(activity: ActivityStore) -> Data? {
        guard let deviceID = database.localDeviceIdentifier(),
              let frontier = try? database.ownedFrontier(),
              let digest = try? database.canonicalStateDigest() else { return nil }
        let events = database.allRawEvents()
        let artifacts = database.localArtifactRevisions()
        let canonical = database.canonicalArtifactRevisions()
        let latestLocation = events.filter { $0.source == .location }.max { $0.timestamp < $1.timestamp }
        let geocoded = events.filter { $0.source == .location && $0.payload.mapProvider != nil }
            .max { $0.recordedAt < $1.recordedAt }
        let latestIntent = events.filter { $0.persistedSource == "shortcuts" }.max { $0.recordedAt < $1.recordedAt }
        let latestJob = database.latestAnalysisJob()
        let sessionCount = SessionBuilder.build(events.compactMap { $0.replica() }).count
        let pendingHabitCount = database.habitCardRows().filter { $0.status == "bundled" || $0.status == "shown" }.count
        let pendingMemoryCount = database.memories().filter { database.memoryConfirmation(for: $0.id)?.confirmed != true }.count
        let pendingGenericCount = database.sharedUserRecords().filter {
            $0.kind == .pendingConfirmation && $0.status == "pending"
        }.count
        let report = RiverMacDiagnosticsReport(
            generatedAt: Date(),
            deviceID: deviceID.rawValue,
            databaseSchemaVersion: database.databaseSchemaVersion,
            eventCount: database.countRows(in: .rawEvents),
            sessionCount: sessionCount,
            placeCount: database.places().count,
            stateOperationCount: database.countRows(in: .stateOperations),
            artifactCount: artifacts.count,
            canonicalArtifactCount: canonical.count,
            staleArtifactCount: database.staleArtifactRevisionCount(),
            pendingConfirmationStatus: "习惯卡 \(pendingHabitCount) 张、记忆 \(pendingMemoryCount) 条、地点/时间线 \(pendingGenericCount) 条待确认",
            importedObjectCount: database.countRows(in: .syncImports),
            exportedEventBatches: lastReport?.exportedEventBatches ?? 0,
            exportedOperationBatches: lastReport?.exportedOperationBatches ?? 0,
            exportedArtifactRevisions: lastReport?.exportedArtifactRevisions ?? 0,
            importedEventBatches: lastReport?.importedEventBatches ?? 0,
            importedOperationBatches: lastReport?.importedOperationBatches ?? 0,
            importedArtifactRevisions: lastReport?.importedArtifactRevisions ?? 0,
            eventFrontier: frontier.events,
            operationFrontier: frontier.operations,
            selectedDirectory: folderName ?? "未选择",
            bookmarkStatus: bookmark == nil ? "未配置" : (lastError == nil ? "已保存；同步时重新验证" : "授权失效或同步错误"),
            lanReplicationStatus: isLANReplicating ? lanSyncStatus : "未启用",
            lastSuccessfulExportAt: lastSuccessfulExportAt,
            lastImportAt: lastImportAt,
            lastReconciliationAt: lastRunAt,
            lastVerifiedAt: lastVerifiedAt,
            canonicalDigest: digest,
            missingSequenceDevices: (lastReport?.sequenceGapDevices ?? []).map(\.rawValue),
            missingSequenceRanges: (lastReport?.missingSequenceGaps ?? []).map {
                "\($0.deviceID.rawValue)/\($0.stream): \($0.first)-\($0.last)"
            },
            integrityFailures: lastReport?.integrityFailures ?? [],
            locationAuthorization: "Mac 位置采集器尚未实现",
            lastLocationEventAt: latestLocation?.timestamp,
            lastGeocodeAt: geocoded?.recordedAt,
            mapCandidateRecords: events.filter { $0.source == .location && $0.payload.mapProvider != nil }.count,
            lastAppActivityIntentAt: latestIntent?.recordedAt,
            analysisJobStatus: latestJob.map { "\($0.status.rawValue) · \($0.logicalKey) · attempt \($0.attempt)" } ?? "暂无已记录任务"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(report)
    }

    private func saveFolderBookmark(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try SecurityScopedBookmark.create(for: url)
            bookmark = data
            preferences.set(data, forKey: "river.sync.directory.bookmark.v1")
            folderName = url.lastPathComponent
            lastError = nil
            status = "已连接文件夹，等待同步"
            if preferences.bool(forKey: "river.lanReplication.enabled") { startLANReplication() }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
