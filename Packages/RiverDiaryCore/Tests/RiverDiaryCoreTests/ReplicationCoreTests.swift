import CryptoKit
import Foundation
import Testing
@testable import RiverDiaryCore

struct ReplicationCoreTests {
    @Test func qaBundleIdentifiersUseIsolatedKeychainServices() {
        #expect(RiverSecureStore.keychainServiceName(
            "local.riverdiary.node", bundleIdentifier: "studio.riverdiary.ios.qa"
        ) == "local.riverdiary.node.qa")
        #expect(RiverSecureStore.keychainServiceName(
            "RiverDiaryMac.state", bundleIdentifier: "studio.riverdiary.mac.qa"
        ) == "RiverDiaryMac.state.qa")
        #expect(RiverSecureStore.keychainServiceName(
            "local.riverdiary.node", bundleIdentifier: "local.riverdiary.app"
        ) == "local.riverdiary.node")
    }

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
        let legacyJournal = try #require(RiverSharedStateRecord.journalEntry(RiverJournalEntryContent(
            dayKey: "2026-09-28", body: "legacy diary backup payload",
            source: "legacy-data.json", updatedAt: Date(timeIntervalSince1970: 90)
        )))
        let journalOperation = StateOperation(
            actorDeviceID: device,
            originSequence: 1,
            clock: HybridLogicalClock(physicalMilliseconds: 90_000, deviceID: device),
            causalFrontier: try InputFrontier(),
            targetID: legacyJournal.targetID,
            fieldKey: "record",
            operationType: "shared.record.upsert",
            payload: try JSONEncoder().encode(legacyJournal)
        )
        let backup = RiverNodeBackup(
            sourceDeviceID: device,
            events: [event],
            stateOperations: [journalOperation],
            artifactRevisions: [],
            deviceRegistrations: []
        )
        #expect(backup.isSupported)
        #expect(!RiverNodeBackup(
            protocolVersion: 0, sourceDeviceID: device, events: [],
            stateOperations: [], artifactRevisions: [], deviceRegistrations: []
        ).isSupported)
        #expect(!RiverNodeBackup(
            protocolVersion: RiverNodeBackup.currentProtocolVersion + 1,
            sourceDeviceID: device, events: [], stateOperations: [], artifactRevisions: [], deviceRegistrations: []
        ).isSupported)
        #expect(!RiverNodeBackup(
            schemaVersion: RiverNodeBackup.currentSchemaVersion + 1,
            sourceDeviceID: device, events: [], stateOperations: [], artifactRevisions: [], deviceRegistrations: []
        ).isSupported)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SyncEncryptionKey()
        let transferredKey = try SyncEncryptionKey(importCode: key.exportCode)
        let encrypted = try EncryptedReplicationObject.seal(
            encoder.encode(backup), id: "local-backup-test", kind: "local_backup", using: key
        )
        #expect(encrypted.ciphertext.range(of: Data("private note".utf8)) == nil)
        #expect(encrypted.ciphertext.range(of: Data("legacy diary backup payload".utf8)) == nil)
        let restored = try JSONDecoder().decode(RiverNodeBackup.self, from: encrypted.open(using: transferredKey))
        #expect(restored == backup)
        let restoredJournal = try JSONDecoder().decode(
            RiverSharedStateRecord.self, from: restored.stateOperations[0].payload
        )
        #expect(restoredJournal.journalEntryContent?.body == "legacy diary backup payload")
        #expect(throws: Error.self) { try encrypted.open(using: SyncEncryptionKey()) }
    }

    @Test func coordinatedFileIOReadsAndAtomicallyWritesSelectedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-coordinated-io-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("RiverDiary.riverbackup")
        let contents = Data("coordinated backup payload".utf8)

        try CoordinatedFileIO.writeAtomically(contents, to: file)

        #expect(try CoordinatedFileIO.read(file) == contents)
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

    @Test func sessionBuilderIgnoresNonAppEventsWhenResolvingOpenSessions() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        let opened = RiverEvent(
            originDeviceID: phone,
            originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 100),
            source: "shortcuts",
            kind: "app.opened",
            payload: try JSONEncoder().encode(RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"))
        )
        let location = RiverEvent(
            originDeviceID: phone,
            originSequence: 2,
            observedAt: Date(timeIntervalSince1970: 10_900),
            source: "core_location",
            kind: "location.visit.arrival",
            payload: try JSONEncoder().encode(RiverEventPayload(latitude: 37.0, longitude: -122.0))
        )

        let session = try #require(SessionBuilder.build([opened, location]).first)
        #expect(session.end == nil)
        #expect(session.endReason == .stillOpen)
    }

    @Test func sessionBuilderResultsCanBeRebuiltIndependentlyPerDevice() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        let mac = RiverDeviceID(rawValue: "mac_b")
        func event(_ device: RiverDeviceID, _ sequence: UInt64, _ time: TimeInterval,
                   _ kind: String, _ app: String) throws -> RiverEvent {
            RiverEvent(
                originDeviceID: device,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: time),
                source: "shortcuts",
                kind: kind,
                payload: try JSONEncoder().encode(RiverEventPayload(appName: app, bundleID: app.lowercased()))
            )
        }
        let events = [
            try event(phone, 1, 100, "app.opened", "Safari"),
            try event(phone, 2, 200, "app.closed", "Safari"),
            try event(mac, 1, 150, "app.opened", "Xcode"),
            try event(mac, 2, 500, "app.opened", "Notes"),
        ]
        let combined = SessionBuilder.build(events)
        let byDevice = [phone, mac].flatMap { device in
            SessionBuilder.build(events.filter { $0.originDeviceID == device })
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }

        #expect(combined == byDevice)
    }

    @Test func sessionBuilderAppendsMonotonicTailEquivalentToFullRebuild() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func event(_ sequence: UInt64, _ time: TimeInterval, _ kind: String, _ app: String) throws -> RiverEvent {
            RiverEvent(
                originDeviceID: phone,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: time),
                source: "shortcuts",
                kind: kind,
                payload: try JSONEncoder().encode(RiverEventPayload(appName: app, bundleID: app.lowercased()))
            )
        }
        let first = try event(1, 100, "app.opened", "Safari")
        let tail = [
            try event(2, 102, "app.opened", "Safari"),
            try event(3, 10_900, "app.opened", "Xcode"),
            try event(4, 10_960, "app.closed", "Xcode"),
        ]
        let initial = SessionBuilder.snapshot([first], for: phone)
        let incremental = try #require(SessionBuilder.appending(tail, to: initial))
        let rebuilt = SessionBuilder.snapshot([first] + tail, for: phone)
        var merged = Dictionary(uniqueKeysWithValues: initial.sessions.map { ($0.id, $0) })
        for session in incremental.changedSessions { merged[session.id] = session }
        let incrementallyRebuilt = RiverSessionProjectionSnapshot(
            deviceID: phone,
            sessions: merged.values.sorted { $0.start < $1.start },
            activeSession: incremental.activeSession,
            lastSessionSequence: incremental.lastSessionSequence,
            latestSessionObservedAt: incremental.latestSessionObservedAt
        )

        #expect(incrementallyRebuilt == rebuilt)
        #expect(incremental.changedSessions.first { $0.displayName == "Safari" }?.endReason == .durationCapped)
        #expect(incremental.changedSessions.first { $0.displayName == "Safari" }?.evidenceEventIDs.count == 3)
        #expect(incremental.changedSessions.first { $0.displayName == "Xcode" }?.endReason == .observedClose)
    }

    @Test func sessionBuilderRejectsOutOfOrderTailForFullRebuild() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        let first = RiverEvent(
            originDeviceID: phone,
            originSequence: 2,
            observedAt: Date(timeIntervalSince1970: 100),
            source: "shortcuts",
            kind: "app.opened",
            payload: try JSONEncoder().encode(RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"))
        )
        let late = RiverEvent(
            originDeviceID: phone,
            originSequence: 3,
            observedAt: Date(timeIntervalSince1970: 90),
            source: "shortcuts",
            kind: "app.closed",
            payload: try JSONEncoder().encode(RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"))
        )
        let snapshot = SessionBuilder.snapshot([first], for: phone)

        #expect(SessionBuilder.appending([late], to: snapshot) == nil)
    }

    @Test func incrementalProjectionKeepsOpenStateBehindItsCappedDisplayRow() throws {
        let phone = RiverDeviceID(rawValue: "iphone_a")
        func event(_ sequence: UInt64, _ time: TimeInterval, _ kind: String,
                   _ payload: RiverEventPayload) throws -> RiverEvent {
            RiverEvent(originDeviceID: phone, originSequence: sequence,
                       observedAt: Date(timeIntervalSince1970: time), source: "test", kind: kind,
                       payload: try JSONEncoder().encode(payload))
        }
        let opened = try event(1, 100, "app.opened", RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"))
        let boundary = try event(2, 10_900, "app.session", RiverEventPayload(
            appName: "Console", bundleID: "com.apple.console",
            sessionEnd: Date(timeIntervalSince1970: 10_930)
        ))
        let nextOpen = try event(3, 10_960, "app.opened", RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode"))

        let first = SessionBuilder.snapshot([opened], for: phone)
        let afterBoundary = try #require(SessionBuilder.appending([boundary], to: first))
        var afterBoundarySessions = Dictionary(uniqueKeysWithValues: first.sessions.map { ($0.id, $0) })
        for session in afterBoundary.changedSessions { afterBoundarySessions[session.id] = session }
        #expect(afterBoundarySessions["session:\(opened.id.uuidString.lowercased())"]?.endReason == .durationCapped)
        #expect(afterBoundary.activeSession?.id == "session:\(opened.id.uuidString.lowercased())")
        let cappedSnapshot = RiverSessionProjectionSnapshot(
            deviceID: phone,
            sessions: Array(afterBoundarySessions.values),
            activeSession: afterBoundary.activeSession,
            lastSessionSequence: afterBoundary.lastSessionSequence,
            latestSessionObservedAt: afterBoundary.latestSessionObservedAt
        )
        let incrementallyUpdated = try #require(SessionBuilder.appending([nextOpen], to: cappedSnapshot))
        let fullyRebuilt = SessionBuilder.snapshot([opened, boundary, nextOpen], for: phone)
        var finalSessions = afterBoundarySessions
        for session in incrementallyUpdated.changedSessions { finalSessions[session.id] = session }
        let incrementallyRebuilt = RiverSessionProjectionSnapshot(
            deviceID: phone,
            sessions: finalSessions.values.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            },
            activeSession: incrementallyUpdated.activeSession,
            lastSessionSequence: incrementallyUpdated.lastSessionSequence,
            latestSessionObservedAt: incrementallyUpdated.latestSessionObservedAt
        )

        #expect(incrementallyRebuilt == fullyRebuilt)
        #expect(finalSessions["session:\(opened.id.uuidString.lowercased())"]?.evidenceEventIDs.contains(nextOpen.id) == true)
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

        let changedFrontier = try InputFrontier(sequences: [device.rawValue: 5], operationSequences: [device.rawValue: 2])
        let interruptedDailyReview = RiverAnalysisJob(
            id: UUID(), logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, status: .running, originDeviceID: device,
            pipelineVersion: "1.0|network|model|endpoint", promptVersion: "1",
            requestSnapshot: snapshot, requestFingerprint: "snapshot-hash"
        )
        #expect(RiverAnalysisJobScheduler.needsCurrentInputRebuild(
            [interruptedDailyReview], logicalKey: interruptedDailyReview.logicalKey,
            currentFrontier: changedFrontier, pipelineVersion: interruptedDailyReview.pipelineVersion,
            hasCurrentArtifact: false
        ))
        #expect(!RiverAnalysisJobScheduler.needsCurrentInputRebuild(
            [interruptedDailyReview], logicalKey: interruptedDailyReview.logicalKey,
            currentFrontier: changedFrontier, pipelineVersion: interruptedDailyReview.pipelineVersion,
            hasCurrentArtifact: true
        ))
        #expect(!RiverAnalysisJobScheduler.needsCurrentInputRebuild(
            [interruptedDailyReview], logicalKey: interruptedDailyReview.logicalKey,
            currentFrontier: changedFrontier, pipelineVersion: "new-pipeline",
            hasCurrentArtifact: false
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

    @Test func deletedSharedMemoryOutranksConcurrentGeneratedCandidate() throws {
        let device = RiverDeviceID(rawValue: "iphone_memory_delete")
        let frontier = try InputFrontier()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000777")!
        let candidate = RiverSharedStateRecord(
            id: id, kind: .memory, status: "candidate", logicalKey: id.uuidString.lowercased(),
            payloadJSON: "{\"title\":\"River 记忆候选\",\"body\":\"candidate\"}",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10)
        )
        let deleted = RiverSharedStateRecord(
            id: id, kind: .memory, status: "deleted", logicalKey: candidate.logicalKey,
            payloadJSON: candidate.payloadJSON,
            createdAt: candidate.createdAt, updatedAt: Date(timeIntervalSince1970: 20)
        )
        func operation(_ record: RiverSharedStateRecord, sequence: UInt64) throws -> StateOperation {
            StateOperation(
                actorDeviceID: device, originSequence: sequence,
                clock: HybridLogicalClock(physicalMilliseconds: sequence, deviceID: device),
                causalFrontier: frontier, targetID: record.targetID, fieldKey: "record",
                operationType: "shared.record.upsert", payload: try JSONEncoder().encode(record)
            )
        }
        let generated = try operation(candidate, sequence: 1)
        let deletion = try operation(deleted, sequence: 2)
        let key = "\(candidate.targetID)\u{1f}record"

        for operations in [[generated, deletion], [deletion, generated]] {
            let current = try #require(StateOperationResolver.resolve(operations).currentByField[key])
            let record = try JSONDecoder().decode(RiverSharedStateRecord.self, from: current.payload)
            #expect(record.status == "deleted")
        }
        #expect(RiverStateOperationFreshness.changesAnalyticalState(deletion))
    }

    @Test func explicitUserReopenOutranksThePreviouslyAnsweredQuestion() throws {
        let device = RiverDeviceID(rawValue: "iphone_question_reopen")
        let frontier = try InputFrontier()
        let createdAt = Date(timeIntervalSince1970: 10)
        let questionContent = RiverPendingConfirmationContent(
            title: "时间线理解", question: "这段记录通常代表什么？", candidate: "写作"
        )
        let questionPayload = String(decoding: try JSONEncoder().encode(questionContent), as: UTF8.self)
        let pending = RiverSharedStateRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000779")!,
            kind: .pendingConfirmation, status: "pending", logicalKey: "question:reopen",
            payloadJSON: questionPayload, createdAt: createdAt, updatedAt: createdAt
        )
        let answered = try #require(pending.resolving(.confirmed, at: Date(timeIntervalSince1970: 20)))
        let reopened = try #require(answered.reopened(at: Date(timeIntervalSince1970: 30)))
        func operation(_ record: RiverSharedStateRecord, sequence: UInt64) throws -> StateOperation {
            StateOperation(
                actorDeviceID: device, originSequence: sequence,
                clock: HybridLogicalClock(physicalMilliseconds: sequence, deviceID: device),
                causalFrontier: frontier, targetID: record.targetID, fieldKey: "record",
                operationType: "shared.record.upsert", payload: try JSONEncoder().encode(record)
            )
        }
        let resolvedOperation = try operation(answered, sequence: 1)
        let reopenedOperation = try operation(reopened, sequence: 2)
        let reanswered = try #require(reopened.resolving(.corrected, correction: "阅读", at: Date(timeIntervalSince1970: 40)))
        let reansweredOperation = try operation(reanswered, sequence: 3)
        let key = "\(pending.targetID)\u{1f}record"
        for operations in [[resolvedOperation, reopenedOperation], [reopenedOperation, resolvedOperation]] {
            let current = try #require(StateOperationResolver.resolve(operations).currentByField[key])
            let record = try JSONDecoder().decode(RiverSharedStateRecord.self, from: current.payload)
            #expect(record.status == "pending")
            #expect(record.pendingConfirmationContent?.userReopenedAt != nil)
        }
        let finalQuestion = try #require(StateOperationResolver.resolve([
            resolvedOperation, reopenedOperation, reansweredOperation
        ]).currentByField[key])
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: finalQuestion.payload).status == "corrected")
        #expect(RiverStateOperationFreshness.changesAnalyticalState(reopenedOperation))

        let answeredHabit = RiverSharedStateRecord(
            id: UUID(), kind: .habitCard, status: "answered", logicalKey: "habit:reopen",
            payloadJSON: "{\"answerKind\":\"longTermRule\"}", createdAt: createdAt, updatedAt: createdAt
        )
        let reopenedHabit = RiverSharedStateRecord(
            id: answeredHabit.id, kind: .habitCard, status: "shown", logicalKey: answeredHabit.logicalKey,
            payloadJSON: "{\"userReopenedAt\":\"1970-01-01T00:00:30Z\"}",
            createdAt: createdAt, updatedAt: Date(timeIntervalSince1970: 30)
        )
        let answeredHabitOperation = try operation(answeredHabit, sequence: 3)
        let reopenedHabitOperation = try operation(reopenedHabit, sequence: 4)
        let reansweredHabit = RiverSharedStateRecord(
            id: answeredHabit.id, kind: .habitCard, status: "answered", logicalKey: answeredHabit.logicalKey,
            payloadJSON: "{\"answerKind\":\"conversation\",\"userReopenedAt\":\"1970-01-01T00:00:30Z\"}",
            createdAt: createdAt, updatedAt: Date(timeIntervalSince1970: 40)
        )
        let reansweredHabitOperation = try operation(reansweredHabit, sequence: 5)
        let habitKey = "\(answeredHabit.targetID)\u{1f}record"
        let currentHabit = try #require(StateOperationResolver.resolve([
            answeredHabitOperation, reopenedHabitOperation, reansweredHabitOperation
        ]).currentByField[habitKey])
        #expect(try JSONDecoder().decode(RiverSharedStateRecord.self, from: currentHabit.payload).status == "answered")
        #expect(RiverStateOperationFreshness.changesAnalyticalState(reopenedHabitOperation))
    }

    @Test func placeConfirmationIsStableAndUserResolutionChangesAnalyticalState() throws {
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        // 新判定门槛：停留 ≥180 秒、≥2 个商户候选、最近候选 ≤120m
        // 且与次近差距 ≤ max(45, 最近水平精度×0.6)。
        let closest = RiverPlaceCandidate(
            name: "长宁图书馆", address: "上海市长宁区", category: "library", provider: "MapKit",
            resultIdentifier: "map-item-1", distanceMeters: 30, horizontalAccuracyMeters: 50
        )
        let next = RiverPlaceCandidate(
            name: "隔壁咖啡馆", address: "上海市长宁区", category: "cafe", provider: "MapKit",
            resultIdentifier: "map-item-2", distanceMeters: 75, horizontalAccuracyMeters: 50
        )
        let place = RiverPlace(
            id: "place:stable-first-event", latitude: 31.2, longitude: 121.4, radiusMeters: 20,
            mapName: "长宁图书馆", mapAddress: "上海市长宁区", poiCategory: "library",
            mapProvider: "MapKit", mapResultIdentifier: "map-item-1", userDefinedName: nil,
            semanticType: nil, isUserConfirmed: false, confidence: 0.75,
            firstSeen: firstSeen, lastSeen: firstSeen.addingTimeInterval(86_400),
            visitCount: 2, totalDurationSeconds: 3_600,
            mapCandidates: [next, closest]
        )

        let pending = try #require(RiverSharedStateRecord.placeCandidate(place))
        let repeated = try #require(RiverSharedStateRecord.placeCandidate(place))
        #expect(pending == repeated)
        #expect(pending.targetID == "user-record:pendingConfirmation:\(pending.id.uuidString.lowercased())")
        #expect(pending.pendingConfirmationContent?.question == "附近有几家商户，选一个最符合的就行。")
        #expect(pending.pendingConfirmationContent?.candidate == "长宁图书馆")
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

    @Test func monthlyLetterDraftUsesStableSharedIdentityAndDeletionChangesState() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let content = RiverMonthlyLetterDraftContent(monthKey: "2026-09", body: "尚未保存的河流信。", updatedAt: date)
        let first = try #require(RiverSharedStateRecord.monthlyLetterDraft(content))
        let second = try #require(RiverSharedStateRecord.monthlyLetterDraft(content))
        #expect(first == second)
        #expect(first.kind == .monthlyLetterDraft)
        #expect(first.logicalKey == "2026-09")
        #expect(first.monthlyLetterDraftContent == content)

        let actor = RiverDeviceID(rawValue: "mac_letter_draft")
        func operation(for record: RiverSharedStateRecord) throws -> StateOperation {
            try StateOperation(
                actorDeviceID: actor,
                clock: HybridLogicalClock(physicalMilliseconds: 1_800_000_000_000, deviceID: actor),
                causalFrontier: InputFrontier(),
                targetID: record.targetID,
                fieldKey: "record",
                operationType: "shared.record.upsert",
                payload: JSONEncoder().encode(record)
            )
        }
        #expect(RiverStateOperationFreshness.changesAnalyticalState(try operation(for: first)))
        let deletion = try #require(RiverSharedStateRecord.monthlyLetterDraft(
            RiverMonthlyLetterDraftContent(monthKey: "2026-09", body: "", updatedAt: date.addingTimeInterval(10)),
            status: "deleted"
        ))
        #expect(deletion.id == first.id)
        #expect(RiverStateOperationFreshness.changesAnalyticalState(try operation(for: deletion)))
    }
}
