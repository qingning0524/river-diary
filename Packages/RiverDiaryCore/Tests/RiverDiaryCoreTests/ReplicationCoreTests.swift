import CryptoKit
import Foundation
import Testing
@testable import RiverDiaryCore

struct ReplicationCoreTests {
    @Test func syncObjectsEncryptVerifyAndRejectTampering() throws {
        let key = SyncEncryptionKey()
        let original = Data("private river diary event".utf8)
        let object = try EncryptedReplicationObject.seal(original, id: "event-batch-1", kind: "events", using: key)

        #expect(try object.open(using: key) == original)
        #expect(object.ciphertext != original)

        let tampered = EncryptedReplicationObject(
            id: object.id,
            kind: object.kind,
            protocolVersion: object.protocolVersion,
            ciphertext: object.ciphertext + Data([0]),
            ciphertextSHA256: object.ciphertextSHA256
        )
        #expect(throws: ReplicationCryptoError.digestMismatch) { try tampered.open(using: key) }
    }

    @Test func keyExportCanBeTransferredAndWrongKeyCannotDecrypt() throws {
        let key = SyncEncryptionKey()
        let restored = try SyncEncryptionKey(importCode: key.exportCode)
        let object = try EncryptedReplicationObject.seal(Data([1, 2, 3]), id: "x", kind: "event", using: key)
        #expect(try object.open(using: restored) == Data([1, 2, 3]))

        let wrong = SyncEncryptionKey()
        #expect(throws: Error.self) { try object.open(using: wrong) }
    }

    @Test func localBackupRoundTripsOnlyInsideAnAuthenticatedEncryptedEnvelope() throws {
        let device = RiverDeviceID(rawValue: "iphone_backup")
        let event = RiverEvent(
            originDeviceID: device,
            originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 100),
            source: "test",
            kind: "manual.note",
            payload: Data("private note".utf8)
        )
        let backup = RiverNodeBackup(
            sourceDeviceID: device,
            events: [event],
            stateOperations: [],
            artifactRevisions: [],
            deviceRegistrations: []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SyncEncryptionKey()
        let transferredKey = try SyncEncryptionKey(importCode: key.exportCode)
        let encrypted = try EncryptedReplicationObject.seal(
            encoder.encode(backup), id: "local-backup-test", kind: "local_backup", using: key
        )
        #expect(encrypted.ciphertext.range(of: Data("private note".utf8)) == nil)
        let restored = try JSONDecoder().decode(RiverNodeBackup.self, from: encrypted.open(using: transferredKey))
        #expect(restored == backup)
        #expect(throws: Error.self) { try encrypted.open(using: SyncEncryptionKey()) }
    }

    @Test func sequenceScanKeepsHighestSeparateFromContiguousWatermark() {
        let scan = SequenceScan(sequences: [101, 102, 104], startingAfter: 100)
        #expect(scan.highestObserved == 104)
        #expect(scan.contiguousThrough == 102)
        #expect(scan.gaps == [SequenceGap(first: 103, last: 103)])
        #expect(!scan.isContiguous)
    }

    @Test func eventBatchRejectsMixedDeviceAndSequenceGaps() throws {
        let first = RiverDeviceID(kind: "iphone")
        let second = RiverDeviceID(kind: "mac")
        func event(_ device: RiverDeviceID, _ sequence: UInt64) -> RiverEvent {
            RiverEvent(originDeviceID: device, originSequence: sequence, observedAt: .distantPast,
                       source: "test", kind: "manual", payload: Data())
        }

        #expect(throws: RiverProtocolError.mixedDeviceBatch) {
            try RiverEventBatch(deviceID: first, events: [event(first, 1), event(second, 2)])
        }
        #expect(throws: RiverProtocolError.nonContiguousBatch) {
            try RiverEventBatch(deviceID: first, events: [event(first, 1), event(first, 3)])
        }
    }

    @Test func logicalClockBreaksSameMillisecondTiesDeterministically() {
        let iphone = RiverDeviceID(rawValue: "iphone_a")
        let mac = RiverDeviceID(rawValue: "mac_b")
        let a = HybridLogicalClock(physicalMilliseconds: 10, logicalCounter: 2, deviceID: iphone)
        let b = HybridLogicalClock(physicalMilliseconds: 10, logicalCounter: 2, deviceID: mac)
        #expect(a < b)

        var local = a
        local.observe(b, wallTimeMilliseconds: 9)
        #expect(local.physicalMilliseconds == 10)
        #expect(local.logicalCounter == 3)
        #expect(local.deviceID == iphone)
    }

    @Test func artifactResolutionUsesUserAuthorityThenDominatingFrontierThenStableTieBreak() throws {
        let device = RiverDeviceID(rawValue: "mac_a")
        let other = RiverDeviceID(rawValue: "iphone_b")
        let small = try InputFrontier(sequences: ["mac_a": 5, "iphone_b": 1])
        let large = try InputFrontier(sequences: ["mac_a": 5, "iphone_b": 2])
        func artifact(_ id: String, frontier: InputFrontier, userState: ArtifactUserState = .generated) -> RiverArtifactRevision {
            RiverArtifactRevision(
                id: id, logicalKey: "daily-review:2026-09-28", kind: .dailyReview,
                revisionNumber: 1, originDeviceID: device,
                clock: HybridLogicalClock(physicalMilliseconds: 1, deviceID: device),
                inputFrontier: frontier, inputSnapshotHash: "h", pipelineVersion: "1.0",
                promptVersion: "1", modelProvider: "test", modelIdentifier: "m",
                content: Data(id.utf8), contentHash: "hash", userState: userState
            )
        }

        let resolution = try ArtifactResolver.resolve([
            artifact("a", frontier: large),
            artifact("z", frontier: small, userState: .edited)
        ])
        #expect(resolution.canonical.id == "z")

        let another = artifact("b", frontier: large)
        let tied = try ArtifactResolver.resolve([artifact("z", frontier: large), another])
        #expect(tied.canonical.id == "b")
        #expect(tied.superseded.map(\.id) == ["z"])
        #expect(other.rawValue == "iphone_b")
    }

    @Test func artifactResolutionIsOrderIndependentWhenFrontiersAreEqual() throws {
        let device = RiverDeviceID(rawValue: "mac_a")
        let frontier = try InputFrontier(sequences: ["mac_a": 5])
        func artifact(_ id: String) -> RiverArtifactRevision {
            RiverArtifactRevision(
                id: id, logicalKey: "daily-review:2026-09-28", kind: .dailyReview,
                revisionNumber: 1, originDeviceID: device,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: device),
                inputFrontier: frontier, inputSnapshotHash: "same", pipelineVersion: "1.0",
                promptVersion: "1", modelProvider: "test", modelIdentifier: "m",
                content: Data(id.utf8), contentHash: "hash"
            )
        }
        let firstOrder = try ArtifactResolver.resolve([artifact("z"), artifact("a")])
        let reversedOrder = try ArtifactResolver.resolve([artifact("a"), artifact("z")])

        #expect(firstOrder.canonical.id == "a")
        #expect(reversedOrder.canonical.id == "a")
    }

    @Test func concurrentUserEditsAreRetainedAndNewestClockWins() throws {
        let iphone = RiverDeviceID(rawValue: "iphone_a")
        let mac = RiverDeviceID(rawValue: "mac_b")
        let empty = try InputFrontier()
        let operations = [
            StateOperation(actorDeviceID: iphone,
                           clock: HybridLogicalClock(physicalMilliseconds: 100, deviceID: iphone),
                           causalFrontier: empty, targetID: "place-1", fieldKey: "name",
                           operationType: "place.rename", payload: Data("宿舍".utf8)),
            StateOperation(actorDeviceID: mac,
                           clock: HybridLogicalClock(physicalMilliseconds: 101, deviceID: mac),
                           causalFrontier: empty, targetID: "place-1", fieldKey: "name",
                           operationType: "place.rename", payload: Data("寝室".utf8))
        ]
        let resolution = StateOperationResolver.resolve(operations)
        #expect(String(data: resolution.currentByField["place-1\u{1f}name"]!.payload, encoding: .utf8) == "寝室")
        #expect(resolution.conflicts.count == 1)
        #expect(resolution.conflicts[0].count == 2)
    }

    @Test func canonicalDigestDoesNotDependOnDeliveryOrder() {
        let a = CanonicalStateDigest.make(eventIDs: ["e2", "e1"], operationIDs: ["o1"],
                                          canonicalArtifactIDs: ["a1"], deviceFrontiers: ["mac": 2, "iphone": 7])
        let b = CanonicalStateDigest.make(eventIDs: ["e1", "e2"], operationIDs: ["o1"],
                                          canonicalArtifactIDs: ["a1"], deviceFrontiers: ["iphone": 7, "mac": 2])
        #expect(a == b)
        #expect(a.count == 64)
    }

    @Test func canonicalDigestIncludesRecordedTimeAndObservedTimezone() {
        let device = RiverDeviceID(rawValue: "iphone_a")
        let payload = Data("{}".utf8)
        let base = RiverEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            originDeviceID: device, originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 1_000),
            recordedAt: Date(timeIntervalSince1970: 1_010),
            observedTimeZoneIdentifier: "Asia/Shanghai",
            source: "test", kind: "test", payload: payload
        )
        let changedTimezone = RiverEvent(
            id: base.id, originDeviceID: device, originSequence: 1,
            observedAt: base.observedAt, recordedAt: base.recordedAt,
            observedTimeZoneIdentifier: "UTC", source: base.source, kind: base.kind,
            sourceHash: base.sourceHash, payload: payload
        )
        let frontiers = ["iphone_a:events": UInt64(1)]
        let first = CanonicalStateDigest.make(events: [base], stateOperations: [], canonicalArtifactDigests: [], deviceFrontiers: frontiers)
        let second = CanonicalStateDigest.make(events: [changedTimezone], stateOperations: [], canonicalArtifactDigests: [], deviceFrontiers: frontiers)
        #expect(first != second)
    }

    @Test func syncVerificationWaitsForEveryActivePeerAcknowledgement() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        let mac = RiverDeviceID(rawValue: "mac_b")
        let digest = "same-state"
        let phoneManifest = ReplicationManifest(
            deviceID: phone,
            ownedFrontier: StreamFrontier(events: 3, operations: 1),
            importedFrontiers: ["mac_b": StreamFrontier(events: 5, operations: 2)],
            knownDevices: [], canonicalStateDigest: digest
        )
        let macManifest = ReplicationManifest(
            deviceID: mac,
            ownedFrontier: StreamFrontier(events: 5, operations: 2),
            importedFrontiers: ["iphone_a": StreamFrontier(events: 3, operations: 1)],
            knownDevices: [], canonicalStateDigest: digest
        )
        let peers: Set<RiverDeviceID> = [phone, mac]
        #expect(SyncVerification.isVerified(manifests: [phoneManifest, macManifest], activeDeviceIDs: peers))

        let incompletePhone = ReplicationManifest(
            deviceID: phone,
            ownedFrontier: StreamFrontier(events: 3, operations: 1),
            importedFrontiers: ["mac_b": StreamFrontier(events: 4, operations: 2)],
            knownDevices: [], canonicalStateDigest: digest
        )
        #expect(!SyncVerification.isVerified(manifests: [incompletePhone, macManifest], activeDeviceIDs: peers))
        #expect(!SyncVerification.isVerified(manifests: [phoneManifest], activeDeviceIDs: peers))
        #expect(SyncVerification.isVerified(manifests: [phoneManifest], activeDeviceIDs: [phone]))
    }

    @Test func replicationDirectoryIsIdempotentAndRejectsMutationOfPublishedObject() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = ReplicationDirectory(rootURL: temporary)
        let device = RiverDeviceID(rawValue: "mac_test")
        let key = SyncEncryptionKey()
        let first = try EncryptedReplicationObject.seal(Data("batch A".utf8), id: "batch-1", kind: "event_batch", using: key)
        _ = try directory.publish(first, stream: "Events", deviceID: device)
        _ = try directory.publish(first, stream: "Events", deviceID: device)
        #expect(try directory.scan() == [first])

        let conflicting = try EncryptedReplicationObject.seal(Data("different content".utf8), id: "batch-1", kind: "event_batch", using: key)
        #expect(throws: ReplicationIOError.immutableObjectCollision("batch-1")) {
            try directory.publish(conflicting, stream: "Events", deviceID: device)
        }
    }

    @Test func sessionBuilderRepairsMissingCloseAtNextAppAndLeavesFinalOpenProvisional() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func event(_ sequence: UInt64, _ time: TimeInterval, _ kind: String, _ app: String, _ bundle: String) throws -> RiverEvent {
            RiverEvent(
                originDeviceID: phone,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: time),
                source: "shortcuts",
                kind: kind,
                payload: try JSONEncoder().encode(RiverEventPayload(appName: app, bundleID: bundle))
            )
        }
        let sessions = SessionBuilder.build([
            try event(1, 100, "app.opened", "微信", "com.tencent.xin"),
            try event(2, 400, "app.opened", "ChatGPT", "com.openai.chat")
        ])
        #expect(sessions.count == 2)
        #expect(sessions[0].duration == 300)
        #expect(sessions[0].endReason == .inferredNextApp)
        #expect(sessions[0].quality == .inferred)
        #expect(sessions[1].end == nil)
        #expect(sessions[1].duration == nil)
        #expect(sessions[1].endReason == .stillOpen)
    }

    @Test func sessionBuilderCapsUnclosedSessionWhenNextAppArrivesTooLate() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func event(_ sequence: UInt64, _ time: TimeInterval, _ app: String) throws -> RiverEvent {
            RiverEvent(
                originDeviceID: phone,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: time),
                source: "shortcuts",
                kind: "app.opened",
                payload: try JSONEncoder().encode(RiverEventPayload(appName: app, bundleID: app.lowercased()))
            )
        }
        let sessions = SessionBuilder.build([
            try event(1, 100, "微信"),
            try event(2, 10_900, "ChatGPT")
        ])

        #expect(sessions.count == 2)
        #expect(sessions[0].duration == 7_200)
        #expect(sessions[0].endReason == .durationCapped)
        #expect(sessions[1].end == nil)
    }

    @Test func sessionBuilderUsesObservedCloseAndMacSessionBoundary() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        let mac = RiverDeviceID(rawValue: "mac_b")
        func event(_ device: RiverDeviceID, _ sequence: UInt64,
                   _ time: TimeInterval, _ kind: String, _ payload: RiverEventPayload) throws -> RiverEvent {
            RiverEvent(originDeviceID: device, originSequence: sequence,
                       observedAt: Date(timeIntervalSince1970: time), source: "test", kind: kind,
                       payload: try JSONEncoder().encode(payload))
        }
        let sessions = SessionBuilder.build([
            try event(phone, 1, 100, "app.opened", RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari")),
            try event(phone, 2, 160, "app.closed", RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari")),
            try event(mac, 1, 200, "app.session", RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode", sessionEnd: Date(timeIntervalSince1970: 500)))
        ])
        #expect(sessions.count == 2)
        #expect(sessions.first(where: { $0.displayName == "Safari" })?.endReason == .observedClose)
        #expect(sessions.first(where: { $0.displayName == "Xcode" })?.duration == 300)
        #expect(sessions.first(where: { $0.displayName == "Xcode" })?.quality == .observed)
    }

    @Test func placeClusterUsesStableGroupingAndUserAuthorityOverridesMapGuess() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func event(_ sequence: UInt64, _ time: TimeInterval, _ kind: String,
                   _ latitude: Double, _ longitude: Double, _ name: String? = nil) throws -> RiverEvent {
            RiverEvent(
                originDeviceID: phone,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: time),
                source: kind == "location.placeCandidate" ? "mapkit" : "core_location",
                kind: kind,
                payload: try JSONEncoder().encode(RiverEventPayload(
                    latitude: latitude, longitude: longitude, horizontalAccuracy: 50, locationName: name,
                    mapAddress: name == nil ? nil : "上海市·长宁区", poiCategory: name == nil ? nil : "School"
                ))
            )
        }
        let first = try event(1, 100, "location.visit.arrival", 31.2304, 121.4737)
        let poi = try event(2, 110, "location.placeCandidate", 31.2305, 121.4738, "大学")
        let departure = try event(3, 3_700, "location.visit.departure", 31.2304, 121.4737)
        let id = "place:\(first.id.uuidString.lowercased())"
        let clock = HybridLogicalClock(physicalMilliseconds: 5, deviceID: phone)
        let frontier = try InputFrontier()
        let operations = [
            StateOperation(actorDeviceID: phone, clock: clock, causalFrontier: frontier,
                           targetID: id, fieldKey: "userDefinedName", operationType: "place.rename",
                           payload: try JSONEncoder().encode("宿舍")),
            StateOperation(actorDeviceID: phone,
                           clock: HybridLogicalClock(physicalMilliseconds: 6, deviceID: phone),
                           causalFrontier: frontier, targetID: id, fieldKey: "semanticType",
                           operationType: "place.confirm", payload: try JSONEncoder().encode("residence")),
            StateOperation(actorDeviceID: phone,
                           clock: HybridLogicalClock(physicalMilliseconds: 7, deviceID: phone),
                           causalFrontier: frontier, targetID: id, fieldKey: "confirmation",
                           operationType: "place.confirm", payload: try JSONEncoder().encode(true))
        ]

        let forward = PlaceClusterEngine.build(events: [first, poi, departure], userOperations: operations)
        let reverse = PlaceClusterEngine.build(events: [departure, poi, first], userOperations: operations)
        #expect(forward == reverse)
        #expect(forward.count == 1)
        #expect(forward[0].displayName == "宿舍")
        #expect(forward[0].mapName == "大学")
        #expect(forward[0].isUserConfirmed)
        #expect(forward[0].semanticType == "residence")
        #expect(forward[0].visitCount == 1)
        #expect(forward[0].totalDurationSeconds == 3_600)
    }

    @Test func sessionFusionNestsShortPhoneInterruptionInsideLongerMacActivity() {
        let mac = RiverDeviceID(rawValue: "mac_b")
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func session(_ id: String, _ device: RiverDeviceID, _ start: TimeInterval, _ end: TimeInterval) -> RiverAppSession {
            RiverAppSession(
                id: id, originDeviceID: device, applicationIdentifier: id, displayName: id,
                start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                endReason: .observedClose, quality: .observed, evidenceEventIDs: []
            )
        }
        let macWork = session("work", mac, 100, 1_900)
        let phoneChat = session("chat", phone, 820, 1_000)
        let groups = SessionFusionEngine.fuse([phoneChat, macWork])
        #expect(groups.count == 1)
        #expect(groups[0].primary.id == "work")
        #expect(groups[0].secondary.map(\.id) == ["chat"])
        #expect(groups[0].primary.duration == 1_800)
    }

    @Test func analysisJobsHaveStableIdentityAndPriorityOrdering() throws {
        let device = RiverDeviceID(rawValue: "iphone_jobs")
        let frontier = try InputFrontier(sequences: [device.rawValue: 4], operationSequences: [device.rawValue: 2])
        let firstID = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, pipelineVersion: "1.0", promptVersion: "1"
        )
        let secondID = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, pipelineVersion: "1.0", promptVersion: "1"
        )
        #expect(firstID == secondID)
        let requestA = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, pipelineVersion: "1.0", promptVersion: "1", requestFingerprint: "request-a"
        )
        let requestB = RiverAnalysisJobScheduler.jobID(
            deviceID: device, logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, pipelineVersion: "1.0", promptVersion: "1", requestFingerprint: "request-b"
        )
        #expect(requestA != requestB)

        let lowPriority = RiverAnalysisJob(
            id: UUID(), logicalKey: "low", artifactType: .insight, inputFrontier: frontier,
            priority: 1, createdAt: Date(timeIntervalSince1970: 1), originDeviceID: device,
            pipelineVersion: "1", promptVersion: "1"
        )
        let snapshot = Data("exact system + user prompt".utf8)
        let highPriority = RiverAnalysisJob(
            id: UUID(), logicalKey: "high", artifactType: .dailyReview, inputFrontier: frontier,
            priority: 5, createdAt: Date(timeIntervalSince1970: 2), originDeviceID: device,
            pipelineVersion: "1", promptVersion: "1", requestSnapshot: snapshot,
            requestFingerprint: "snapshot-hash"
        )
        #expect(RiverAnalysisJobScheduler.nextQueuedJob(from: [lowPriority, highPriority])?.id == highPriority.id)
        #expect(highPriority.transitioning(to: .running).requestSnapshot == snapshot)
        #expect(highPriority.transitioning(to: .running).requestFingerprint == "snapshot-hash")
        #expect(highPriority.transitioning(to: .succeeded).requestSnapshot == nil)
        #expect(RiverAnalysisJobScheduler.canResume(
            highPriority, at: frontier, pipelineVersion: "1", requestFingerprint: "snapshot-hash"
        ))
        #expect(!RiverAnalysisJobScheduler.canResume(
            highPriority, at: try InputFrontier(sequences: [device.rawValue: 5], operationSequences: [device.rawValue: 2]),
            pipelineVersion: "1", requestFingerprint: "snapshot-hash"
        ))
    }

    @Test func artifactResolverDoesNotUseProviderOrModelAsArtifactIdentity() throws {
        let device = RiverDeviceID(rawValue: "mac_artifact_identity")
        let frontier = try InputFrontier(sequences: [device.rawValue: 9])
        let contentA = Data("same canonical payload".utf8)
        func revision(id: String, provider: String, model: String) -> RiverArtifactRevision {
            RiverArtifactRevision(
                id: id, logicalKey: RiverCanonicalArtifactKey.dailyReview(dayKey: "2026-09-28"),
                kind: .dailyReview, revisionNumber: 3, originDeviceID: device,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: device),
                inputFrontier: frontier, inputSnapshotHash: "same-input", pipelineVersion: "1.0",
                promptVersion: "1", modelProvider: provider, modelIdentifier: model,
                content: contentA, contentHash: SHA256.hash(data: contentA).map { String(format: "%02x", $0) }.joined()
            )
        }
        let providerHeavy = revision(id: "z", provider: "A-provider", model: "A-model")
        let stableIDWinner = revision(id: "a", provider: "Z-provider", model: "Z-model")
        #expect(try ArtifactResolver.resolve([providerHeavy, stableIDWinner]).canonical.id == "a")
        #expect(try ArtifactResolver.resolve([stableIDWinner, providerHeavy]).canonical.id == "a")
    }

    @Test func sharedHabitStateRecordKeepsPortableIdentityAndPayload() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let record = RiverSharedStateRecord(
            id: id, kind: .habitCard, status: "shown", logicalKey: "weekly|pattern:com.example.app",
            payloadJSON: "{\"question\":\"是否算作工作？\"}",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20),
            batchID: UUID(uuidString: "00000000-0000-0000-0000-000000000456")
        )
        let decoded = try JSONDecoder().decode(RiverSharedStateRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.targetID == "user-record:habitCard:\(id.uuidString.lowercased())")
        #expect(RiverCanonicalArtifactKey.dailyReview(dayKey: "2026-09-28") == "daily-review:2026-09-28")
    }

    @Test func onlyUserDecisionsInvalidateGeneratedAnalysisFrontiers() throws {
        let device = RiverDeviceID(rawValue: "iphone_state")
        let frontier = try InputFrontier()
        let pendingCard = RiverSharedStateRecord(
            id: UUID(), kind: .habitCard, status: "bundled", logicalKey: "week|pattern:app",
            payloadJSON: "{}", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1)
        )
        let answeredCard = RiverSharedStateRecord(
            id: pendingCard.id, kind: .habitCard, status: "answered", logicalKey: pendingCard.logicalKey,
            payloadJSON: "{\"answerKind\":\"onlyTheseExamples\"}",
            createdAt: pendingCard.createdAt, updatedAt: Date(timeIntervalSince1970: 2)
        )
        func operation(_ record: RiverSharedStateRecord, sequence: UInt64) -> StateOperation {
            StateOperation(
                actorDeviceID: device, originSequence: sequence,
                clock: HybridLogicalClock(physicalMilliseconds: sequence, deviceID: device),
                causalFrontier: frontier, targetID: record.targetID, fieldKey: "record",
                operationType: "shared.record.upsert", payload: (try? JSONEncoder().encode(record)) ?? Data()
            )
        }
        #expect(!RiverStateOperationFreshness.changesAnalyticalState(operation(pendingCard, sequence: 1)))
        #expect(RiverStateOperationFreshness.changesAnalyticalState(operation(answeredCard, sequence: 2)))
    }

    @Test func placeConfirmationIsStableAndUserResolutionChangesAnalyticalState() throws {
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let place = RiverPlace(
            id: "place:stable-first-event", latitude: 31.2, longitude: 121.4, radiusMeters: 20,
            mapName: "长宁图书馆", mapAddress: "上海市长宁区", poiCategory: "library",
            mapProvider: "MapKit", mapResultIdentifier: "map-item-1", userDefinedName: nil,
            semanticType: nil, isUserConfirmed: false, confidence: 0.75,
            firstSeen: firstSeen, lastSeen: firstSeen.addingTimeInterval(86_400),
            visitCount: 2, totalDurationSeconds: 3_600
        )

        let pending = try #require(RiverSharedStateRecord.placeCandidate(place))
        let repeated = try #require(RiverSharedStateRecord.placeCandidate(place))
        #expect(pending == repeated)
        #expect(pending.targetID == "user-record:pendingConfirmation:\(pending.id.uuidString.lowercased())")
        #expect(pending.pendingConfirmationContent?.question == "这里是「长宁图书馆」吗？")
        #expect(RiverSharedStateRecord.placeCandidate(RiverPlace(
            id: "one-visit", latitude: 31.2, longitude: 121.4, radiusMeters: 20,
            mapName: "长宁图书馆", mapAddress: nil, poiCategory: "library", mapProvider: "MapKit",
            mapResultIdentifier: nil, userDefinedName: nil, semanticType: nil,
            isUserConfirmed: false, confidence: 0.75, firstSeen: firstSeen, lastSeen: firstSeen,
            visitCount: 1, totalDurationSeconds: 0
        )) == nil)

        let confirmed = try #require(pending.resolving(.confirmed, at: firstSeen.addingTimeInterval(10)))
        #expect(confirmed.id == pending.id)
        #expect(confirmed.status == "confirmed")
        let device = RiverDeviceID(rawValue: "iphone_confirmation")
        let operation = StateOperation(
            actorDeviceID: device, originSequence: 1,
            clock: HybridLogicalClock(physicalMilliseconds: 1, deviceID: device),
            causalFrontier: try InputFrontier(), targetID: confirmed.targetID, fieldKey: "record",
            operationType: "shared.record.upsert", payload: try JSONEncoder().encode(confirmed)
        )
        #expect(RiverStateOperationFreshness.changesAnalyticalState(operation))
    }

    @Test func journalAndMonthlyLetterRecordsUseStableSharedIdentity() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = RiverJournalEntryContent(
            dayKey: "2026-09-28", body: "完成了跨设备日记", moodScore: 82,
            category: "记录", tags: ["工作", "回顾"], updatedAt: createdAt
        )
        let first = try #require(RiverSharedStateRecord.journalEntry(entry))
        let second = try #require(RiverSharedStateRecord.journalEntry(entry))
        #expect(first == second)
        #expect(first.logicalKey == "2026-09-28")
        #expect(first.journalEntryContent == entry)

        let letter = RiverMonthlyLetterContent(
            monthKey: "2026-09", title: "写给自己的河流信", body: "把值得记住的事留下。",
            evidence: "2 天日记", createdAt: createdAt, updatedAt: createdAt
        )
        let sharedLetter = try #require(RiverSharedStateRecord.monthlyLetter(letter))
        #expect(sharedLetter.monthlyLetterContent == letter)
        #expect(sharedLetter.logicalKey == "2026-09")
    }

    @Test func unknownSharedRecordKindSurvivesDecodeAndReencoding() throws {
        let record = RiverSharedStateRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000999")!,
            kind: .habitRule, status: "current", logicalKey: "future-record",
            payloadJSON: "{\"futureField\":\"preserve me\"}",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let original = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["kind"] = "future.semanticConfirmation"
        let futurePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(RiverSharedStateRecord.self, from: futurePayload)
        #expect(decoded.kind.rawValue == "future.semanticConfirmation")
        let reencoded = try JSONDecoder().decode(RiverSharedStateRecord.self, from: JSONEncoder().encode(decoded))
        #expect(reencoded.kind.rawValue == "future.semanticConfirmation")
        #expect(reencoded.payloadJSON == record.payloadJSON)
    }

    @Test func timelineClarificationUsesSharedAnnotationIdentityAndEvidence() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(RiverSharedStateRecord.timelineClarification(
            candidateID: "activity-session-123", annotationKey: "1700000000|com.example.editor|Editor",
            observation: "这段时间主要使用了编辑器。", opening: "当时在编辑什么内容？",
            evidenceRefs: ["raw:event-2", "raw:event-1"], createdAt: date
        ))
        let second = try #require(RiverSharedStateRecord.timelineClarification(
            candidateID: "activity-session-123", annotationKey: "1700000000|com.example.editor|Editor",
            observation: "这段时间主要使用了编辑器。", opening: "当时在编辑什么内容？",
            evidenceRefs: ["raw:event-1", "raw:event-2"], createdAt: date
        ))
        #expect(first == second)
        #expect(first.pendingConfirmationContent?.targetType == "timelineCandidate")
        #expect(first.pendingConfirmationContent?.targetID == "1700000000|com.example.editor|Editor")
        #expect(first.pendingConfirmationContent?.evidenceRefs == ["raw:event-1", "raw:event-2"])
    }

    @Test func quickCaptureMetadataRecordHasStableIdentityAndSharedPinState() throws {
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000654")!
        let content = RiverQuickCaptureMetadata(
            eventID: eventID, tag: "灵感", isPinned: true, updatedAt: Date(timeIntervalSince1970: 100)
        )
        let first = try #require(RiverSharedStateRecord.quickCaptureMetadata(content))
        let second = try #require(RiverSharedStateRecord.quickCaptureMetadata(content))
        #expect(first == second)
        #expect(first.quickCaptureMetadata == content)
        #expect(first.logicalKey == eventID.uuidString.lowercased())
        #expect(RiverStateOperationFreshness.changesAnalyticalState(StateOperation(
            actorDeviceID: RiverDeviceID(rawValue: "mac_capture"),
            clock: HybridLogicalClock(physicalMilliseconds: 100, deviceID: RiverDeviceID(rawValue: "mac_capture")),
            causalFrontier: try InputFrontier(), targetID: first.targetID, fieldKey: "record",
            operationType: "shared.record.upsert", payload: try JSONEncoder().encode(first)
        )))
    }

    @Test func analysisFingerprintsSeparateArtifactInputsFromProviderRequestIdentity() throws {
        let frontier = try InputFrontier(sequences: ["iphone_test": 12], operationSequences: ["iphone_test": 4])
        let artifactFingerprint = RiverAnalysisFingerprints.artifactInput(
            frontier: frontier, systemPrompt: "system", userPrompt: "private daily prompt"
        )
        #expect(artifactFingerprint == RiverAnalysisFingerprints.artifactInput(
            frontier: frontier, systemPrompt: "system", userPrompt: "private daily prompt"
        ))
        #expect(artifactFingerprint != RiverAnalysisFingerprints.artifactInput(
            frontier: try InputFrontier(sequences: ["iphone_test": 13], operationSequences: ["iphone_test": 4]),
            systemPrompt: "system", userPrompt: "private daily prompt"
        ))

        let localRequest = RiverAnalysisFingerprints.request(
            endpoint: "http://localhost:11434/v1/chat/completions", model: "llama3.2",
            systemPrompt: "system", userPrompt: "private daily prompt", temperature: 0.2, maxTokens: 900
        )
        #expect(localRequest == RiverAnalysisFingerprints.request(
            endpoint: "http://localhost:11434/v1/chat/completions", model: "llama3.2",
            systemPrompt: "system", userPrompt: "private daily prompt", temperature: 0.2, maxTokens: 900
        ))
        #expect(localRequest != RiverAnalysisFingerprints.request(
            endpoint: "https://api.example.test/v1/chat/completions", model: "llama3.2",
            systemPrompt: "system", userPrompt: "private daily prompt", temperature: 0.2, maxTokens: 900
        ))
        #expect(localRequest != RiverAnalysisFingerprints.request(
            endpoint: "http://localhost:11434/v1/chat/completions", model: "other-model",
            systemPrompt: "system", userPrompt: "private daily prompt", temperature: 0.2, maxTokens: 900
        ))
        #expect(localRequest != RiverAnalysisFingerprints.request(
            endpoint: "http://localhost:11434/v1/chat/completions", model: "llama3.2",
            systemPrompt: "system", userPrompt: "updated private daily prompt", temperature: 0.2, maxTokens: 900
        ))
    }
}
