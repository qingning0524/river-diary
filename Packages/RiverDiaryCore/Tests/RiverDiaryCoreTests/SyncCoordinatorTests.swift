import CryptoKit
import Foundation
import Testing
@testable import RiverDiaryCore

@MainActor
struct SyncCoordinatorTests {
    @Test func twoPairedOfflineNodesConvergeAfterBothExchangeImmutableBatches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let key = SyncEncryptionKey()

        phoneStore.append(event(device: phone, sequence: 1, kind: "app.opened", name: "微信", at: 100))
        macStore.append(event(device: mac, sequence: 1, kind: "app.session", name: "Xcode", at: 200))

        let directory = ReplicationDirectory(rootURL: root)
        let phoneSync = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key)
        let macSync = try RiverSyncCoordinator(store: macStore, directory: directory, key: key)

        #expect(try phoneSync.synchronize().isVerified == false)
        #expect(try macSync.synchronize().importedEventBatches == 1)
        let finalPhoneReport = try phoneSync.synchronize()
        #expect(finalPhoneReport.importedEventBatches == 1)
        #expect(finalPhoneReport.isVerified)
        #expect(Set(phoneStore.events.values.map(\.id)) == Set(macStore.events.values.map(\.id)))
        #expect(try macSync.synchronize().isVerified)
    }

    @Test func duplicateLanThenICloudDeliveryKeepsOneEventByEventID() throws {
        let phoneRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let macRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: phoneRoot)
            try? FileManager.default.removeItem(at: macRoot)
        }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let event = self.event(device: phone, sequence: 1, kind: "location.visit.arrival", name: "学校", at: 100)
        phoneStore.append(event)
        macStore.append(self.event(device: mac, sequence: 1, kind: "app.session", name: "Xcode", at: 200))

        let phoneDirectory = ReplicationDirectory(rootURL: phoneRoot)
        let macDirectory = ReplicationDirectory(rootURL: macRoot)
        let key = SyncEncryptionKey()
        let phoneSync = try RiverSyncCoordinator(store: phoneStore, directory: phoneDirectory, key: key)
        let macSync = try RiverSyncCoordinator(store: macStore, directory: macDirectory, key: key)
        _ = try phoneSync.synchronize()

        let lanBatch = try #require(phoneStore.localEventBatches().first)
        let maybeEncryptedBatch = try phoneDirectory.readObject(id: lanBatch.id, stream: "Events", deviceID: phone)
        let encryptedBatch = try #require(maybeEncryptedBatch)
        _ = try macDirectory.publish(encryptedBatch, stream: "Events", deviceID: phone) // LAN delivery
        let lanReport = try macSync.synchronize()
        #expect(lanReport.importedEventBatches == 1)

        _ = try macDirectory.publish(encryptedBatch, stream: "Events", deviceID: phone) // later iCloud delivery
        let iCloudReport = try macSync.synchronize()

        #expect(iCloudReport.importedEventBatches == 0)
        #expect(macStore.events.values.filter { $0.id == event.id }.count == 1)
        #expect(macStore.events.count == 2)
    }

    @Test func sharedHabitAndMemoryDecisionsConvergeThroughEncryptedOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let directory = ReplicationDirectory(rootURL: root)
        let key = SyncEncryptionKey()
        let empty = try InputFrontier()
        let memoryID = UUID()
        let memory = RiverSharedStateRecord(
            id: memoryID, kind: .memory, status: "candidate", logicalKey: memoryID.uuidString.lowercased(),
            payloadJSON: "{\"title\":\"早晨先写作\",\"body\":\"\"}",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let card = RiverSharedStateRecord(
            id: UUID(), kind: .habitCard, status: "answered", logicalKey: "w-2026-09-28|pattern:com.example.app",
            payloadJSON: "{\"question\":\"是否算作工作？\",\"status\":\"answered\"}",
            createdAt: Date(timeIntervalSince1970: 11), updatedAt: Date(timeIntervalSince1970: 20)
        )
        let memoryPayload = try JSONEncoder().encode(memory)
        let cardPayload = try JSONEncoder().encode(card)
        let decision = RiverMemoryConfirmation(memoryID: memoryID, confirmed: true, note: "已确认", updatedAt: Date(timeIntervalSince1970: 30))
        let operations = [
            StateOperation(
                actorDeviceID: phone, originSequence: 1,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: phone),
                causalFrontier: empty, targetID: memory.targetID, fieldKey: "record",
                operationType: "shared.record.upsert", payload: memoryPayload
            ),
            StateOperation(
                actorDeviceID: phone, originSequence: 2,
                clock: HybridLogicalClock(physicalMilliseconds: 20, deviceID: phone),
                causalFrontier: try InputFrontier(operationSequences: [phone.rawValue: 1]),
                targetID: card.targetID, fieldKey: "record",
                operationType: "shared.record.upsert", payload: cardPayload
            ),
            StateOperation(
                actorDeviceID: phone, originSequence: 3,
                clock: HybridLogicalClock(physicalMilliseconds: 30, deviceID: phone),
                causalFrontier: try InputFrontier(operationSequences: [phone.rawValue: 2]),
                targetID: "memory:\(memoryID.uuidString.lowercased())", fieldKey: "confirmation",
                operationType: "memory.confirmation.set", payload: try JSONEncoder().encode(decision)
            )
        ]
        operations.forEach { phoneStore.append($0) }

        _ = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key).synchronize()
        let report = try RiverSyncCoordinator(store: macStore, directory: directory, key: key).synchronize()

        #expect(report.importedOperationBatches == 1)
        let received = macStore.operations.values.sorted { $0.originSequence < $1.originSequence }
        #expect(received.map(\.operationType) == ["shared.record.upsert", "shared.record.upsert", "memory.confirmation.set"])
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: received[0].payload) == memory)
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: received[1].payload) == card)
        #expect(try JSONDecoder().decode(RiverMemoryConfirmation.self, from: received[2].payload) == decision)
    }

    @Test func handwrittenEntriesAndMonthlyLettersConvergeThroughEncryptedOperations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let directory = ReplicationDirectory(rootURL: root)
        let key = SyncEncryptionKey()
        let entry = try #require(RiverSharedStateRecord.journalEntry(RiverJournalEntryContent(
            dayKey: "2026-09-28", body: "两台设备最终会看到同一段日记", moodScore: 81,
            tags: ["跨设备"], updatedAt: Date(timeIntervalSince1970: 100)
        )))
        let letter = try #require(RiverSharedStateRecord.monthlyLetter(RiverMonthlyLetterContent(
            monthKey: "2026-09", title: "九月", body: "这封信来自同一份共享状态。",
            evidence: "手写记录", createdAt: Date(timeIntervalSince1970: 110),
            updatedAt: Date(timeIntervalSince1970: 110)
        )))
        let draft = try #require(RiverSharedStateRecord.monthlyLetterDraft(
            RiverMonthlyLetterDraftContent(
                monthKey: "2026-09", body: "这份信还没有正式保存。",
                updatedAt: Date(timeIntervalSince1970: 120)
            )
        ))
        let frontier = try InputFrontier()
        phoneStore.append(StateOperation(
            actorDeviceID: phone, originSequence: 1,
            clock: HybridLogicalClock(physicalMilliseconds: 100, deviceID: phone),
            causalFrontier: frontier, targetID: entry.targetID, fieldKey: "record",
            operationType: "shared.record.upsert", payload: try JSONEncoder().encode(entry)
        ))
        phoneStore.append(StateOperation(
            actorDeviceID: phone, originSequence: 2,
            clock: HybridLogicalClock(physicalMilliseconds: 110, deviceID: phone),
            causalFrontier: try InputFrontier(operationSequences: [phone.rawValue: 1]),
            targetID: letter.targetID, fieldKey: "record",
            operationType: "shared.record.upsert", payload: try JSONEncoder().encode(letter)
        ))
        phoneStore.append(StateOperation(
            actorDeviceID: phone, originSequence: 3,
            clock: HybridLogicalClock(physicalMilliseconds: 120, deviceID: phone),
            causalFrontier: try InputFrontier(operationSequences: [phone.rawValue: 2]),
            targetID: draft.targetID, fieldKey: "record",
            operationType: "shared.record.upsert", payload: try JSONEncoder().encode(draft)
        ))

        _ = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key).synchronize()
        let report = try RiverSyncCoordinator(store: macStore, directory: directory, key: key).synchronize()
        #expect(report.importedOperationBatches == 1)
        let received = macStore.operations.values.sorted { $0.originSequence < $1.originSequence }
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: received[0].payload) == entry)
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: received[1].payload) == letter)
        let receivedDraft = try JSONDecoder().decode(RiverSharedStateRecord.self, from: received[2].payload)
        #expect(receivedDraft.monthlyLetterDraftContent?.body == "这份信还没有正式保存。")
    }

    @Test func corruptedArtifactFileCannotImportOrReportVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        phoneStore.append(event(device: phone, sequence: 1, kind: "app.opened", name: "Safari", at: 100))
        let revision = artifact(
            id: "daily-review-corrupt-test",
            device: phone,
            frontier: try InputFrontier(sequences: [phone.rawValue: 1]),
            content: "canonical review"
        )
        phoneStore.append(revision)
        let directory = ReplicationDirectory(rootURL: root)
        let key = SyncEncryptionKey()
        _ = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key).synchronize()

        let encryptedObject = try directory.readObject(id: revision.id, stream: "Artifacts", deviceID: phone)
        let encrypted = try #require(encryptedObject)
        let corrupted = EncryptedReplicationObject(
            id: encrypted.id,
            kind: encrypted.kind,
            protocolVersion: encrypted.protocolVersion,
            ciphertext: encrypted.ciphertext + Data([0]),
            ciphertextSHA256: encrypted.ciphertextSHA256
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let objectURL = root.appendingPathComponent("Devices", isDirectory: true)
            .appendingPathComponent(phone.rawValue, isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
            .appendingPathComponent("\(revision.id).rdo")
        try encoder.encode(corrupted).write(to: objectURL, options: .atomic)

        let report = try RiverSyncCoordinator(store: macStore, directory: directory, key: key).synchronize()
        #expect(!report.integrityFailures.isEmpty)
        #expect(report.importedArtifactRevisions == 0)
        #expect(macStore.artifacts[revision.id] == nil)
        #expect(!report.isVerified)
    }

    @Test func replicationObjectWithInvalidProtocolVersionCannotImportOrVerify() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let event = self.event(device: phone, sequence: 1, kind: "app.opened", name: "Safari", at: 100)
        let batch = try RiverEventBatch(deviceID: phone, events: [event])
        let key = SyncEncryptionKey()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(batch)
        let validEnvelope = try EncryptedReplicationObject.seal(
            plaintext, id: batch.id, kind: "event_batch", using: key
        )
        let invalidEnvelope = EncryptedReplicationObject(
            id: validEnvelope.id,
            kind: validEnvelope.kind,
            protocolVersion: 0,
            ciphertext: validEnvelope.ciphertext,
            ciphertextSHA256: validEnvelope.ciphertextSHA256
        )
        let directory = ReplicationDirectory(rootURL: root)
        _ = try directory.publish(invalidEnvelope, stream: "Events", deviceID: phone)

        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let report = try RiverSyncCoordinator(store: macStore, directory: directory, key: key).synchronize()

        #expect(report.importedEventBatches == 0)
        #expect(macStore.events.isEmpty)
        #expect(report.integrityFailures.contains { $0.contains("协议版本无效") })
        #expect(!report.isVerified)
    }

    @Test func reinstalledNodeRestoresItsOwnPublishedObjectsFromTheSelectedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let key = SyncEncryptionKey()
        let directory = ReplicationDirectory(rootURL: root)
        let original = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let localEvent = event(device: phone, sequence: 1, kind: "app.opened", name: "Safari", at: 100)
        original.append(localEvent)
        original.append(StateOperation(
            actorDeviceID: phone,
            originSequence: 1,
            clock: HybridLogicalClock(physicalMilliseconds: 100, deviceID: phone),
            causalFrontier: try InputFrontier(),
            targetID: "place:school",
            fieldKey: "name",
            operationType: "place.rename",
            payload: Data("学校".utf8)
        ))
        original.append(artifact(
            id: "recovery-daily-review",
            device: phone,
            frontier: try InputFrontier(sequences: [phone.rawValue: 1], operationSequences: [phone.rawValue: 1]),
            content: "恢复的回顾"
        ))
        _ = try RiverSyncCoordinator(store: original, directory: directory, key: key).synchronize()

        let reinstalled = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let recoveryReport = try RiverSyncCoordinator(store: reinstalled, directory: directory, key: key).synchronize()

        #expect(recoveryReport.importedEventBatches == 1)
        #expect(recoveryReport.importedOperationBatches == 1)
        #expect(recoveryReport.importedArtifactRevisions == 1)
        #expect(try reinstalled.ownedFrontier() == StreamFrontier(events: 1, operations: 1))
        #expect(reinstalled.events[localEvent.id] == localEvent)
        #expect(reinstalled.canonicalArtifacts.first?.id == "recovery-daily-review")
        #expect(!recoveryReport.isVerified, "a recovered node must wait for each other active device to acknowledge it")
    }

    @Test func missingEventSequencePreventsVerifiedStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        let key = SyncEncryptionKey()
        phoneStore.append(event(device: phone, sequence: 1, kind: "location.visit.arrival", name: "", at: 100))
        phoneStore.append(event(device: phone, sequence: 3, kind: "location.visit.departure", name: "", at: 200))

        let directory = ReplicationDirectory(rootURL: root)
        _ = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key).synchronize()
        let report = try RiverSyncCoordinator(store: macStore, directory: directory, key: key).synchronize()
        #expect(report.importedEventBatches == 2)
        #expect(!report.isVerified)
        #expect(macStore.importedFrontiers[phone.rawValue]?.events == 1)
        #expect(report.missingSequenceGaps.contains {
            $0.deviceID == phone && $0.stream == "Events" && $0.first == 2 && $0.last == 2
        })
    }

    @Test func pairedNodesConvergeUserOperationsAndOfflineArtifactConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = RiverDeviceID(rawValue: "iphone_phone")
        let mac = RiverDeviceID(rawValue: "mac_desktop")
        let phoneStore = MemorySyncStore(deviceID: phone, knownDevices: [mac])
        let macStore = MemorySyncStore(deviceID: mac, knownDevices: [phone])
        phoneStore.append(event(device: phone, sequence: 1, kind: "location.visit.arrival", name: "学校", at: 100))
        macStore.append(event(device: mac, sequence: 1, kind: "app.session", name: "Xcode", at: 200))

        let empty = try InputFrontier()
        phoneStore.append(StateOperation(
            actorDeviceID: phone,
            originSequence: 1,
            clock: HybridLogicalClock(physicalMilliseconds: 2, deviceID: phone),
            causalFrontier: empty,
            targetID: "place:campus",
            fieldKey: "identity",
            operationType: "place.identity.set",
            payload: try JSONEncoder().encode(RiverPlaceUserDecision(name: "学校", semanticType: "school", isConfirmed: true))
        ))
        phoneStore.append(artifact(id: "phone-r1", device: phone, frontier: try InputFrontier(sequences: [phone.rawValue: 1]), content: "phone review"))
        macStore.append(artifact(id: "mac-r1", device: mac, frontier: try InputFrontier(sequences: [mac.rawValue: 1]), content: "mac review"))

        let directory = ReplicationDirectory(rootURL: root)
        let key = SyncEncryptionKey()
        let phoneSync = try RiverSyncCoordinator(store: phoneStore, directory: directory, key: key)
        let macSync = try RiverSyncCoordinator(store: macStore, directory: directory, key: key)

        _ = try phoneSync.synchronize()
        let macImport = try macSync.synchronize()
        #expect(macImport.importedOperationBatches == 1)
        #expect(macImport.importedArtifactRevisions == 1)
        _ = try phoneSync.synchronize()
        _ = try macSync.synchronize()

        #expect(phoneStore.operations.values.map(\.id) == macStore.operations.values.map(\.id))
        #expect(phoneStore.artifacts.keys.sorted() == macStore.artifacts.keys.sorted())
        #expect(phoneStore.canonicalArtifacts.map(\.id) == macStore.canonicalArtifacts.map(\.id))
        #expect(phoneStore.canonicalArtifacts.first?.id == "mac-r1")
        #expect(try phoneSync.synchronize().isVerified)
    }

    private func event(device: RiverDeviceID, sequence: UInt64, kind: String, name: String, at time: TimeInterval) -> RiverEvent {
        let payload = try! JSONEncoder().encode(RiverEventPayload(appName: name.isEmpty ? nil : name))
        return RiverEvent(
            originDeviceID: device,
            originSequence: sequence,
            observedAt: Date(timeIntervalSince1970: time),
            source: "test",
            kind: kind,
            payload: payload
        )
    }
}

@MainActor
private final class MemorySyncStore: RiverSyncLocalStore {
    let deviceID: RiverDeviceID
    var syncDeviceID: RiverDeviceID? { deviceID }
    var events: [UUID: RiverEvent] = [:]
    var operations: [UUID: StateOperation] = [:]
    var artifacts: [String: RiverArtifactRevision] = [:]
    var imports: Set<String> = []
    var registrations: [RiverDeviceID: DeviceRegistration] = [:]
    var importedFrontiers: [String: StreamFrontier] = [:]
    private var eventSequence: UInt64 = 0
    private var operationSequence: UInt64 = 0
    private var manifestRevision: UInt64 = 0
    private var clock: HybridLogicalClock
    private var manifestKeys: [String: String] = [:]

    init(deviceID: RiverDeviceID, knownDevices: [RiverDeviceID]) {
        self.deviceID = deviceID
        clock = HybridLogicalClock(physicalMilliseconds: 0, deviceID: deviceID)
        registrations[deviceID] = DeviceRegistration(
            id: deviceID, displayName: deviceID.rawValue, platform: "test",
            lifecycle: .active, clock: clock
        )
        for peer in knownDevices {
            registrations[peer] = DeviceRegistration(
                id: peer, displayName: peer.rawValue, platform: "test",
                lifecycle: .active, clock: HybridLogicalClock(physicalMilliseconds: 0, deviceID: peer)
            )
        }
    }

    func append(_ event: RiverEvent) {
        events[event.id] = event
        if event.originDeviceID == deviceID { eventSequence = max(eventSequence, event.originSequence) }
    }

    func append(_ operation: StateOperation) {
        operations[operation.id] = operation
        if operation.actorDeviceID == deviceID {
            operationSequence = max(operationSequence, operation.originSequence)
        }
    }

    func append(_ revision: RiverArtifactRevision) {
        artifacts[revision.id] = revision
    }

    var canonicalArtifacts: [RiverArtifactRevision] {
        let grouped: [[RiverArtifactRevision]] = Dictionary(
            grouping: Array(artifacts.values),
            by: { revision in revision.logicalKey + "|" + revision.kind.rawValue }
        ).map { $0.value }
        var resolved: [RiverArtifactRevision] = []
        for candidates in grouped {
            if let choice = try? ArtifactResolver.resolve(candidates) {
                resolved.append(choice.canonical)
            }
        }
        return resolved.sorted {
            if $0.logicalKey != $1.logicalKey { return $0.logicalKey < $1.logicalKey }
            return $0.id < $1.id
        }
    }

    func localEventBatches() throws -> [RiverEventBatch] {
        try groups(Array(events.values.filter { $0.originDeviceID == deviceID }), batchSize: 128)
            .map { try RiverEventBatch(deviceID: deviceID, events: $0) }
    }

    func localStateOperationBatches() throws -> [StateOperationBatch] {
        try groups(Array(operations.values.filter { $0.actorDeviceID == deviceID }), batchSize: 128)
            .map { try StateOperationBatch(deviceID: deviceID, operations: $0) }
    }
    func localArtifactRevisions() throws -> [RiverArtifactRevision] { artifacts.values.filter { $0.originDeviceID == deviceID } }

    func importEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        if imports.contains(objectID) { return false }
        for event in batch.events {
            if let existing = events[event.id], existing != event { throw RiverSyncStoreError.persistence("Event collision") }
            events[event.id] = event
        }
        importedFrontiers[batch.deviceID.rawValue] = StreamFrontier(
            events: contiguous(events.values.filter { $0.originDeviceID == batch.deviceID }.map(\.originSequence)),
            operations: importedFrontiers[batch.deviceID.rawValue]?.operations ?? 0
        )
        imports.insert(objectID)
        return true
    }

    func importStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        if imports.contains(objectID) { return false }
        for operation in batch.operations {
            if let existing = operations[operation.id], existing != operation {
                throw RiverSyncStoreError.persistence("Operation collision")
            }
            operations[operation.id] = operation
        }
        importedFrontiers[batch.deviceID.rawValue] = StreamFrontier(
            events: importedFrontiers[batch.deviceID.rawValue]?.events ?? 0,
            operations: contiguous(operations.values.filter { $0.actorDeviceID == batch.deviceID }.map(\.originSequence))
        )
        imports.insert(objectID)
        return true
    }

    func importArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        if imports.contains(objectID) { return false }
        if let existing = artifacts[revision.id], existing != revision {
            throw RiverSyncStoreError.persistence("Artifact collision")
        }
        artifacts[revision.id] = revision
        imports.insert(objectID)
        return true
    }

    func restoreOwnedEventBatch(_ batch: RiverEventBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == deviceID else { return false }
        let restored = try importEventBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash)
        if restored { eventSequence = contiguous(events.values.filter { $0.originDeviceID == deviceID }.map(\.originSequence)) }
        return restored
    }

    func restoreOwnedStateOperationBatch(_ batch: StateOperationBatch, objectID: String, ciphertextHash: String) throws -> Bool {
        guard batch.deviceID == deviceID else { return false }
        let restored = try importStateOperationBatch(batch, objectID: objectID, ciphertextHash: ciphertextHash)
        if restored { operationSequence = contiguous(operations.values.filter { $0.actorDeviceID == deviceID }.map(\.originSequence)) }
        return restored
    }

    func restoreOwnedArtifactRevision(_ revision: RiverArtifactRevision, objectID: String, ciphertextHash: String) throws -> Bool {
        guard revision.originDeviceID == deviceID else { return false }
        return try importArtifactRevision(revision, objectID: objectID, ciphertextHash: ciphertextHash)
    }

    func importedObjectExists(_ objectID: String) throws -> Bool { imports.contains(objectID) }

    func ownedFrontier() throws -> StreamFrontier {
        StreamFrontier(events: eventSequence, operations: operationSequence)
    }

    func importedFrontiers(for deviceIDs: Set<RiverDeviceID>) throws -> [String: StreamFrontier] {
        Dictionary(uniqueKeysWithValues: deviceIDs.map { ($0.rawValue, importedFrontiers[$0.rawValue] ?? StreamFrontier()) })
    }

    func sequenceGapDevices(expectedFrontiers: [String: StreamFrontier]) throws -> Set<RiverDeviceID> {
        Set(expectedFrontiers.compactMap { deviceText, expected in
            let events = self.events.values.filter { $0.originDeviceID.rawValue == deviceText }.map(\.originSequence)
            let eventPrefix = self.contiguous(events)
            let operations = self.operations.values.filter { $0.actorDeviceID.rawValue == deviceText }.map(\.originSequence)
            let opPrefix = self.contiguous(operations)
            return eventPrefix < expected.events || opPrefix < expected.operations
                ? RiverDeviceID(rawValue: deviceText)
                : nil
        })
    }

    func sequenceGaps(expectedFrontiers: [String: StreamFrontier]) throws -> [SyncSequenceGap] {
        var result: [SyncSequenceGap] = []
        for (deviceText, frontier) in expectedFrontiers {
            let deviceID = RiverDeviceID(rawValue: deviceText)
            let streams: [(String, [UInt64], UInt64)] = [
                ("Events", events.values.filter { $0.originDeviceID.rawValue == deviceText }.map(\.originSequence), frontier.events),
                ("Operations", operations.values.filter { $0.actorDeviceID.rawValue == deviceText }.map(\.originSequence), frontier.operations)
            ]
            for (stream, values, expected) in streams where expected > 0 {
                var cursor: UInt64 = 1
                for sequence in Set(values.filter { $0 <= expected }).sorted() {
                    if sequence > cursor { result.append(SyncSequenceGap(deviceID: deviceID, stream: stream, first: cursor, last: sequence - 1)) }
                    if sequence >= cursor { cursor = sequence + 1 }
                }
                if cursor <= expected { result.append(SyncSequenceGap(deviceID: deviceID, stream: stream, first: cursor, last: expected)) }
            }
        }
        return result
    }

    func allDeviceRegistrations() throws -> [DeviceRegistration] { Array(registrations.values) }

    func mergeDeviceRegistrations(_ values: [DeviceRegistration]) throws {
        for value in DeviceRegistry.merge(Array(registrations.values) + values) { registrations[value.id] = value }
    }

    func reconcileDeviceRegistryFromOperations() throws {}
    func rebuildDerivedState() throws {}

    func canonicalStateDigest() throws -> String {
        let frontiers = Dictionary(uniqueKeysWithValues: registrations.keys.flatMap { id in
            let frontier = id == deviceID
                ? StreamFrontier(events: eventSequence, operations: operationSequence)
                : importedFrontiers[id.rawValue] ?? StreamFrontier()
            return [("\(id.rawValue):events", frontier.events), ("\(id.rawValue):operations", frontier.operations)]
        })
        return CanonicalStateDigest.make(
            events: Array(events.values),
            stateOperations: Array(operations.values),
            canonicalArtifactDigests: canonicalArtifacts.map(\.canonicalDigestEntry),
            deviceFrontiers: frontiers
        )
    }

    func nextManifestStamp(after previousRevision: UInt64, observing remoteClock: HybridLogicalClock?) throws -> (revision: UInt64, clock: HybridLogicalClock) {
        manifestRevision = max(manifestRevision, previousRevision) + 1
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        if let remoteClock { clock.observe(remoteClock, wallTimeMilliseconds: now) }
        clock.tick(wallTimeMilliseconds: now)
        return (manifestRevision, clock)
    }

    func lastPublishedManifestKey(for directoryID: String) throws -> String? { manifestKeys[directoryID] }
    func savePublishedManifestKey(_ key: String, for directoryID: String) throws { manifestKeys[directoryID] = key }
    func recordVerification(isVerified: Bool, digest: String) throws {}

    private func contiguous(_ values: [UInt64]) -> UInt64 {
        SequenceScan(sequences: values).contiguousThrough
    }

    private func groups(_ values: [RiverEvent], batchSize: Int) throws -> [[RiverEvent]] {
        let ordered = values.sorted { $0.originSequence < $1.originSequence }
        var batches: [[RiverEvent]] = []
        var current: [RiverEvent] = []
        for event in ordered {
            if let last = current.last, last.originSequence == UInt64.max || event.originSequence != last.originSequence + 1 {
                batches.append(current)
                current = []
            }
            current.append(event)
            if current.count == batchSize { batches.append(current); current = [] }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func groups(_ values: [StateOperation], batchSize: Int) throws -> [[StateOperation]] {
        let ordered = values.sorted { $0.originSequence < $1.originSequence }
        var batches: [[StateOperation]] = []
        var current: [StateOperation] = []
        for operation in ordered {
            if let last = current.last, last.originSequence == UInt64.max || operation.originSequence != last.originSequence + 1 {
                batches.append(current)
                current = []
            }
            current.append(operation)
            if current.count == batchSize { batches.append(current); current = [] }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

@MainActor
private func artifact(id: String, device: RiverDeviceID, frontier: InputFrontier, content: String) -> RiverArtifactRevision {
    let data = Data(content.utf8)
    return RiverArtifactRevision(
        id: id,
        logicalKey: "daily-review:2026-09-28",
        kind: .dailyReview,
        revisionNumber: 1,
        originDeviceID: device,
        clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: device),
        inputFrontier: frontier,
        inputSnapshotHash: "snapshot-\(id)",
        pipelineVersion: "1.0",
        promptVersion: "1",
        modelProvider: "test",
        modelIdentifier: "test-model",
        content: data,
        contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    )
}
