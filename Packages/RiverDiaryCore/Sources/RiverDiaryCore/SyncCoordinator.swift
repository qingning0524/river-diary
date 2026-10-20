import CryptoKit
import Foundation

@MainActor
public protocol RiverSyncLocalStore: AnyObject {
    var syncDeviceID: RiverDeviceID? { get }
    func localEventBatches() throws -> [RiverEventBatch]
    func localStateOperationBatches() throws -> [StateOperationBatch]
    func localArtifactRevisions() throws -> [RiverArtifactRevision]
    func importEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool
    func importStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool
    func importArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool
    func restoreOwnedEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool
    func restoreOwnedStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool
    func restoreOwnedArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool
    func importedObjectExists(_ objectID: String) throws -> Bool
    func ownedFrontier() throws -> StreamFrontier
    func importedFrontiers(for deviceIDs: Set<RiverDeviceID>) throws -> [String: StreamFrontier]
    func sequenceGapDevices(expectedFrontiers: [String: StreamFrontier]) throws -> Set<RiverDeviceID>
    func sequenceGaps(expectedFrontiers: [String: StreamFrontier]) throws -> [SyncSequenceGap]
    func allDeviceRegistrations() throws -> [DeviceRegistration]
    func mergeDeviceRegistrations(_ registrations: [DeviceRegistration]) throws
    func reconcileDeviceRegistryFromOperations() throws
    func rebuildDerivedState() throws
    func reconcileDerivedStateIfNeeded() throws
    func canonicalStateDigest() throws -> String
    func nextManifestStamp(after revision: UInt64, observing clock: HybridLogicalClock?) throws -> (revision: UInt64, clock: HybridLogicalClock)
    func lastPublishedManifestKey(for directoryID: String) throws -> String?
    func savePublishedManifestKey(_ key: String, for directoryID: String) throws
    func recordVerification(isVerified: Bool, digest: String) throws
}

public extension RiverSyncLocalStore {
    func sequenceGaps(expectedFrontiers: [String: StreamFrontier]) throws -> [SyncSequenceGap] { [] }
    func reconcileDerivedStateIfNeeded() throws { try rebuildDerivedState() }
}

public enum RiverSyncCoordinatorError: Error, Equatable {
    case deviceIdentityUnavailable
}

public enum RiverSyncStoreError: Error, Equatable {
    case persistence(String)
}

public struct SyncRunReport: Sendable {
    public let exportedEventBatches: Int
    public let exportedOperationBatches: Int
    public let exportedArtifactRevisions: Int
    public let importedEventBatches: Int
    public let importedOperationBatches: Int
    public let importedArtifactRevisions: Int
    public let duplicateEventBatches: Int
    public let duplicateOperationBatches: Int
    public let ignoredUnknownObjects: Int
    public let integrityFailures: [String]
    public let sequenceGapDevices: [RiverDeviceID]
    public let missingSequenceGaps: [SyncSequenceGap]
    public let needsProtocolUpgrade: Bool
    public let isVerified: Bool
    public let canonicalStateDigest: String

    public init(exportedEventBatches: Int, exportedOperationBatches: Int,
                importedEventBatches: Int, importedOperationBatches: Int,
                exportedArtifactRevisions: Int, importedArtifactRevisions: Int,
                duplicateEventBatches: Int, duplicateOperationBatches: Int,
                ignoredUnknownObjects: Int, integrityFailures: [String], sequenceGapDevices: [RiverDeviceID] = [], missingSequenceGaps: [SyncSequenceGap] = [], needsProtocolUpgrade: Bool,
                isVerified: Bool, canonicalStateDigest: String) {
        self.exportedEventBatches = exportedEventBatches
        self.exportedOperationBatches = exportedOperationBatches
        self.exportedArtifactRevisions = exportedArtifactRevisions
        self.importedEventBatches = importedEventBatches
        self.importedOperationBatches = importedOperationBatches
        self.importedArtifactRevisions = importedArtifactRevisions
        self.duplicateEventBatches = duplicateEventBatches
        self.duplicateOperationBatches = duplicateOperationBatches
        self.ignoredUnknownObjects = ignoredUnknownObjects
        self.integrityFailures = integrityFailures
        self.sequenceGapDevices = sequenceGapDevices.sorted { $0.rawValue < $1.rawValue }
        self.missingSequenceGaps = missingSequenceGaps.sorted {
            if $0.deviceID != $1.deviceID { return $0.deviceID.rawValue < $1.deviceID.rawValue }
            if $0.stream != $1.stream { return $0.stream < $1.stream }
            return $0.first < $1.first
        }
        self.needsProtocolUpgrade = needsProtocolUpgrade
        self.isVerified = isVerified
        self.canonicalStateDigest = canonicalStateDigest
    }
}

public struct SyncSequenceGap: Codable, Hashable, Sendable, Identifiable {
    public let deviceID: RiverDeviceID
    public let stream: String
    public let first: UInt64
    public let last: UInt64

    public var id: String { "\(deviceID.rawValue):\(stream):\(first)-\(last)" }

    public init(deviceID: RiverDeviceID, stream: String, first: UInt64, last: UInt64) {
        self.deviceID = deviceID
        self.stream = stream
        self.first = first
        self.last = last
    }
}

private struct SyncLocalSnapshot: Sendable {
    let eventBatches: [RiverEventBatch]
    let operationBatches: [StateOperationBatch]
    let artifactRevisions: [RiverArtifactRevision]
    let eventsByID: [UUID: RiverEvent]
    let operationsByID: [UUID: StateOperation]
    let artifactsByID: [String: RiverArtifactRevision]
}

private struct SyncPublishCounts: Sendable {
    let eventBatches: Int
    let operationBatches: Int
    let artifactRevisions: Int
}

private struct SyncFileExchange: Sendable {
    let counts: SyncPublishCounts
    let located: [LocatedEncryptedReplicationObject]
}

private struct PendingManifestPublication: Sendable {
    let manifest: ReplicationManifest
    let objectID: String
    let stableKey: String
}

private struct SyncExecutionResult {
    let report: SyncRunReport
    let pendingManifest: PendingManifestPublication?
}

private func publishLocalReplicationObjects(
    _ snapshot: SyncLocalSnapshot,
    using transport: EncryptedFileReplication
) throws -> SyncPublishCounts {
    for batch in snapshot.eventBatches {
        try transport.publish(batch, objectID: batch.id, kind: "event_batch", stream: "Events")
    }
    for batch in snapshot.operationBatches {
        try transport.publish(batch, objectID: batch.id, kind: "state_operation_batch", stream: "Operations")
    }
    for revision in snapshot.artifactRevisions {
        try transport.publish(revision, objectID: revision.id, kind: "artifact_revision", stream: "Artifacts")
    }
    return SyncPublishCounts(
        eventBatches: snapshot.eventBatches.count,
        operationBatches: snapshot.operationBatches.count,
        artifactRevisions: snapshot.artifactRevisions.count
    )
}

@MainActor
public final class RiverSyncCoordinator {
    private let store: any RiverSyncLocalStore
    private let transport: EncryptedFileReplication
    private let key: SyncEncryptionKey
    private let deviceID: RiverDeviceID
    private let directoryID: String

    public init(store: any RiverSyncLocalStore, directory: ReplicationDirectory, key: SyncEncryptionKey) throws {
        guard let deviceID = store.syncDeviceID else { throw RiverSyncCoordinatorError.deviceIdentityUnavailable }
        self.store = store
        self.deviceID = deviceID
        self.key = key
        self.transport = EncryptedFileReplication(deviceID: deviceID, directory: directory, key: key)
        self.directoryID = SHA256.hash(data: Data(directory.rootURL.standardizedFileURL.path.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    public func synchronize() throws -> SyncRunReport {
        let snapshot = try makeLocalSnapshot()
        let counts = try publishLocalReplicationObjects(snapshot, using: transport)
        let located = try transport.directory.scanFiles()
        let result = try process(snapshot: snapshot, counts: counts, located: located)
        if let publication = result.pendingManifest {
            try transport.publish(publication.manifest, objectID: publication.objectID, kind: "manifest", stream: "Manifest")
            try store.savePublishedManifestKey(publication.stableKey, for: directoryID)
        }
        return result.report
    }

    /// Keeps coordinated iCloud File Provider access off the main actor.
    public func synchronizeAsynchronously() async throws -> SyncRunReport {
        let snapshot = try makeLocalSnapshot()
        let transport = self.transport
        let exchange = try await Task.detached(priority: .utility) {
            let counts = try publishLocalReplicationObjects(snapshot, using: transport)
            let located = try transport.directory.scanFiles()
            return SyncFileExchange(counts: counts, located: located)
        }.value
        let result = try process(snapshot: snapshot, counts: exchange.counts, located: exchange.located)
        if let publication = result.pendingManifest {
            _ = try await Task.detached(priority: .utility) {
                try transport.publish(publication.manifest, objectID: publication.objectID, kind: "manifest", stream: "Manifest")
            }.value
            try store.savePublishedManifestKey(publication.stableKey, for: directoryID)
        }
        return result.report
    }

    private func makeLocalSnapshot() throws -> SyncLocalSnapshot {
        try store.reconcileDerivedStateIfNeeded()
        let events = try store.localEventBatches()
        let operations = try store.localStateOperationBatches()
        let artifacts = try store.localArtifactRevisions()
        return SyncLocalSnapshot(
            eventBatches: events,
            operationBatches: operations,
            artifactRevisions: artifacts,
            eventsByID: Dictionary(uniqueKeysWithValues: events.flatMap(\.events).map { ($0.id, $0) }),
            operationsByID: Dictionary(uniqueKeysWithValues: operations.flatMap(\.operations).map { ($0.id, $0) }),
            artifactsByID: Dictionary(uniqueKeysWithValues: artifacts.map { ($0.id, $0) })
        )
    }

    private func process(
        snapshot: SyncLocalSnapshot,
        counts: SyncPublishCounts,
        located: [LocatedEncryptedReplicationObject]
    ) throws -> SyncExecutionResult {
        let exported = counts.eventBatches
        let exportedOperations = counts.operationBatches
        let exportedArtifacts = counts.artifactRevisions
        let localEventsByID = snapshot.eventsByID
        let localOperationsByID = snapshot.operationsByID
        let localArtifactsByID = snapshot.artifactsByID
        var importedBatchCount = 0
        var importedOperationCount = 0
        var importedArtifactCount = 0
        var duplicates = 0
        var duplicateOperationCount = 0
        var ignored = 0
        var integrityFailures: [String] = []
        var needsUpgrade = false
        var pendingManifest: PendingManifestPublication?
        var manifests: [ReplicationManifest] = []
        for file in located {
            let object = file.object
            if object.protocolVersion > EncryptedReplicationObject.currentProtocolVersion {
                needsUpgrade = true
                continue
            }
            if object.protocolVersion < EncryptedReplicationObject.minimumCompatibleProtocolVersion {
                integrityFailures.append("\(file.deviceID.rawValue)/\(file.stream)/\(object.id)：复制对象协议版本无效")
                continue
            }
            let plaintext: Data
            do {
                plaintext = try object.open(using: key)
            } catch {
                integrityFailures.append("\(file.deviceID.rawValue)/\(file.stream)/\(object.id)：\(error.localizedDescription)")
                continue
            }
            switch object.kind {
            case "event_batch":
                guard file.stream == "Events",
                      let batch = try? JSONDecoder().decode(RiverEventBatch.self, from: plaintext),
                      batch.deviceID == file.deviceID,
                      batch.id == object.id else {
                    integrityFailures.append("\(object.id)：事件批次结构或所属设备不匹配")
                    continue
                }
                if batch.protocolVersion > EncryptedReplicationObject.currentProtocolVersion || batch.schemaVersion > 1 {
                    needsUpgrade = true
                    continue
                }
                if batch.protocolVersion < EncryptedReplicationObject.minimumCompatibleProtocolVersion || batch.schemaVersion < 1 {
                    integrityFailures.append("\(object.id)：事件批次协议或 Schema 版本无效")
                    continue
                }
                if try store.importedObjectExists(object.id) {
                    duplicates += 1
                    continue
                }
                if batch.deviceID == deviceID {
                    let conflicting = batch.events.first { event in
                        localEventsByID[event.id].map { $0 != event } ?? false
                    }
                    if let conflicting {
                        integrityFailures.append("\(object.id)：本机 Event ID 对应了不同内容 \(conflicting.id)")
                        continue
                    }
                    let fullyPresent = batch.events.allSatisfy { localEventsByID[$0.id] == $0 }
                    if fullyPresent, try store.ownedFrontier().events >= batch.lastSequence { continue }
                }
                let imported = batch.deviceID == deviceID
                    ? try store.restoreOwnedEventBatch(batch, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                    : try store.importEventBatch(batch, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                if imported {
                    importedBatchCount += 1
                } else {
                    integrityFailures.append("\(object.id)：事件批次事务导入失败")
                }
            case "manifest":
                guard file.stream == "Manifest",
                      let manifest = try? JSONDecoder().decode(ReplicationManifest.self, from: plaintext),
                      manifest.deviceID == file.deviceID,
                      object.id == "manifest_\(manifest.deviceID.rawValue)_\(manifest.revision)" else {
                    integrityFailures.append("\(object.id)：Manifest 结构或所属设备不匹配")
                    continue
                }
                if manifest.protocolVersion > EncryptedReplicationObject.currentProtocolVersion || manifest.schemaVersion > 1 {
                    needsUpgrade = true
                    continue
                }
                if manifest.protocolVersion < EncryptedReplicationObject.minimumCompatibleProtocolVersion || manifest.schemaVersion < 1 {
                    integrityFailures.append("\(object.id)：Manifest 协议或 Schema 版本无效")
                    continue
                }
                manifests.append(manifest)
            case "state_operation_batch":
                guard file.stream == "Operations",
                      let batch = try? JSONDecoder().decode(StateOperationBatch.self, from: plaintext),
                      batch.deviceID == file.deviceID,
                      batch.id == object.id else {
                    integrityFailures.append("\(object.id)：用户状态批次结构或所属设备不匹配")
                    continue
                }
                if batch.protocolVersion > EncryptedReplicationObject.currentProtocolVersion {
                    needsUpgrade = true
                    continue
                }
                if batch.protocolVersion < EncryptedReplicationObject.minimumCompatibleProtocolVersion {
                    integrityFailures.append("\(object.id)：Operation 批次协议版本无效")
                    continue
                }
                if try store.importedObjectExists(object.id) {
                    duplicateOperationCount += 1
                    continue
                }
                if batch.deviceID == deviceID {
                    let conflicting = batch.operations.first { operation in
                        localOperationsByID[operation.id].map { $0 != operation } ?? false
                    }
                    if let conflicting {
                        integrityFailures.append("\(object.id)：本机 Operation ID 对应了不同内容 \(conflicting.id)")
                        continue
                    }
                    let fullyPresent = batch.operations.allSatisfy { localOperationsByID[$0.id] == $0 }
                    if fullyPresent, try store.ownedFrontier().operations >= batch.lastSequence { continue }
                }
                let imported = batch.deviceID == deviceID
                    ? try store.restoreOwnedStateOperationBatch(batch, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                    : try store.importStateOperationBatch(batch, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                if imported {
                    importedOperationCount += 1
                    try store.reconcileDeviceRegistryFromOperations()
                } else {
                    integrityFailures.append("\(object.id)：用户状态批次事务导入失败")
                }
            case "artifact_revision":
                guard file.stream == "Artifacts",
                      let revision = try? JSONDecoder().decode(RiverArtifactRevision.self, from: plaintext),
                      revision.originDeviceID == file.deviceID,
                      revision.id == object.id else {
                    integrityFailures.append("\(object.id)：Artifact 修订结构或所属设备不匹配")
                    continue
                }
                if try store.importedObjectExists(object.id) {
                    continue
                }
                if revision.originDeviceID == deviceID, let existing = localArtifactsByID[revision.id] {
                    if existing != revision {
                        integrityFailures.append("\(object.id)：本机 Artifact ID 对应了不同修订内容")
                    }
                    continue
                }
                let imported = revision.originDeviceID == deviceID
                    ? try store.restoreOwnedArtifactRevision(revision, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                    : try store.importArtifactRevision(revision, objectID: object.id, ciphertextHash: object.ciphertextSHA256)
                if imported {
                    importedArtifactCount += 1
                }
            default:
                // Future object kinds are retained in the directory and left
                // untouched so an older app never deletes data it cannot read.
                ignored += 1
            }
        }

        try store.reconcileDeviceRegistryFromOperations()
        try store.reconcileDerivedStateIfNeeded()
        let latestManifests = ManifestResolver.latestByDevice(manifests)
        let knownDevices = latestManifests.values.flatMap(\.knownDevices)
        let knownIDs = Set(knownDevices.map(\.id))
        let discoveredDevices = latestManifests.values.filter { !knownIDs.contains($0.deviceID) }.map { manifest in
                DeviceRegistration(
                    id: manifest.deviceID,
                    displayName: manifest.deviceID.rawValue,
                    platform: "unknown",
                    lifecycle: .active,
                    clock: manifest.clock
                )
            }
        try store.mergeDeviceRegistrations(knownDevices + discoveredDevices)

        let registrations = DeviceRegistry.merge(try store.allDeviceRegistrations())
        guard registrations.first(where: { $0.id == deviceID })?.lifecycle == .active else {
            throw RiverSyncStoreError.persistence("这台设备已被另一 River Node 退役；请重新登记后再同步。")
        }
        let activeIDs = Set(registrations.filter { $0.lifecycle == .active }.map(\.id))
        let importedFrontiers = try store.importedFrontiers(for: activeIDs)
        let owned = try store.ownedFrontier()
        let digest = try store.canonicalStateDigest()
        let priorOwnManifest = latestManifests[deviceID]
        let stamp = try store.nextManifestStamp(
            after: priorOwnManifest?.revision ?? 0,
            observing: priorOwnManifest?.clock
        )
        let stableKey = Self.manifestKey(deviceID: deviceID, owned: owned,
                                         imported: importedFrontiers, registrations: registrations, digest: digest)
        let priorKey = try store.lastPublishedManifestKey(for: directoryID)
        let localManifest = ReplicationManifest(
            deviceID: deviceID,
            revision: stamp.revision,
            clock: stamp.clock,
            ownedFrontier: owned,
            importedFrontiers: importedFrontiers,
            knownDevices: registrations,
            canonicalStateDigest: digest
        )
        if stableKey != priorKey {
            let objectID = "manifest_\(deviceID.rawValue)_\(stamp.revision)"
            pendingManifest = PendingManifestPublication(manifest: localManifest, objectID: objectID, stableKey: stableKey)
        }

        let allManifests = Array(latestManifests.values.filter { $0.deviceID != deviceID }) + [localManifest]
        let latest = ManifestResolver.latestByDevice(allManifests)
        let expected = Set(registrations.filter { $0.lifecycle == .active }.map(\.id))
        var expectedFrontiers = Dictionary(uniqueKeysWithValues: latest.values.map {
            ($0.deviceID.rawValue, $0.ownedFrontier)
        })
        expectedFrontiers[deviceID.rawValue] = owned
        let gaps = try store.sequenceGapDevices(expectedFrontiers: expectedFrontiers)
        let missingSequenceGaps = try store.sequenceGaps(expectedFrontiers: expectedFrontiers)
        let verified = !needsUpgrade && integrityFailures.isEmpty
            && ignored == 0 && gaps.isEmpty
            && SyncVerification.isVerified(manifests: Array(latest.values), activeDeviceIDs: expected,
                                           devicesWithSequenceGaps: gaps)
        try store.recordVerification(isVerified: verified, digest: digest)

        let report = SyncRunReport(
            exportedEventBatches: exported,
            exportedOperationBatches: exportedOperations,
            importedEventBatches: importedBatchCount,
            importedOperationBatches: importedOperationCount,
            exportedArtifactRevisions: exportedArtifacts,
            importedArtifactRevisions: importedArtifactCount,
            duplicateEventBatches: duplicates,
            duplicateOperationBatches: duplicateOperationCount,
            ignoredUnknownObjects: ignored,
            integrityFailures: integrityFailures,
            sequenceGapDevices: Array(gaps),
            missingSequenceGaps: missingSequenceGaps,
            needsProtocolUpgrade: needsUpgrade,
            isVerified: verified,
            canonicalStateDigest: digest
        )
        return SyncExecutionResult(report: report, pendingManifest: pendingManifest)
    }

    private static func manifestKey(deviceID: RiverDeviceID, owned: StreamFrontier,
                                    imported: [String: StreamFrontier], registrations: [DeviceRegistration],
                                    digest: String) -> String {
        let peerText = imported.keys.sorted().map {
            "\($0)=\(imported[$0]?.events ?? 0),\(imported[$0]?.operations ?? 0)"
        }.joined(separator: ";")
        let deviceText = registrations.map {
            "\($0.id.rawValue)=\($0.lifecycle.rawValue)=\($0.clock.physicalMilliseconds):\($0.clock.logicalCounter)"
        }.joined(separator: ";")
        let raw = "\(deviceID.rawValue)|\(owned.events)|\(owned.operations)|\(peerText)|\(deviceText)|\(digest)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
