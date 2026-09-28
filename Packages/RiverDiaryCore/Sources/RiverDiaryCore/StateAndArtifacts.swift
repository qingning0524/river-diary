import Foundation

public struct HybridLogicalClock: Codable, Hashable, Sendable, Comparable {
    public let physicalMilliseconds: UInt64
    public let logicalCounter: UInt32
    public let deviceID: RiverDeviceID

    public init(physicalMilliseconds: UInt64, logicalCounter: UInt32 = 0, deviceID: RiverDeviceID) {
        self.physicalMilliseconds = physicalMilliseconds
        self.logicalCounter = logicalCounter
        self.deviceID = deviceID
    }

    public static func < (lhs: HybridLogicalClock, rhs: HybridLogicalClock) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logicalCounter != rhs.logicalCounter {
            return lhs.logicalCounter < rhs.logicalCounter
        }
        return lhs.deviceID.rawValue < rhs.deviceID.rawValue
    }

    public mutating func tick(wallTimeMilliseconds: UInt64) {
        if wallTimeMilliseconds > physicalMilliseconds {
            self = HybridLogicalClock(physicalMilliseconds: wallTimeMilliseconds, deviceID: deviceID)
        } else {
            self = HybridLogicalClock(
                physicalMilliseconds: physicalMilliseconds,
                logicalCounter: logicalCounter &+ 1,
                deviceID: deviceID
            )
        }
    }

    public mutating func observe(_ remote: HybridLogicalClock, wallTimeMilliseconds: UInt64) {
        let maximum = max(wallTimeMilliseconds, physicalMilliseconds, remote.physicalMilliseconds)
        let nextCounter: UInt32
        if maximum == physicalMilliseconds && maximum == remote.physicalMilliseconds {
            nextCounter = max(logicalCounter, remote.logicalCounter) &+ 1
        } else if maximum == physicalMilliseconds {
            nextCounter = logicalCounter &+ 1
        } else if maximum == remote.physicalMilliseconds {
            nextCounter = remote.logicalCounter &+ 1
        } else {
            nextCounter = 0
        }
        self = HybridLogicalClock(
            physicalMilliseconds: maximum,
            logicalCounter: nextCounter,
            deviceID: deviceID
        )
    }
}

public struct InputFrontier: Codable, Hashable, Sendable {
    public let sequences: [String: UInt64]
    public let operationSequences: [String: UInt64]

    public init(sequences: [String: UInt64] = [:], operationSequences: [String: UInt64] = [:]) throws {
        guard sequences.values.allSatisfy({ $0 >= 0 }), operationSequences.values.allSatisfy({ $0 >= 0 }) else {
            throw RiverProtocolError.invalidFrontier
        }
        self.sequences = sequences.filter { $0.value > 0 }
        self.operationSequences = operationSequences.filter { $0.value > 0 }
    }

    public func dominates(_ other: InputFrontier) -> Bool {
        compare(sequences, to: other.sequences) && compare(operationSequences, to: other.operationSequences)
            && (isStrictlyGreater(sequences, than: other.sequences)
                || isStrictlyGreater(operationSequences, than: other.operationSequences))
    }

    public var eventCountScore: UInt64 {
        (Array(sequences.values) + Array(operationSequences.values)).reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? UInt64.max : sum
        }
    }

    public var stableKey: String {
        let events = sequences.keys.sorted().map { "e:\($0)=\(sequences[$0, default: 0])" }
        let operations = operationSequences.keys.sorted().map { "o:\($0)=\(operationSequences[$0, default: 0])" }
        return (events + operations).joined(separator: ";")
    }

    private func compare(_ lhs: [String: UInt64], to rhs: [String: UInt64]) -> Bool {
        let keys = Set(lhs.keys).union(rhs.keys)
        return keys.allSatisfy { lhs[$0, default: 0] >= rhs[$0, default: 0] }
    }

    private func isStrictlyGreater(_ lhs: [String: UInt64], than rhs: [String: UInt64]) -> Bool {
        let keys = Set(lhs.keys).union(rhs.keys)
        return keys.contains { lhs[$0, default: 0] > rhs[$0, default: 0] }
    }
}

public enum RiverArtifactKind: String, Codable, Hashable, Sendable {
    case semanticTimeline
    case dailyReview
    case habitReview
    case insight
    case memory
    case suggestion
    case weeklyReview
    case monthlyReview
    case pendingConfirmation
    case activityInterpretation
}

public enum ArtifactUserState: Int, Codable, Hashable, Sendable, Comparable {
    case generated = 0
    case approved = 1
    case edited = 2

    public static func < (lhs: ArtifactUserState, rhs: ArtifactUserState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ArtifactStatus: String, Codable, Hashable, Sendable {
    case provisional
    case current
    case stale
    case superseded
}

public struct ArtifactDependency: Codable, Hashable, Sendable {
    public let type: String
    public let id: String
    public let rangeStart: Date?
    public let rangeEnd: Date?

    public init(type: String, id: String, rangeStart: Date? = nil, rangeEnd: Date? = nil) {
        self.type = type
        self.id = id
        self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd
    }
}

public struct RiverArtifactRevision: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let logicalKey: String
    public let kind: RiverArtifactKind
    public let revisionNumber: UInt64
    public let originDeviceID: RiverDeviceID
    public let clock: HybridLogicalClock
    public let inputFrontier: InputFrontier
    public let inputSnapshotHash: String
    public let pipelineVersion: String
    public let promptVersion: String
    public let modelProvider: String
    public let modelIdentifier: String
    public let content: Data
    public let contentHash: String
    public let status: ArtifactStatus
    public let userState: ArtifactUserState
    public let supersedesRevisionID: String?
    public let dependencies: [ArtifactDependency]

    /// Stable, complete representation of fields that determine the canonical
    /// artifact and its provenance. Content itself is represented by its hash.
    public var canonicalDigestEntry: String {
        func frame(_ value: String) -> String { "\(value.utf8.count):\(value)" }
        func dateBits(_ date: Date?) -> String {
            guard let date else { return "nil" }
            return String(date.timeIntervalSince1970.bitPattern, radix: 16)
        }
        let dependencyEntries = dependencies.map { dependency in
            [dependency.type, dependency.id, dateBits(dependency.rangeStart), dateBits(dependency.rangeEnd)]
                .map(frame)
                .joined()
        }.sorted()
        let fields = [
            id, logicalKey, kind.rawValue, String(revisionNumber), originDeviceID.rawValue,
            String(clock.physicalMilliseconds), String(clock.logicalCounter), clock.deviceID.rawValue,
            inputFrontier.stableKey, inputSnapshotHash, pipelineVersion, promptVersion,
            modelProvider, modelIdentifier, contentHash, status.rawValue,
            String(userState.rawValue), supersedesRevisionID ?? ""
        ] + dependencyEntries
        return fields.map(frame).joined()
    }

    public func replacingStatus(_ status: ArtifactStatus) -> RiverArtifactRevision {
        RiverArtifactRevision(
            id: id, logicalKey: logicalKey, kind: kind, revisionNumber: revisionNumber,
            originDeviceID: originDeviceID, clock: clock, inputFrontier: inputFrontier,
            inputSnapshotHash: inputSnapshotHash, pipelineVersion: pipelineVersion,
            promptVersion: promptVersion, modelProvider: modelProvider,
            modelIdentifier: modelIdentifier, content: content, contentHash: contentHash,
            status: status, userState: userState, supersedesRevisionID: supersedesRevisionID,
            dependencies: dependencies
        )
    }

    public init(
        id: String,
        logicalKey: String,
        kind: RiverArtifactKind,
        revisionNumber: UInt64,
        originDeviceID: RiverDeviceID,
        clock: HybridLogicalClock,
        inputFrontier: InputFrontier,
        inputSnapshotHash: String,
        pipelineVersion: String,
        promptVersion: String,
        modelProvider: String,
        modelIdentifier: String,
        content: Data,
        contentHash: String,
        status: ArtifactStatus = .current,
        userState: ArtifactUserState = .generated,
        supersedesRevisionID: String? = nil,
        dependencies: [ArtifactDependency] = []
    ) {
        self.id = id
        self.logicalKey = logicalKey
        self.kind = kind
        self.revisionNumber = revisionNumber
        self.originDeviceID = originDeviceID
        self.clock = clock
        self.inputFrontier = inputFrontier
        self.inputSnapshotHash = inputSnapshotHash
        self.pipelineVersion = pipelineVersion
        self.promptVersion = promptVersion
        self.modelProvider = modelProvider
        self.modelIdentifier = modelIdentifier
        self.content = content
        self.contentHash = contentHash
        self.status = status
        self.userState = userState
        self.supersedesRevisionID = supersedesRevisionID
        self.dependencies = dependencies
    }
}

public struct ArtifactResolution: Sendable {
    public let canonical: RiverArtifactRevision
    public let superseded: [RiverArtifactRevision]
}

public enum ArtifactResolver {
    public static func resolve(_ revisions: [RiverArtifactRevision]) throws -> ArtifactResolution {
        var uniqueByID: [String: RiverArtifactRevision] = [:]
        for revision in revisions {
            if let existing = uniqueByID[revision.id], existing != revision {
                throw RiverProtocolError.invalidArtifactSet
            }
            uniqueByID[revision.id] = revision
        }
        let uniqueRevisions = Array(uniqueByID.values)
        guard let first = uniqueRevisions.first,
              uniqueRevisions.allSatisfy({ $0.logicalKey == first.logicalKey && $0.kind == first.kind }) else {
            throw RiverProtocolError.invalidArtifactSet
        }
        let ordered = uniqueRevisions.sorted(by: preferred)
        return ArtifactResolution(canonical: ordered[0], superseded: Array(ordered.dropFirst()))
    }

    /// A strict total order makes every replica choose the same winner. A
    /// dominating frontier wins first; incomparable frontiers fall through to
    /// coverage, pipeline, prompt, HLC, and finally a stable revision ID.
    private static func preferred(_ lhs: RiverArtifactRevision, _ rhs: RiverArtifactRevision) -> Bool {
        if lhs.userState != rhs.userState { return lhs.userState > rhs.userState }
        let lhsDominates = lhs.inputFrontier.dominates(rhs.inputFrontier)
        let rhsDominates = rhs.inputFrontier.dominates(lhs.inputFrontier)
        if lhsDominates != rhsDominates { return lhsDominates }
        if lhs.inputFrontier.eventCountScore != rhs.inputFrontier.eventCountScore {
            return lhs.inputFrontier.eventCountScore > rhs.inputFrontier.eventCountScore
        }
        let lhsStatusRank = statusRank(lhs.status)
        let rhsStatusRank = statusRank(rhs.status)
        if lhsStatusRank != rhsStatusRank { return lhsStatusRank > rhsStatusRank }
        if lhs.pipelineVersion != rhs.pipelineVersion { return version(lhs.pipelineVersion, outranks: rhs.pipelineVersion) }
        if lhs.promptVersion != rhs.promptVersion { return version(lhs.promptVersion, outranks: rhs.promptVersion) }
        if lhs.clock != rhs.clock { return lhs.clock > rhs.clock }
        if lhs.revisionNumber != rhs.revisionNumber { return lhs.revisionNumber > rhs.revisionNumber }
        return lhs.id < rhs.id
    }

    private static func statusRank(_ status: ArtifactStatus) -> Int {
        switch status {
        case .current: 3
        case .provisional: 2
        case .stale: 1
        case .superseded: 0
        }
    }

    private static func version(_ lhs: String, outranks rhs: String) -> Bool {
        func components(_ value: String) -> [Int] {
            value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let left = components(lhs)
        let right = components(rhs)
        if left != right { return left.lexicographicallyPrecedes(right) == false }
        return lhs > rhs
    }
}

public struct StateOperation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let actorDeviceID: RiverDeviceID
    public let originSequence: UInt64
    public let clock: HybridLogicalClock
    public let causalFrontier: InputFrontier
    public let targetID: String
    public let fieldKey: String
    public let operationType: String
    public let payload: Data

    public init(
        id: UUID = UUID(),
        actorDeviceID: RiverDeviceID,
        originSequence: UInt64 = 0,
        clock: HybridLogicalClock,
        causalFrontier: InputFrontier,
        targetID: String,
        fieldKey: String,
        operationType: String,
        payload: Data
    ) {
        self.id = id
        self.actorDeviceID = actorDeviceID
        self.originSequence = originSequence
        self.clock = clock
        self.causalFrontier = causalFrontier
        self.targetID = targetID
        self.fieldKey = fieldKey
        self.operationType = operationType
        self.payload = payload
    }
}

public struct StateOperationBatch: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let deviceID: RiverDeviceID
    public let protocolVersion: Int
    public let operations: [StateOperation]

    public init(id: String? = nil, deviceID: RiverDeviceID, protocolVersion: Int = 1,
                operations: [StateOperation]) throws {
        guard !operations.isEmpty else { throw RiverProtocolError.emptyBatch }
        guard operations.allSatisfy({ $0.actorDeviceID == deviceID && $0.originSequence > 0 }) else {
            throw RiverProtocolError.mixedDeviceBatch
        }
        let ordered = operations.sorted { $0.originSequence < $1.originSequence }
        guard Set(ordered.map(\.id)).count == ordered.count,
              Set(ordered.map(\.originSequence)).count == ordered.count else {
            throw RiverProtocolError.duplicateSequence
        }
        for pair in zip(ordered, ordered.dropFirst())
        where pair.0.originSequence == UInt64.max || pair.1.originSequence != pair.0.originSequence + 1 {
            throw RiverProtocolError.nonContiguousBatch
        }
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.operations = ordered
        self.id = id ?? "operations_\(deviceID.rawValue)_\(ordered[0].originSequence)-\(ordered[ordered.count - 1].originSequence)"
    }

    public var firstSequence: UInt64 { operations[0].originSequence }
    public var lastSequence: UInt64 { operations[operations.count - 1].originSequence }
}

public struct StreamFrontier: Codable, Hashable, Sendable {
    public let events: UInt64
    public let operations: UInt64

    public init(events: UInt64 = 0, operations: UInt64 = 0) {
        self.events = events
        self.operations = operations
    }
}

public enum DeviceLifecycle: String, Codable, Hashable, Sendable {
    case active
    case retired
}

public struct DeviceLifecyclePayload: Codable, Hashable, Sendable {
    public let displayName: String
    public let platform: String
    public let lifecycle: DeviceLifecycle

    public init(displayName: String, platform: String, lifecycle: DeviceLifecycle) {
        self.displayName = displayName
        self.platform = platform
        self.lifecycle = lifecycle
    }
}

public struct DeviceRegistration: Identifiable, Codable, Hashable, Sendable {
    public let id: RiverDeviceID
    public let displayName: String
    public let platform: String
    public let lifecycle: DeviceLifecycle
    public let clock: HybridLogicalClock

    public init(id: RiverDeviceID, displayName: String, platform: String,
                lifecycle: DeviceLifecycle, clock: HybridLogicalClock) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.lifecycle = lifecycle
        self.clock = clock
    }
}

public struct ReplicationManifest: Codable, Hashable, Sendable {
    public let deviceID: RiverDeviceID
    public let protocolVersion: Int
    public let schemaVersion: Int
    public let revision: UInt64
    public let clock: HybridLogicalClock
    public let ownedFrontier: StreamFrontier
    public let importedFrontiers: [String: StreamFrontier]
    public let knownDevices: [DeviceRegistration]
    public let canonicalStateDigest: String
    public let updatedAt: Date

    public init(deviceID: RiverDeviceID, protocolVersion: Int = 1, schemaVersion: Int = 1,
                revision: UInt64 = 0, clock: HybridLogicalClock? = nil,
                ownedFrontier: StreamFrontier, importedFrontiers: [String: StreamFrontier],
                knownDevices: [DeviceRegistration], canonicalStateDigest: String, updatedAt: Date = Date()) {
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.clock = clock ?? HybridLogicalClock(
            physicalMilliseconds: UInt64(max(0, updatedAt.timeIntervalSince1970 * 1_000)),
            deviceID: deviceID
        )
        self.ownedFrontier = ownedFrontier
        self.importedFrontiers = importedFrontiers
        self.knownDevices = knownDevices
        self.canonicalStateDigest = canonicalStateDigest
        self.updatedAt = updatedAt
    }
}

public enum ManifestResolver {
    public static func latestByDevice(_ manifests: [ReplicationManifest]) -> [RiverDeviceID: ReplicationManifest] {
        Dictionary(grouping: manifests, by: \.deviceID).compactMapValues { candidates in
            candidates.sorted {
                if $0.clock != $1.clock { return $0.clock > $1.clock }
                if $0.revision != $1.revision { return $0.revision > $1.revision }
                if $0.ownedFrontier.events != $1.ownedFrontier.events {
                    return $0.ownedFrontier.events > $1.ownedFrontier.events
                }
                if $0.ownedFrontier.operations != $1.ownedFrontier.operations {
                    return $0.ownedFrontier.operations > $1.ownedFrontier.operations
                }
                return $0.canonicalStateDigest < $1.canonicalStateDigest
            }.first
        }
    }
}

public enum DeviceRegistry {
    /// Per-device lifecycle updates are immutable operations. The highest HLC
    /// wins; equal clocks use a stable device ID tie-break, and records remain
    /// available for audit after retirement.
    public static func merge(_ registrations: [DeviceRegistration]) -> [DeviceRegistration] {
        Dictionary(grouping: registrations, by: \.id).values.compactMap { values in
            values.sorted {
                if $0.clock != $1.clock { return $0.clock > $1.clock }
                if $0.lifecycle != $1.lifecycle { return $0.lifecycle == .retired }
                return $0.displayName < $1.displayName
            }.first
        }.sorted { $0.id.rawValue < $1.id.rawValue }
    }
}

public enum SyncVerification {
    /// A replica is verified only when every active registered device is
    /// present, every replica has imported each peer's advertised event and
    /// operation prefix without gaps, and all report the same canonical digest.
    public static func isVerified(
        manifests: [ReplicationManifest],
        activeDeviceIDs: Set<RiverDeviceID>,
        devicesWithSequenceGaps: Set<RiverDeviceID> = []
    ) -> Bool {
        guard !activeDeviceIDs.isEmpty,
              devicesWithSequenceGaps.isEmpty,
              Set(manifests.map(\.deviceID)) == activeDeviceIDs,
              let firstDigest = manifests.first?.canonicalStateDigest,
              !firstDigest.isEmpty,
              manifests.allSatisfy({ $0.canonicalStateDigest == firstDigest }) else { return false }

        let advertised = Dictionary(uniqueKeysWithValues: manifests.map { ($0.deviceID.rawValue, $0.ownedFrontier) })
        return manifests.allSatisfy { manifest in
            activeDeviceIDs.allSatisfy { peer in
                if peer == manifest.deviceID { return true }
                guard let expected = advertised[peer.rawValue] else { return false }
                let imported = manifest.importedFrontiers[peer.rawValue] ?? StreamFrontier()
                return imported.events >= expected.events && imported.operations >= expected.operations
            }
        }
    }
}

public struct StateResolution: Sendable {
    public let currentByField: [String: StateOperation]
    public let conflicts: [[StateOperation]]
}

public enum StateOperationResolver {
    public static func resolve(_ operations: [StateOperation]) -> StateResolution {
        let groups = Dictionary(grouping: operations) { "\($0.targetID)\u{1f}\($0.fieldKey)" }
        var current: [String: StateOperation] = [:]
        var conflicts: [[StateOperation]] = []
        for (key, values) in groups {
            let ordered = values.sorted {
                if $0.clock != $1.clock { return $0.clock > $1.clock }
                return $0.id.uuidString < $1.id.uuidString
            }
            if let winner = ordered.first { current[key] = winner }
            let concurrent = ordered.filter { candidate in
                guard let winner = ordered.first, candidate.id != winner.id else { return false }
                return !candidate.causalFrontier.dominates(winner.causalFrontier)
                    && !winner.causalFrontier.dominates(candidate.causalFrontier)
                    && candidate.payload != winner.payload
            }
            if !concurrent.isEmpty, let winner = ordered.first {
                conflicts.append([winner] + concurrent)
            }
        }
        conflicts.sort {
            let left = $0.first.map { "\($0.targetID)\u{1f}\($0.fieldKey)" } ?? ""
            let right = $1.first.map { "\($0.targetID)\u{1f}\($0.fieldKey)" } ?? ""
            return left < right
        }
        return StateResolution(currentByField: current, conflicts: conflicts)
    }

    public static func tombstonedObjectIDs(_ operations: [StateOperation]) -> Set<String> {
        let resolved = resolve(operations)
        var result = Set<String>()
        for operation in resolved.currentByField.values where operation.fieldKey == "deleted" {
            guard let deleted = try? JSONDecoder().decode(Bool.self, from: operation.payload) else { continue }
            if deleted { result.insert(operation.targetID) }
        }
        return result
    }

    public static func invalidatedArtifactIDs(_ operations: [StateOperation]) -> Set<String> {
        Set(operations.lazy
            .filter { $0.operationType == "artifact.stale" && $0.fieldKey == "freshness" }
            .map(\.targetID))
    }
}
