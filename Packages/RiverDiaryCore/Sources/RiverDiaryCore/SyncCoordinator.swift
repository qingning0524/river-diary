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
    func canonicalStateDigest() throws -> String
    func nextManifestStamp(after revision: UInt64, observing clock: HybridLogicalClock?) throws -> (revision: UInt64, clock: HybridLogicalClock)
    func lastPublishedManifestKey(for directoryID: String) throws -> String?
    func savePublishedManifestKey(_ key: String, for directoryID: String) throws
    func recordVerification(isVerified: Bool, digest: String) throws
}

public extension RiverSyncLocalStore {
    func sequenceGaps(expectedFrontiers: [String: StreamFrontier]) throws -> [SyncSequenceGap] { [] }
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
        var exported = 0
        var exportedOperations = 0
        var exportedArtifacts = 0
        var importedBatchCount = 0
        var importedOperationCount = 0
        var importedArtifactCount = 0
        var duplicates = 0
        var duplicateOperationCount = 0
        var ignored = 0
        var integrityFailures: [String] = []
        var needsUpgrade = false

        try store.rebuildDerivedState()
        let localEventBatches = try store.localEventBatches()
        let localOperationBatches = try store.localStateOperationBatches()
        let localArtifactRevisions = try store.localArtifactRevisions()
        let localEventsByID = Dictionary(uniqueKeysWithValues: localEventBatches.flatMap(\.events).map { ($0.id, $0) })
        let localOperationsByID = Dictionary(uniqueKeysWithValues: localOperationBatches.flatMap(\.operations).map { ($0.id, $0) })
        let localArtifactsByID = Dictionary(uniqueKeysWithValues: localArtifactRevisions.map { ($0.id, $0) })

        for batch in localEventBatches {
            try transport.publish(batch, objectID: batch.id, kind: "event_batch", stream: "Events")
            exported += 1
        }
        for batch in localOperationBatches {
            try transport.publish(batch, objectID: batch.id, kind: "state_operation_batch", stream: "Operations")
            exportedOperations += 1
        }
        for revision in localArtifactRevisions {
            try transport.publish(revision, objectID: revision.id, kind: "artifact_revision", stream: "Artifacts")
            exportedArtifacts += 1
        }

        let located = try transport.directory.scanFiles()
        var manifests: [ReplicationManifest] = []
        for file in located {
            let object = file.object
            if object.protocolVersion > 1 {
                needsUpgrade = true
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
                if batch.protocolVersion > 1 || batch.schemaVersion > 1 {
                    needsUpgrade = true
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
                if manifest.protocolVersion > 1 || manifest.schemaVersion > 1 {
                    needsUpgrade = true
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
                if batch.protocolVersion > 1 {
                    needsUpgrade = true
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
        try store.rebuildDerivedState()
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
            try transport.publish(localManifest, objectID: objectID, kind: "manifest", stream: "Manifest")
            try store.savePublishedManifestKey(stableKey, for: directoryID)
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

        return SyncRunReport(
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
