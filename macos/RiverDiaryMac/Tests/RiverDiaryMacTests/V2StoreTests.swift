import XCTest
import RiverDiaryCore
import SQLCipher
@testable import RiverDiaryMac

@MainActor
final class V2StoreTests: XCTestCase {

    private let expectedTables = [
        "activities", "analysis_jobs", "analysis_runs", "artifacts", "artifact_dependencies", "context_snapshots",
        "devices", "episode_annotations", "episodes", "habit_batches", "habit_cards", "habit_rules",
        "memories", "memory_confirmations", "places", "raw_events", "state_operations", "sync_exports",
        "sync_imports", "sync_state", "user_prefs",
    ]

    private func makeStore() throws -> (V2Store, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("river-v2.db")
        return (V2Store(databaseURL: url), url)
    }

    func testSchemaCreatesAllTables() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.databaseSchemaVersion, 2)
        let tables = store.tableNames()
        for table in expectedTables {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
        let indices = store.indexNames()
        XCTAssertTrue(indices.contains("idx_raw_events_ts"))
        XCTAssertTrue(indices.contains("idx_episodes_times"))
    }

    func testDatabaseAndParentDirectoryAreRestrictedToCurrentAccount() throws {
        let (store, databaseURL) = try makeStore()

        XCTAssertEqual(
            try LocalStorageProtection.permissions(at: databaseURL.deletingLastPathComponent()) ?? 0,
            0o700
        )
        XCTAssertEqual(try LocalStorageProtection.permissions(at: databaseURL) ?? 0, 0o600)
        XCTAssertEqual(store.countRows(in: .rawEvents), 0)
    }

    func testSyncDerivedReconciliationSkipsCleanStoreAndRunsAfterImportedBatch() throws {
        let (store, _) = try makeStore()
        try store.rebuildDerivedState()
        let database = try XCTUnwrap(store.db)
        let setupSQL = """
        INSERT INTO places(place_id, latitude, longitude, radius_meters, first_seen, last_seen)
            VALUES ('sync-rebuild-sentinel', 0, 0, 100, 0, 0);
        CREATE TABLE projection_rebuilds(name TEXT NOT NULL);
        CREATE TRIGGER track_place_rebuild AFTER DELETE ON places
        BEGIN INSERT INTO projection_rebuilds(name) VALUES ('places'); END;
        """
        var sqlError: UnsafeMutablePointer<CChar>?
        let setupStatus = sqlite3_exec(database, setupSQL, nil, nil, &sqlError)
        let setupMessage = sqlError.map { String(cString: $0) } ?? ""
        sqlite3_free(sqlError)
        XCTAssertEqual(setupStatus, SQLITE_OK, setupMessage)

        try store.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(projectionRebuildCount(database), 0)

        let localEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_000),
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(appName: "Safari", bundleID: "com.apple.Safari")
        )
        XCTAssertTrue(store.insertRawEvent(localEvent))
        try store.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(projectionRebuildCount(database), 0,
                       "a local non-location Event is reconciled inline and must not schedule a full place rebuild")

        let phoneID = RiverDeviceID(rawValue: "iphone-derived-reconcile-test")
        let event = RiverEvent(
            originDeviceID: phoneID, originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 2_000), source: "shortcuts", kind: "app.opened",
            payload: try JSONEncoder().encode(RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"))
        )
        let batch = try RiverEventBatch(deviceID: phoneID, events: [event])
        XCTAssertTrue(store.importEventBatch(batch, objectID: batch.id, ciphertextHash: "test-hash"))
        try store.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(projectionRebuildCount(database), 1)

        try store.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(projectionRebuildCount(database), 1)
    }

    func testTwoV2StoresConvergeEventsAndSharedConfirmationThroughEncryptedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-two-v2-nodes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let phoneID = RiverDeviceID(rawValue: "iphone-v2-sync-test")
        let macID = RiverDeviceID(rawValue: "mac-v2-sync-test")
        let phone = V2Store(databaseURL: root.appendingPathComponent("phone.db"), testDeviceID: phoneID)
        let mac = V2Store(databaseURL: root.appendingPathComponent("mac.db"), testDeviceID: macID)
        XCTAssertNotNil(phone.db, phone.lastError ?? "phone V2 database should open")
        XCTAssertNotNil(mac.db, mac.lastError ?? "Mac V2 database should open")
        let registrations = [
            DeviceRegistration(
                id: phoneID, displayName: "QA iPhone", platform: "iOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: phoneID)
            ),
            DeviceRegistration(
                id: macID, displayName: "QA Mac", platform: "macOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: macID)
            )
        ]
        try phone.mergeDeviceRegistrations(registrations)
        try mac.mergeDeviceRegistrations(registrations)

        let phoneEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_000), source: .systemApp, kind: .appForeground,
            payload: RawEventPayload(appName: "Safari", bundleID: "com.apple.Safari")
        )
        let macEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 2_000), source: .systemApp, kind: .appForeground,
            payload: RawEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
        )
        XCTAssertTrue(phone.insertRawEvent(phoneEvent))
        XCTAssertTrue(mac.insertRawEvent(macEvent))
        let confirmation = try XCTUnwrap(RiverSharedStateRecord.timelineClarification(
            candidateID: "v2-sqlite-sync-candidate",
            observation: "14:00–14:30 正在处理 River Diary。",
            opening: "这段活动的主要目标是什么？",
            evidenceRefs: ["raw:\(phoneEvent.id.uuidString.lowercased())"],
            createdAt: Date(timeIntervalSince1970: 2_100)
        ))
        XCTAssertTrue(phone.saveSharedUserRecord(confirmation))

        let directory = ReplicationDirectory(rootURL: root.appendingPathComponent("Replication", isDirectory: true))
        let key = SyncEncryptionKey()
        let phoneSync = try RiverSyncCoordinator(store: phone, directory: directory, key: key)
        let macSync = try RiverSyncCoordinator(store: mac, directory: directory, key: key)
        let phoneBatchBeforeSync = try XCTUnwrap(try phone.localEventBatches().first)
        let macBatchBeforeSync = try XCTUnwrap(try mac.localEventBatches().first)
        var phoneReport = try phoneSync.synchronize()
        var macReport = try macSync.synchronize()
        try assertEventBatch(mac, equals: macBatchBeforeSync)
        phoneReport = try phoneSync.synchronize()
        try assertEventBatch(mac, equals: macBatchBeforeSync)
        macReport = try macSync.synchronize()
        for _ in 0..<6 {
            if phoneReport.isVerified && macReport.isVerified { break }
            phoneReport = try phoneSync.synchronize()
            macReport = try macSync.synchronize()
        }

        XCTAssertTrue(phoneReport.isVerified)
        XCTAssertTrue(macReport.isVerified)
        try assertEventBatch(phone, equals: phoneBatchBeforeSync)
        try assertEventBatch(mac, equals: macBatchBeforeSync)
        XCTAssertEqual(Set(phone.allRawEvents().map(\.id)), Set(mac.allRawEvents().map(\.id)))
        XCTAssertEqual(Set(phone.allRawEvents().map(\.id)), Set([phoneEvent.id, macEvent.id]))
        XCTAssertEqual(Set(phone.allStateOperations().map(\.id)), Set(mac.allStateOperations().map(\.id)))
        XCTAssertEqual(try phone.canonicalStateDigest(), try mac.canonicalStateDigest())
        XCTAssertEqual(phone.sharedUserRecords().first(where: { $0.id == confirmation.id })?.status, "pending")
        XCTAssertEqual(mac.sharedUserRecords().first(where: { $0.id == confirmation.id })?.status, "pending")

        let phoneBatch = try XCTUnwrap(try phone.localEventBatches().first)
        let phoneEnvelope = try XCTUnwrap(try directory.readObject(id: phoneBatch.id, stream: "Events", deviceID: phoneID))
        let secondTransport = ReplicationDirectory(rootURL: root.appendingPathComponent("SecondTransport", isDirectory: true))
        _ = try secondTransport.publish(phoneEnvelope, stream: "Events", deviceID: phoneID)
        let duplicateReport = try RiverSyncCoordinator(store: mac, directory: secondTransport, key: key).synchronize()
        XCTAssertEqual(duplicateReport.importedEventBatches, 0)
        XCTAssertEqual(duplicateReport.duplicateEventBatches, 1)
        XCTAssertEqual(mac.allRawEvents().filter { $0.id == phoneEvent.id }.count, 1)
    }

    func testV2SyncReportsMissingEventSequenceAndCannotVerify() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-missing-sequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let phoneID = RiverDeviceID(rawValue: "iphone-v2-gap-test")
        let macID = RiverDeviceID(rawValue: "mac-v2-gap-test")
        let phone = V2Store(databaseURL: root.appendingPathComponent("phone.db"), testDeviceID: phoneID)
        let mac = V2Store(databaseURL: root.appendingPathComponent("mac.db"), testDeviceID: macID)
        let registrations = [
            DeviceRegistration(
                id: phoneID, displayName: "QA iPhone", platform: "iOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: phoneID)
            ),
            DeviceRegistration(
                id: macID, displayName: "QA Mac", platform: "macOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: macID)
            )
        ]
        try phone.mergeDeviceRegistrations(registrations)
        try mac.mergeDeviceRegistrations(registrations)

        for sequence in [UInt64(1), 2, 4] {
            XCTAssertTrue(phone.insertRawEvent(RawEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(sequence * 1_000)),
                source: .systemApp,
                kind: .appForeground,
                payload: RawEventPayload(appName: "Safari", bundleID: "com.apple.Safari"),
                sourceHash: "event-\(sequence)",
                originDeviceID: phoneID,
                originSequence: sequence
            )))
        }
        let database = try XCTUnwrap(phone.db)
        let frontierKey = "owned.event.sequence.\(phoneID.rawValue)"
        let setFrontierSQL = "INSERT OR REPLACE INTO sync_state(key, value) VALUES ('\(frontierKey)', '4')"
        var sqlError: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, setFrontierSQL, nil, nil, &sqlError)
        let message = sqlError.map { String(cString: $0) } ?? ""
        sqlite3_free(sqlError)
        XCTAssertEqual(status, SQLITE_OK, message)

        let directory = ReplicationDirectory(rootURL: root.appendingPathComponent("Replication", isDirectory: true))
        let key = SyncEncryptionKey()
        _ = try RiverSyncCoordinator(store: phone, directory: directory, key: key).synchronize()
        let report = try RiverSyncCoordinator(store: mac, directory: directory, key: key).synchronize()

        XCTAssertFalse(report.isVerified)
        XCTAssertTrue(report.sequenceGapDevices.contains(phoneID))
        let gap = try XCTUnwrap(report.missingSequenceGaps.first {
            $0.deviceID == phoneID && $0.stream == "Events"
        })
        XCTAssertEqual(gap.first, 3)
        XCTAssertEqual(gap.last, 3)
        XCTAssertEqual(mac.allRawEvents().filter { $0.originDeviceID == phoneID }.count, 3)
    }

    func testV2SyncRejectsCorruptedArtifactWithoutImportOrVerification() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-corrupted-artifact-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let phoneID = RiverDeviceID(rawValue: "iphone-v2-corrupt-test")
        let macID = RiverDeviceID(rawValue: "mac-v2-corrupt-test")
        let phone = V2Store(databaseURL: root.appendingPathComponent("phone.db"), testDeviceID: phoneID)
        let mac = V2Store(databaseURL: root.appendingPathComponent("mac.db"), testDeviceID: macID)
        let registrations = [
            DeviceRegistration(
                id: phoneID, displayName: "QA iPhone", platform: "iOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: phoneID)
            ),
            DeviceRegistration(
                id: macID, displayName: "QA Mac", platform: "macOS", lifecycle: .active,
                clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: macID)
            )
        ]
        try phone.mergeDeviceRegistrations(registrations)
        try mac.mergeDeviceRegistrations(registrations)
        XCTAssertTrue(phone.insertRawEvent(RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_000), source: .systemApp, kind: .appForeground,
            payload: RawEventPayload(appName: "Safari", bundleID: "com.apple.Safari")
        )))
        let content = Data("canonical daily review".utf8)
        let revision = RiverArtifactRevision(
            id: "daily-review-v2-corrupt-test",
            logicalKey: "daily-review:1970-01-01",
            kind: .dailyReview,
            revisionNumber: 1,
            originDeviceID: phoneID,
            clock: HybridLogicalClock(physicalMilliseconds: 5_000, deviceID: phoneID),
            inputFrontier: try InputFrontier(sequences: [phoneID.rawValue: 1]),
            inputSnapshotHash: "snapshot",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "test-model",
            content: content,
            contentHash: SHA256Hex.hash(content)
        )
        XCTAssertTrue(phone.insertArtifactRevision(revision))

        let directoryURL = root.appendingPathComponent("Replication", isDirectory: true)
        let directory = ReplicationDirectory(rootURL: directoryURL)
        let key = SyncEncryptionKey()
        _ = try RiverSyncCoordinator(store: phone, directory: directory, key: key).synchronize()
        let encrypted = try XCTUnwrap(try directory.readObject(
            id: revision.id, stream: "Artifacts", deviceID: phoneID
        ))
        let corrupted = EncryptedReplicationObject(
            id: encrypted.id,
            kind: encrypted.kind,
            protocolVersion: encrypted.protocolVersion,
            ciphertext: encrypted.ciphertext + Data([0]),
            ciphertextSHA256: encrypted.ciphertextSHA256
        )
        let artifactURL = directoryURL.appendingPathComponent("Devices", isDirectory: true)
            .appendingPathComponent(phoneID.rawValue, isDirectory: true)
            .appendingPathComponent("Artifacts", isDirectory: true)
            .appendingPathComponent("\(revision.id).rdo")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(corrupted).write(to: artifactURL, options: .atomic)

        let report = try RiverSyncCoordinator(store: mac, directory: directory, key: key).synchronize()
        XCTAssertFalse(report.integrityFailures.isEmpty)
        XCTAssertTrue(report.integrityFailures.contains { $0.contains(revision.id) })
        XCTAssertEqual(report.importedArtifactRevisions, 0)
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(mac.countRows(in: .artifacts), 0)
    }

    private func projectionRebuildCount(_ database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM projection_rebuilds", -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func assertEventBatch(
        _ store: V2Store,
        equals expected: RiverEventBatch,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try XCTUnwrap(store.localEventBatches().first, file: file, line: line)
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.deviceID, expected.deviceID, file: file, line: line)
        XCTAssertEqual(actual.events.count, expected.events.count, file: file, line: line)
        let actualEvent = try XCTUnwrap(actual.events.first, file: file, line: line)
        let expectedEvent = try XCTUnwrap(expected.events.first, file: file, line: line)
        XCTAssertEqual(actualEvent.id, expectedEvent.id, file: file, line: line)
        XCTAssertEqual(actualEvent.originSequence, expectedEvent.originSequence, file: file, line: line)
        XCTAssertEqual(actualEvent.observedAt.timeIntervalSince1970.bitPattern,
                       expectedEvent.observedAt.timeIntervalSince1970.bitPattern, file: file, line: line)
        XCTAssertEqual(actualEvent.recordedAt.timeIntervalSince1970.bitPattern,
                       expectedEvent.recordedAt.timeIntervalSince1970.bitPattern, file: file, line: line)
        XCTAssertEqual(actualEvent.observedTimeZoneIdentifier, expectedEvent.observedTimeZoneIdentifier, file: file, line: line)
        XCTAssertEqual(actualEvent.source, expectedEvent.source, file: file, line: line)
        XCTAssertEqual(actualEvent.kind, expectedEvent.kind, file: file, line: line)
        XCTAssertEqual(actualEvent.sourceHash, expectedEvent.sourceHash, file: file, line: line)
        XCTAssertEqual(
            actualEvent.payload, expectedEvent.payload,
            "actual=\(String(decoding: actualEvent.payload, as: UTF8.self)) expected=\(String(decoding: expectedEvent.payload, as: UTF8.self))",
            file: file, line: line
        )
    }

    func testDeveloperDiagnosticsCountsSharedPendingTimelineConfirmations() throws {
        let (store, databaseURL) = try makeStore()
        let suiteName = "river-diagnostics-confirmations-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sync = SyncSettingsStore(database: store, preferences: defaults)
        let activity = ActivityStore(
            activityDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("Activity"),
            userDefaults: defaults,
            v2Store: store
        )
        let confirmation = try XCTUnwrap(RiverSharedStateRecord.timelineClarification(
            candidateID: "diagnostics-candidate",
            observation: "观察到一段编辑器活动。",
            opening: "当时在处理什么？",
            evidenceRefs: ["raw:diagnostics-event"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        XCTAssertTrue(store.saveSharedUserRecord(confirmation))

        let reportData = try XCTUnwrap(sync.makeDiagnosticsReport(activity: activity))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: reportData) as? [String: Any])
        let pendingStatus = try XCTUnwrap(report["pendingConfirmationStatus"] as? String)
        XCTAssertTrue(pendingStatus.contains("时间线 1 条"))
        XCTAssertFalse(pendingStatus.contains("尚未接入"))
    }

    func testLostSyncFolderBookmarkKeepsLocalNodeUsableAndRequestsReconnection() throws {
        let (store, _) = try makeStore()
        let suiteName = "river-sync-bookmark-loss-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("unresolvable-bookmark".utf8), forKey: "river.sync.directory.bookmark.v1")

        let sync = SyncSettingsStore(database: store, preferences: defaults)
        sync.synchronize()

        XCTAssertEqual(sync.status, "需要重新连接 iCloud Drive 文件夹")
        XCTAssertTrue(sync.lastError?.contains("重新选择 iCloud Drive") == true)
        XCTAssertFalse(sync.isVerified, "授权失效时不能继续显示旧的 Verified 状态")

        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            source: .manual,
            kind: .quickCapture,
            payload: RawEventPayload(text: "local capture remains available")
        )
        XCTAssertTrue(store.insertRawEvent(event), "同步目录失效不应阻断本机 Event 写入")
        XCTAssertEqual(store.rawEvents(ids: [event.id]).count, 1)
    }

    func testRawEventRoundTripAndEmptyState() throws {
        let (store, _) = try makeStore()
        XCTAssertEqual(store.countRows(in: .rawEvents), 0)

        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 5_000),
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(appName: "Xcode", windowTitle: "River.swift"),
            sourceHash: "hash-1"
        )
        XCTAssertTrue(store.insertRawEvent(event))

        let range = store.rawEvents(between: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10_000))
        XCTAssertEqual(range.count, 1)
        XCTAssertEqual(range[0].id, event.id)
        XCTAssertEqual(range[0].timestamp, event.timestamp)
        XCTAssertEqual(range[0].payload.appName, "Xcode")
        XCTAssertEqual(range[0].originDeviceID, try XCTUnwrap(store.localDeviceIdentifier()))
        XCTAssertEqual(range[0].originSequence, 1)

        let fetched = store.rawEvents(ids: [event.id])
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, event.id)
    }

    func testAnalysisJobsPersistTheirFrontierAndStateTransitions() throws {
        let (store, databaseURL) = try makeStore()
        let device = RiverDeviceID(rawValue: "mac-analysis-jobs")
        let frontier = try InputFrontier(sequences: [device.rawValue: 12], operationSequences: [device.rawValue: 3])
        let requestSnapshot = Data("private exact user prompt input".utf8)
        let queued = RiverAnalysisJob(
            id: UUID(), logicalKey: "daily-review:2026-09-28", artifactType: .dailyReview,
            inputFrontier: frontier, priority: 100, originDeviceID: device,
            pipelineVersion: "1.0", promptVersion: "1", requestSnapshot: requestSnapshot,
            requestFingerprint: SHA256Hex.hash(requestSnapshot)
        )

        XCTAssertTrue(store.saveAnalysisJob(queued))
        XCTAssertEqual(store.latestAnalysisJob(), queued)

        let running = queued.transitioning(to: .running)
        XCTAssertTrue(store.saveAnalysisJob(running))
        XCTAssertEqual(store.latestAnalysisJob()?.status, .running)
        XCTAssertEqual(store.latestAnalysisJob()?.attempt, 1)
        XCTAssertEqual(store.latestAnalysisJob()?.requestSnapshot, requestSnapshot)
        XCTAssertEqual(store.latestAnalysisJob()?.requestFingerprint, SHA256Hex.hash(requestSnapshot))
        XCTAssertEqual(store.countRows(in: .analysisJobs), 1)
        XCTAssertNil(try Data(contentsOf: databaseURL).range(of: requestSnapshot))
    }

    func testMacQuickCaptureEntersEventStreamAndDeletionReplicatesAsTombstone() throws {
        let (store, databaseURL) = try makeStore()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "river-quick-capture-\(UUID().uuidString)"))
        let activity = ActivityStore(
            activityDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("Activity"),
            userDefaults: defaults,
            v2Store: store
        )
        let capture = QuickCapture(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000789")!,
            text: "今天完成了 River Diary 同步",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertTrue(activity.replicateQuickCapture(capture))
        XCTAssertTrue(activity.replicateQuickCapture(capture), "retry must reuse the same Event ID")
        let stored = try XCTUnwrap(store.rawEvents(ids: [capture.id]).first)
        XCTAssertEqual(stored.payload.text, capture.text)
        XCTAssertEqual(stored.timestamp, capture.createdAt)

        XCTAssertTrue(activity.tombstoneQuickCapture(capture))
        XCTAssertTrue(activity.tombstoneQuickCapture(capture), "tombstone retry must be idempotent")
        XCTAssertFalse(store.effectiveRawEvents().contains { $0.id == capture.id })
        XCTAssertEqual(store.allStateOperations().filter {
            $0.operationType == "object.tombstone" && $0.targetID == "event:\(capture.id.uuidString)"
        }.count, 1)
    }

    func testHabitReviewRecordsAreReplicatedAsOperationsAndRebuiltOnImport() throws {
        let (store, _) = try makeStore()
        let record = RiverSharedStateRecord(
            id: UUID(), kind: .habitCard, status: "shown", logicalKey: "pattern:com.example.app",
            payloadJSON: "{\"question\":\"是否算作工作？\"}",
            createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20)
        )
        let payload = try JSONEncoder().encode(record)
        XCTAssertNotNil(store.appendStateOperation(
            targetID: record.targetID, fieldKey: "record", operationType: "shared.record.upsert", payload: payload
        ))

        try store.rebuildDerivedState()

        let restored = try XCTUnwrap(store.habitCardRows().first)
        XCTAssertEqual(restored.id, record.id)
        XCTAssertEqual(restored.status, "shown")
        XCTAssertEqual(restored.dedupKey, record.logicalKey)
        XCTAssertEqual(restored.payloadJSON, record.payloadJSON)
        XCTAssertEqual(store.allStateOperations().filter { $0.operationType == "shared.record.upsert" }.count, 1)
    }

    func testLegacyHabitAndMemoryRowsMigrateDuringSyncRebuildAndRemainIdempotentAfterRestart() throws {
        let (store, databaseURL) = try makeStore()
        let ruleID = "00000000-0000-0000-0000-000000000101"
        let cardID = "00000000-0000-0000-0000-000000000102"
        let batchID = "00000000-0000-0000-0000-000000000103"
        let memoryID = "00000000-0000-0000-0000-000000000104"
        let database = try XCTUnwrap(store.db)
        let legacyRows = """
        INSERT INTO habit_rules(id, status, payload_json, updated_at)
        VALUES ('\(ruleID)', 'active', '{"title":"旧规则"}', 100);
        INSERT INTO habit_cards(id, batch_id, dedup_key, status, payload_json, updated_at)
        VALUES ('\(cardID)', '\(batchID)', 'legacy:card', 'answered', '{"answer":"yes"}', 110);
        INSERT INTO habit_batches(id, period_key, payload_json, created_at, shown_at)
        VALUES ('\(batchID)', '2026-09', '{"period":"2026-09"}', 90, 120);
        INSERT INTO memories(id, title, body, kind, confidence, source_episode_ids, created_at, last_confirmed_at, is_user_confirmed)
        VALUES ('\(memoryID)', '旧记忆', '保留的正文', 'other', 80, '[]', 80, 130, 1);
        INSERT INTO memory_confirmations(memory_id, confirmed_at, is_confirmed, note)
        VALUES ('\(memoryID)', 130, 1, '旧确认');
        """
        var sqlError: UnsafeMutablePointer<CChar>?
        let seedStatus = sqlite3_exec(database, legacyRows, nil, nil, &sqlError)
        let seedMessage = sqlError.map { String(cString: $0) } ?? ""
        sqlite3_free(sqlError)
        XCTAssertEqual(seedStatus, SQLITE_OK, seedMessage)
        XCTAssertTrue(store.allStateOperations().isEmpty)

        // RiverSyncCoordinator calls rebuildDerivedState before exporting local batches.
        try store.rebuildDerivedState()

        let migrated = store.sharedUserRecords()
        XCTAssertTrue(migrated.contains { $0.kind == .habitRule && $0.id.uuidString.lowercased() == ruleID })
        XCTAssertTrue(migrated.contains { $0.kind == .habitCard && $0.id.uuidString.lowercased() == cardID && $0.status == "answered" })
        XCTAssertTrue(migrated.contains { $0.kind == .habitBatch && $0.id.uuidString.lowercased() == batchID })
        let memory = try XCTUnwrap(migrated.first { $0.kind == .memory && $0.id.uuidString.lowercased() == memoryID })
        XCTAssertTrue(memory.payloadJSON.contains("保留的正文"))
        let confirmation = try XCTUnwrap(store.allStateOperations().first {
            $0.operationType == "memory.confirmation.set" && $0.targetID == "memory:\(memoryID)"
        })
        let decision = try JSONDecoder().decode(RiverMemoryConfirmation.self, from: confirmation.payload)
        XCTAssertTrue(decision.confirmed)
        XCTAssertEqual(decision.note, "旧确认")
        XCTAssertEqual(store.allStateOperations().count, 5)

        try store.rebuildDerivedState()
        XCTAssertEqual(store.allStateOperations().count, 5, "repeated migration must not append duplicate operations")

        store.close()
        let relaunched = V2Store(databaseURL: databaseURL)
        try relaunched.rebuildDerivedState()
        XCTAssertEqual(relaunched.allStateOperations().count, 5, "migration remains idempotent after reopening the database")
    }

    func testPendingConfirmationResolutionReplicatesUserCorrectionAndPlaceIdentity() throws {
        let (store, _) = try makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let content = RiverPendingConfirmationContent(
            title: "地点候选", question: "这里是「学校」吗？", candidate: "学校",
            targetType: "place", targetID: "place:example"
        )
        let payload = try JSONEncoder().encode(content)
        let record = RiverSharedStateRecord(
            id: RiverStableIdentifier.uuid(namespace: "test", key: "place:example"),
            kind: .pendingConfirmation, status: "pending", logicalKey: "place-confirmation:place:example",
            payloadJSON: String(decoding: payload, as: UTF8.self), createdAt: createdAt, updatedAt: createdAt
        )
        XCTAssertTrue(store.saveSharedUserRecord(record))
        XCTAssertTrue(store.resolvePendingConfirmation(record, as: .corrected, correction: "宿舍"))

        let resolved = try XCTUnwrap(store.sharedUserRecords().first { $0.id == record.id })
        XCTAssertEqual(resolved.status, "corrected")
        XCTAssertEqual(resolved.pendingConfirmationContent?.correction, "宿舍")
        let identity = try XCTUnwrap(store.allStateOperations().first { $0.operationType == "place.identity.set" })
        let decision = try JSONDecoder().decode(RiverPlaceUserDecision.self, from: identity.payload)
        XCTAssertEqual(decision.name, "宿舍")
        XCTAssertEqual(decision.semanticType, "userDefined")
        let operations = store.allStateOperations().sorted { $0.originSequence < $1.originSequence }
        XCTAssertEqual(operations.count, 3)
        XCTAssertEqual(operations[1].originSequence + 1, operations[2].originSequence)
        XCTAssertEqual(operations[2].causalFrontier.operationSequences[operations[2].actorDeviceID.rawValue], operations[1].originSequence)
    }

    func testReopenedPlaceQuestionCanRejectAndClearItsEarlierUserIdentity() throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let content = RiverPendingConfirmationContent(
            title: "地点候选", question: "这里是「学校」吗？", candidate: "学校",
            targetType: "place", targetID: "place:reopened-question"
        )
        let payload = String(decoding: try JSONEncoder().encode(content), as: UTF8.self)
        let pending = RiverSharedStateRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000779")!,
            kind: .pendingConfirmation, status: "pending", logicalKey: "place-confirmation:reopen",
            payloadJSON: payload, createdAt: now, updatedAt: now
        )
        XCTAssertTrue(store.saveSharedUserRecord(pending))
        XCTAssertTrue(store.resolvePendingConfirmation(pending, as: .confirmed))

        let resolved = try XCTUnwrap(store.sharedUserRecords().first { $0.id == pending.id })
        let reopened = try XCTUnwrap(resolved.reopened(at: now.addingTimeInterval(30)))
        XCTAssertTrue(store.saveSharedUserRecord(reopened))
        XCTAssertEqual(store.sharedUserRecords().first { $0.id == pending.id }?.status, "pending")
        XCTAssertTrue(store.resolvePendingConfirmation(reopened, as: .rejected))

        let finalIdentityOperation = try XCTUnwrap(store.allStateOperations().last {
            $0.operationType == "place.identity.set" && $0.targetID == "place:reopened-question"
        })
        let decision = try JSONDecoder().decode(RiverPlaceUserDecision.self, from: finalIdentityOperation.payload)
        XCTAssertFalse(decision.isConfirmed)
        XCTAssertEqual(decision.name, "")
        XCTAssertEqual(store.sharedUserRecords().first { $0.id == pending.id }?.status, "rejected")
    }

    func testTimelineClarificationConfirmationSharesReviewedAnnotationAndClosesQuestion() throws {
        let (store, _) = try makeStore()
        let annotationKey = "1700000000|com.example.editor|Editor"
        let record = try XCTUnwrap(RiverSharedStateRecord.timelineClarification(
            candidateID: "activity-candidate", annotationKey: annotationKey,
            observation: "这段时间主要使用了编辑器。", opening: "当时在编辑什么？",
            evidenceRefs: ["raw:source-1"], createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        XCTAssertTrue(store.saveSharedUserRecord(record))
        let reviewedAt = Date(timeIntervalSince1970: 1_700_000_010)
        let portableAnnotation = RiverTimelineAnnotation(
            title: "修改 River Diary", note: "确认是项目开发", isReviewed: true,
            reviewedAt: reviewedAt, updatedAt: reviewedAt
        )
        XCTAssertNotNil(store.appendStateOperation(
            targetID: annotationKey, fieldKey: "annotation",
            operationType: "timeline.annotation.set", payload: try JSONEncoder().encode(portableAnnotation)
        ))
        let localAnnotation = TimelineAnnotation(
            title: portableAnnotation.title, note: portableAnnotation.note,
            isReviewed: true, reviewedAt: reviewedAt, updatedAt: reviewedAt
        )
        XCTAssertTrue(store.resolvePendingTimelineConfirmation(annotationKey: annotationKey, annotation: localAnnotation))

        let resolved = try XCTUnwrap(store.sharedUserRecords().first { $0.id == record.id })
        XCTAssertEqual(resolved.status, "corrected")
        let annotationOperation = try XCTUnwrap(store.allStateOperations().first {
            $0.operationType == "shared.record.upsert" && $0.targetID == resolved.targetID
                && (try? JSONDecoder().decode(RiverSharedStateRecord.self, from: $0.payload))?.status == "corrected"
        })
        XCTAssertEqual(try JSONDecoder().decode(RiverSharedStateRecord.self, from: annotationOperation.payload), resolved)

        let timelineOperation = try XCTUnwrap(store.allStateOperations().first {
            $0.operationType == "timeline.annotation.set" && $0.targetID == annotationKey
        })
        let restoredPortable = try JSONDecoder().decode(RiverTimelineAnnotation.self, from: timelineOperation.payload)
        let restoredLocal = try JSONDecoder().decode(TimelineAnnotation.self, from: timelineOperation.payload)
        XCTAssertTrue(restoredPortable.isReviewed)
        XCTAssertEqual(restoredLocal.title, "修改 River Diary")
        XCTAssertEqual(restoredLocal.note, "确认是项目开发")
    }

    func testHandwrittenJournalAndMonthlyLetterUseSharedOperationRecords() throws {
        let (store, _) = try makeStore()
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = RiverJournalEntryContent(
            dayKey: "2026-09-28", body: "终于把日记写入共享状态", moodScore: 78,
            energyScore: 70, category: "记录", tags: ["工作"], updatedAt: updatedAt
        )
        let record = try XCTUnwrap(RiverSharedStateRecord.journalEntry(entry))
        XCTAssertTrue(store.saveSharedUserRecord(record))
        XCTAssertEqual(store.sharedUserRecords().first { $0.kind == .journalEntry }?.journalEntryContent, entry)

        let deleted = try XCTUnwrap(RiverSharedStateRecord.journalEntry(entry, status: "deleted"))
        XCTAssertTrue(store.saveSharedUserRecord(deleted))
        let deletionOperation = try XCTUnwrap(store.allStateOperations().first {
            guard $0.operationType == "shared.record.upsert",
                  let saved = try? JSONDecoder().decode(RiverSharedStateRecord.self, from: $0.payload) else { return false }
            return saved.id == deleted.id && saved.status == "deleted"
        })
        XCTAssertTrue(RiverStateOperationFreshness.changesAnalyticalState(deletionOperation))

        let letter = RiverMonthlyLetterContent(
            monthKey: "2026-09", title: "九月的河流信", body: "留住这一段。", evidence: "2 天记录",
            createdAt: updatedAt, updatedAt: updatedAt
        )
        let letterRecord = try XCTUnwrap(RiverSharedStateRecord.monthlyLetter(letter))
        XCTAssertTrue(store.saveSharedUserRecord(letterRecord))
        XCTAssertEqual(store.sharedUserRecords().first { $0.kind == .monthlyLetter }?.monthlyLetterContent, letter)

        XCTAssertTrue(store.setMoodScore(dayKey: "2026-09-28", score: 78, updatedAt: updatedAt))
        let moodOperation = try XCTUnwrap(store.allStateOperations().first { $0.operationType == "mood.score.set" })
        XCTAssertEqual(try JSONDecoder().decode(RiverMoodScoreDecision.self, from: moodOperation.payload).score, 78)
    }

    func testDiaryStoreWritesJournalLetterAndMoodToTheReplicationOutbox() throws {
        let (replicationStore, databaseURL) = try makeStore()
        let stateDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("journal-state", isDirectory: true)
        let diary = DiaryStore(supportDirectory: stateDirectory)
        diary.onSharedJournalEntryChanged = { replicationStore.saveSharedUserRecord($0) }
        diary.onSharedMonthlyLetterChanged = { replicationStore.saveSharedUserRecord($0) }
        diary.onQuickCaptureMetadataChanged = { replicationStore.saveSharedUserRecord($0) }
        diary.onMoodScoreChanged = { day, score, updatedAt in
            replicationStore.setMoodScore(dayKey: day, score: score, updatedAt: updatedAt)
        }
        diary.onMoodScoreReset = { day, updatedAt in
            replicationStore.resetMoodScore(dayKey: day, updatedAt: updatedAt)
        }

        let day = "2026-09-28"
        let entry = DiaryEntry(pageID: "local-\(day)", date: day)
        try diary.saveWriting(entry: entry, text: "写入共享日记", mood: 73)
        if case .saved(_) = diary.saveState {} else { XCTFail("日记保存和复制操作应成功") }
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.kind == .journalEntry }?.journalEntryContent?.body, "写入共享日记")
        XCTAssertEqual(try JSONDecoder().decode(
            RiverMoodScoreDecision.self,
            from: XCTUnwrap(replicationStore.allStateOperations().first { $0.operationType == "mood.score.set" }).payload
        ).score, 73)

        diary.clearOverride(for: entry)
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.kind == .journalEntry }?.status, "deleted")
        XCTAssertTrue(replicationStore.allStateOperations().contains { $0.operationType == "mood.score.reset" })

        let letter = MonthlyLetter(
            month: "2026-09", title: "九月", body: "共享的信件正文", evidence: "日记记录",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try diary.saveMonthlyLetter(letter)
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.kind == .monthlyLetter }?.monthlyLetterContent?.body, "共享的信件正文")

        let quickCaptureDay = DiaryEntry.dateFormatter.date(from: day)!
        XCTAssertTrue(diary.addQuickCapture("跨设备快记", tag: "记录", for: quickCaptureDay))
        let quickCapture = try XCTUnwrap(diary.captures(for: entry).first { $0.text == "跨设备快记" })
        let initialMetadata = try XCTUnwrap(replicationStore.sharedUserRecords().first { $0.kind == .quickCaptureMetadata })
        XCTAssertEqual(initialMetadata.quickCaptureMetadata?.tag, "记录")
        diary.setQuickCapturePinned(quickCapture, entry: entry, pinned: true)
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.id == initialMetadata.id }?.quickCaptureMetadata?.isPinned, true)
    }

    func testMonthlyLetterDraftIsSharedAndRemovedWhenSaved() throws {
        let (replicationStore, databaseURL) = try makeStore()
        let source = DiaryStore(supportDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("letter-draft-source"))
        source.saveLetterDraft("还没有决定是否保存的正文。", for: "2026-09")
        source.onSharedMonthlyLetterChanged = { replicationStore.saveSharedUserRecord($0) }
        source.onSharedMonthlyLetterDraftChanged = { replicationStore.saveSharedUserRecord($0) }
        source.loadSharedMonthlyLetterDrafts = {
            Dictionary(uniqueKeysWithValues: replicationStore.sharedUserRecords().compactMap { record in
                guard record.kind == .monthlyLetterDraft, record.status == "current",
                      let draft = record.monthlyLetterDraftContent else { return nil }
                return (draft.monthKey, draft)
            })
        }
        XCTAssertEqual(source.migrateLocalJournalStateToSharedOperations(), 1)
        XCTAssertEqual(source.migrateLocalJournalStateToSharedOperations(), 0, "local draft migration is idempotent")
        let sharedDraft = try XCTUnwrap(replicationStore.sharedUserRecords().first {
            $0.kind == .monthlyLetterDraft && $0.status == "current"
        })
        XCTAssertEqual(sharedDraft.monthlyLetterDraftContent?.body, "还没有决定是否保存的正文。")

        let target = DiaryStore(supportDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("letter-draft-target"))
        target.applySharedDiaryRecords(replicationStore.sharedUserRecords())
        XCTAssertEqual(target.letterDraft(for: "2026-09"), "还没有决定是否保存的正文。")

        try source.saveMonthlyLetter(MonthlyLetter(
            month: "2026-09", title: "九月河流信", body: "正式保存的正文。", evidence: "日记记录",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.id == sharedDraft.id }?.status, "deleted")
        target.applySharedDiaryRecords(replicationStore.sharedUserRecords())
        XCTAssertNil(target.letterDraft(for: "2026-09"))
        XCTAssertEqual(target.monthlyLetters["2026-09"]?.body, "正式保存的正文。")
    }

    func testFailedMonthlyLetterDraftTombstoneResumesAfterStoreReload() throws {
        let (replicationStore, databaseURL) = try makeStore()
        let stateDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("letter-draft-retry")
        let source = DiaryStore(supportDirectory: stateDirectory)
        source.onSharedMonthlyLetterDraftChanged = { _ in false }
        source.saveLetterDraft("稍后会删除的草稿。", for: "2026-09")
        source.discardLetterDraft(for: "2026-09")
        XCTAssertTrue(replicationStore.sharedUserRecords().filter { $0.kind == .monthlyLetterDraft }.isEmpty)

        let relaunched = DiaryStore(supportDirectory: stateDirectory)
        relaunched.onSharedMonthlyLetterDraftChanged = { replicationStore.saveSharedUserRecord($0) }
        relaunched.loadSharedMonthlyLetterDrafts = {
            Dictionary(uniqueKeysWithValues: replicationStore.sharedUserRecords().compactMap { record in
                guard record.kind == .monthlyLetterDraft,
                      let draft = record.monthlyLetterDraftContent else { return nil }
                return (draft.monthKey, draft)
            })
        }
        XCTAssertNil(relaunched.letterDraft(for: "2026-09"))
        XCTAssertEqual(relaunched.migrateLocalJournalStateToSharedOperations(), 1)
        XCTAssertEqual(replicationStore.sharedUserRecords().first { $0.kind == .monthlyLetterDraft }?.status, "deleted")
        XCTAssertEqual(relaunched.migrateLocalJournalStateToSharedOperations(), 0, "pending deletion retry is idempotent")
    }

    func testDiaryStoreProjectsImportedJournalLetterAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-shared-journal-projection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diary = DiaryStore(supportDirectory: directory)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let content = RiverJournalEntryContent(
            dayKey: "2098-01-02", body: "从另一台设备收到的日记", moodScore: 66,
            tags: ["旅行"], updatedAt: updatedAt
        )
        let entry = try XCTUnwrap(RiverSharedStateRecord.journalEntry(content))
        let letterContent = RiverMonthlyLetterContent(
            monthKey: "2026-01", title: "一月河流信", body: "跨设备显示。", evidence: "手写日记",
            createdAt: updatedAt, updatedAt: updatedAt
        )
        let letter = try XCTUnwrap(RiverSharedStateRecord.monthlyLetter(letterContent))

        diary.applySharedDiaryRecords([entry, letter])
        let localEntry = DiaryEntry(pageID: "ingested-2098-01-02", date: "2098-01-02")
        XCTAssertEqual(diary.overview(for: localEntry), "从另一台设备收到的日记")
        XCTAssertEqual(diary.tags(for: localEntry), ["旅行"])
        XCTAssertEqual(diary.monthlyLetters["2026-01"]?.body, "跨设备显示。")

        let deleted = try XCTUnwrap(RiverSharedStateRecord.journalEntry(content, status: "deleted"))
        diary.applySharedDiaryRecords([deleted])
        XCTAssertEqual(diary.overview(for: localEntry), "")
    }

    func testMemoryConfirmationIsReplicatedAndRebuildsBothStorageLayers() throws {
        let (store, _) = try makeStore()
        let memory = Memory(title: "早晨先写作")
        XCTAssertTrue(store.insertMemory(memory))
        XCTAssertTrue(store.setMemoryConfirmation(memory.id, confirmed: true, note: "这是我的习惯"))

        let decisionOperation = try XCTUnwrap(store.allStateOperations().first {
            $0.operationType == "memory.confirmation.set" && $0.targetID == "memory:\(memory.id.uuidString.lowercased())"
        })
        let decision = try JSONDecoder().decode(RiverMemoryConfirmation.self, from: decisionOperation.payload)
        XCTAssertTrue(decision.confirmed)
        XCTAssertEqual(decision.note, "这是我的习惯")

        try store.rebuildDerivedState()
        XCTAssertEqual(store.memoryConfirmation(for: memory.id)?.confirmed, true)
        XCTAssertEqual(store.memories().first(where: { $0.id == memory.id })?.isUserConfirmed, true)
    }

    func testMemoryEvidenceReferencesSurviveStorageAndSharedProjection() throws {
        let (store, _) = try makeStore()
        let refs = [
            "raw:00000000-0000-0000-0000-000000000901",
            "capture:00000000-0000-0000-0000-000000000902",
            "diary:2026-09-30"
        ]
        let memory = Memory(
            title: "持续推进的项目",
            kind: .projectTrajectory,
            sourceEpisodeIDs: [UUID(uuidString: "00000000-0000-0000-0000-000000000903")!],
            evidenceRefs: refs
        )

        XCTAssertTrue(store.insertMemory(memory))
        XCTAssertEqual(store.memories().first(where: { $0.id == memory.id })?.evidenceRefs, refs)

        let sharedRecord = try XCTUnwrap(store.sharedUserRecords().first { $0.id == memory.id })
        let sharedMemory = try JSONDecoder().decode(Memory.self, from: Data(sharedRecord.payloadJSON.utf8))
        XCTAssertEqual(sharedMemory.evidenceRefs, refs)

        try store.rebuildDerivedState()
        XCTAssertEqual(store.memories().first(where: { $0.id == memory.id })?.evidenceRefs, refs)
    }

    func testSharedMemoryDeletionRemovesMacProjectionAndSurvivesRebuild() throws {
        let (store, _) = try makeStore()
        let memory = Memory(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000778")!,
            title: "River 暂定记忆", body: "这条记录由用户更正后删除。", confidence: 62
        )
        let payload = String(decoding: try JSONEncoder().encode(memory), as: UTF8.self)
        let candidate = RiverSharedStateRecord(
            id: memory.id, kind: .memory, status: "candidate", logicalKey: memory.id.uuidString.lowercased(),
            payloadJSON: payload, createdAt: memory.createdAt, updatedAt: memory.createdAt
        )
        XCTAssertTrue(store.saveSharedUserRecord(candidate))
        try store.rebuildDerivedState()
        XCTAssertEqual(store.memories().first(where: { $0.id == memory.id })?.title, "River 暂定记忆")

        let deletion = RiverSharedStateRecord(
            id: memory.id, kind: .memory, status: "deleted", logicalKey: candidate.logicalKey,
            payloadJSON: payload, createdAt: memory.createdAt, updatedAt: Date()
        )
        XCTAssertTrue(store.saveSharedUserRecord(deletion))
        try store.rebuildDerivedState()

        XCTAssertNil(store.memories().first(where: { $0.id == memory.id }))
        XCTAssertEqual(store.sharedUserRecords().first(where: { $0.id == memory.id })?.status, "deleted")
        try store.rebuildDerivedState()
        XCTAssertNil(store.memories().first(where: { $0.id == memory.id }), "A deleted memory must not return through legacy row migration.")
    }

    func testPhoneNaturalLanguageHabitRuleDecodesIntoTheSharedMacHabitModel() throws {
        let (store, _) = try makeStore()
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-000000000884")!
        let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000885")!
        let now = ISO8601DateFormatter().string(from: Date())
        let payloadObject: [String: Any] = [
            "id": ruleID.uuidString,
            "dedupKey": "pattern:com.example.safari",
            "conditionBundleID": "com.apple.mobilesafari",
            "conditionAppName": "Safari",
            "naturalLanguageRule": "我用 Safari 查阅旅行资料。",
            "supportingEvidenceRefs": [],
            "conclusionCategory": "个人习惯",
            "scopeText": "我用 Safari 查阅旅行资料。",
            "status": "active",
            "origin": "userConfirmed",
            "recordedAt": now,
            "validFrom": now,
            "supportingExampleKeys": [],
            "createdFromCardID": cardID.uuidString
        ]
        let bytes = try JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
        let record = RiverSharedStateRecord(
            id: ruleID, kind: .habitRule, status: "active", logicalKey: "pattern:com.example.safari",
            payloadJSON: String(decoding: bytes, as: UTF8.self), createdAt: Date(), updatedAt: Date()
        )
        XCTAssertTrue(store.saveSharedUserRecord(record))
        try store.rebuildDerivedState()

        let review = HabitReviewStore(v2Store: store, calendar: Calendar(identifier: .gregorian))
        let decoded = try XCTUnwrap(review.rules.first { $0.id == ruleID })
        XCTAssertEqual(decoded.naturalLanguageRule, "我用 Safari 查阅旅行资料。")
        XCTAssertEqual(decoded.origin, .userConfirmed)
        XCTAssertEqual(decoded.status, .active)
    }

    func testAnalyticalUserOperationInvalidatesArtifactsBehindItsFrontier() throws {
        let (store, _) = try makeStore()
        let device = try XCTUnwrap(store.localDeviceIdentifier())
        let frontier = try store.currentInputFrontier()
        let content = Data("旧日报".utf8)
        let artifact = RiverArtifactRevision(
            id: "daily-review-before-mood-change",
            logicalKey: "daily-review:2026-09-28",
            kind: .dailyReview,
            revisionNumber: 1,
            originDeviceID: device,
            clock: HybridLogicalClock(physicalMilliseconds: 10, deviceID: device),
            inputFrontier: frontier,
            inputSnapshotHash: "snapshot",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "test-model",
            content: content,
            contentHash: SHA256Hex.hash(content)
        )
        XCTAssertTrue(store.insertArtifactRevision(artifact))

        XCTAssertNotNil(store.appendStateOperation(
            targetID: "mood:2026-09-28", fieldKey: "score", operationType: "mood.score.set",
            payload: Data("changed".utf8)
        ))

        XCTAssertEqual(store.canonicalArtifactRevision(logicalKey: artifact.logicalKey, kind: .dailyReview)?.status, .stale)
        XCTAssertEqual(store.allStateOperations().filter { $0.operationType == "artifact.stale" }.count, 1)
    }

    func testImportedEventBatchIsIdempotentAndAdvancesOnlyContiguousFrontier() throws {
        let (store, _) = try makeStore()
        let phone = RiverDeviceID(rawValue: "iphone_test")
        func event(_ sequence: UInt64) -> RiverEvent {
            RiverEvent(
                originDeviceID: phone,
                originSequence: sequence,
                observedAt: Date(timeIntervalSince1970: Double(sequence)),
                source: "shortcuts",
                kind: "app.open",
                payload: try! JSONEncoder().encode(RiverEventPayload(appName: "微信", bundleID: "com.tencent.xin"))
            )
        }

        let second = try RiverEventBatch(deviceID: phone, events: [event(2)])
        XCTAssertTrue(store.importEventBatch(second, objectID: second.id, ciphertextHash: "hash-2"))
        XCTAssertEqual(store.importedEventFrontier(for: phone), 0)

        let first = try RiverEventBatch(deviceID: phone, events: [event(1)])
        XCTAssertTrue(store.importEventBatch(first, objectID: first.id, ciphertextHash: "hash-1"))
        XCTAssertEqual(store.importedEventFrontier(for: phone), 2)
        XCTAssertTrue(store.importEventBatch(first, objectID: first.id, ciphertextHash: "hash-1"))
        XCTAssertEqual(store.rawEvents(between: .distantPast, end: .distantFuture).filter { $0.originDeviceID == phone }.count, 2)
    }

    func testLocalEventBatchesHaveStableSequencesAndIDs() throws {
        let (store, _) = try makeStore()
        let first = RawEvent(source: .manual, kind: .quickCapture, payload: RawEventPayload(text: "A"))
        let second = RawEvent(source: .manual, kind: .quickCapture, payload: RawEventPayload(text: "B"))
        XCTAssertTrue(store.insertRawEvent(first))
        XCTAssertTrue(store.insertRawEvent(second))

        let batches = store.exportableRawEventBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].firstSequence, 1)
        XCTAssertEqual(batches[0].lastSequence, 2)
        XCTAssertEqual(batches[0].id, store.exportableRawEventBatches()[0].id)
    }

    func testUserStateOperationsAreAppendOnlySequencedAndExportable() throws {
        let (store, _) = try makeStore()
        let firstPayload = Data("宿舍".utf8)
        let secondPayload = Data("寝室".utf8)
        let first = try XCTUnwrap(store.appendStateOperation(
            targetID: "place:abc", fieldKey: "name", operationType: "place.rename", payload: firstPayload
        ))
        let second = try XCTUnwrap(store.appendStateOperation(
            targetID: "place:abc", fieldKey: "name", operationType: "place.rename", payload: secondPayload
        ))

        XCTAssertEqual(first.originSequence, 1)
        XCTAssertEqual(second.originSequence, 2)
        XCTAssertEqual(store.allStateOperations().map(\.id), [first.id, second.id])
        XCTAssertEqual(try store.ownedFrontier().operations, 2)
        let batches = store.exportableStateOperationBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.firstSequence, 1)
        XCTAssertEqual(batches.first?.lastSequence, 2)
    }

    func testStateOperationBatchRollsBackAllWritesWhenOneIdentityConflicts() throws {
        let store = try makeStore().0
        let device = try XCTUnwrap(store.localDeviceIdentifier())
        let conflictingID = UUID()
        XCTAssertNotNil(store.appendStateOperation(
            id: conflictingID,
            targetID: "existing-target",
            fieldKey: "record",
            operationType: "test.record",
            payload: Data("existing".utf8)
        ))
        let operationsBefore = store.allStateOperations()
        let frontierBefore = try store.currentInputFrontier()
        let wouldBeFirst = V2Store.StateOperationDraft(
            id: UUID(), targetID: "new-target", fieldKey: "identity",
            operationType: "test.identity", payload: Data("new".utf8)
        )
        let conflicting = V2Store.StateOperationDraft(
            id: conflictingID, targetID: "different-target", fieldKey: "record",
            operationType: "test.record", payload: Data("conflict".utf8)
        )

        XCTAssertNil(store.appendStateOperationsAtomically([wouldBeFirst, conflicting]))
        XCTAssertEqual(store.allStateOperations(), operationsBefore)
        XCTAssertEqual(try store.currentInputFrontier(), frontierBefore)

        let first = V2Store.StateOperationDraft(
            id: UUID(), targetID: "batch-target-1", fieldKey: "record",
            operationType: "test.record", payload: Data("one".utf8)
        )
        let second = V2Store.StateOperationDraft(
            id: UUID(), targetID: "batch-target-2", fieldKey: "record",
            operationType: "test.record", payload: Data("two".utf8)
        )
        let appended = try XCTUnwrap(store.appendStateOperationsAtomically([first, second]))
        XCTAssertEqual(appended.count, 2)
        XCTAssertEqual(appended[1].originSequence, appended[0].originSequence + 1)
        XCTAssertEqual(
            appended[1].causalFrontier.operationSequences[device.rawValue],
            appended[0].originSequence
        )
    }

    func testCurrentDeviceRecoversOwnEventsOperationsAndArtifactsFromReplicationFolder() throws {
        let (store, databaseURL) = try makeStore()
        let device = try XCTUnwrap(store.localDeviceIdentifier())
        let key = SyncEncryptionKey()
        let directoryURL = databaseURL.deletingLastPathComponent().appendingPathComponent("replication", isDirectory: true)
        let directory = ReplicationDirectory(rootURL: directoryURL)
        let transport = EncryptedFileReplication(deviceID: device, directory: directory, key: key)
        let timestamp = Date(timeIntervalSince1970: 5_000)
        let payload = try JSONEncoder().encode(RiverEventPayload(appName: "Safari", bundleID: "com.apple.Safari"))
        let event = RiverEvent(
            originDeviceID: device,
            originSequence: 1,
            observedAt: timestamp,
            recordedAt: timestamp,
            source: "shortcuts",
            kind: "app.opened",
            payload: payload
        )
        let eventBatch = try RiverEventBatch(deviceID: device, events: [event])
        let clock = HybridLogicalClock(physicalMilliseconds: 5_000_000, deviceID: device)
        let operation = StateOperation(
            actorDeviceID: device,
            originSequence: 1,
            clock: clock,
            causalFrontier: try InputFrontier(),
            targetID: "place:school",
            fieldKey: "name",
            operationType: "place.rename",
            payload: try JSONEncoder().encode("学校")
        )
        let operationBatch = try StateOperationBatch(deviceID: device, operations: [operation])
        let content = Data("saved daily review".utf8)
        let revision = RiverArtifactRevision(
            id: "recovered-daily-review",
            logicalKey: "daily-review:1970-01-01",
            kind: .dailyReview,
            revisionNumber: 1,
            originDeviceID: device,
            clock: clock,
            inputFrontier: try InputFrontier(sequences: [device.rawValue: 1], operationSequences: [device.rawValue: 1]),
            inputSnapshotHash: "snapshot",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "model",
            content: content,
            contentHash: SHA256Hex.hash(content)
        )
        _ = try transport.publish(eventBatch, objectID: eventBatch.id, kind: "event_batch", stream: "Events")
        _ = try transport.publish(operationBatch, objectID: operationBatch.id, kind: "state_operation_batch", stream: "Operations")
        _ = try transport.publish(revision, objectID: revision.id, kind: "artifact_revision", stream: "Artifacts")

        let report = try RiverSyncCoordinator(store: store, directory: directory, key: key).synchronize()

        XCTAssertEqual(try store.ownedFrontier(), StreamFrontier(events: 1, operations: 1))
        XCTAssertEqual(store.rawEvents(ids: [event.id]).count, 1)
        XCTAssertEqual(store.allStateOperations().filter { $0.id == operation.id }.count, 1)
        XCTAssertEqual(store.localArtifactRevisions().map(\.id), [revision.id])
        XCTAssertEqual(report.importedEventBatches, 1)
        XCTAssertEqual(report.importedOperationBatches, 1)
        XCTAssertEqual(report.importedArtifactRevisions, 1)
        XCTAssertTrue(report.isVerified)
    }

    func testArtifactRevisionsPersistAndSelectOneCanonicalResult() throws {
        let (store, _) = try makeStore()
        let device = try XCTUnwrap(store.localDeviceIdentifier())
        let earlierFrontier = try InputFrontier(sequences: [device.rawValue: 1])
        let newerFrontier = try InputFrontier(sequences: [device.rawValue: 2])
        let earlierContent = Data("summary R1".utf8)
        let newerContent = Data("summary R2".utf8)
        func revision(_ id: String, _ number: UInt64, _ frontier: InputFrontier, _ content: Data) -> RiverArtifactRevision {
            RiverArtifactRevision(
                id: id,
                logicalKey: "daily-review:2026-09-28",
                kind: .dailyReview,
                revisionNumber: number,
                originDeviceID: device,
                clock: HybridLogicalClock(physicalMilliseconds: number, deviceID: device),
                inputFrontier: frontier,
                inputSnapshotHash: "snapshot-\(number)",
                pipelineVersion: "1.0",
                promptVersion: "1",
                modelProvider: "test",
                modelIdentifier: "model",
                content: content,
                contentHash: SHA256Hex.hash(content),
                dependencies: [ArtifactDependency(type: "event", id: "\(number)")]
            )
        }
        let first = revision("daily-review-r1", 1, earlierFrontier, earlierContent)
        let second = revision("daily-review-r2", 2, newerFrontier, newerContent)
        XCTAssertTrue(store.insertArtifactRevision(first))
        XCTAssertTrue(store.insertArtifactRevision(second))
        XCTAssertEqual(store.localArtifactRevisions().count, 2)
        XCTAssertEqual(store.canonicalArtifactRevisions().map(\.id), [second.id])
    }

    func testLateEventInvalidatesArtifactThroughAppendOnlyOperationAndNewRevisionWins() throws {
        let (store, _) = try makeStore()
        let device = try XCTUnwrap(store.localDeviceIdentifier())
        let range = DateInterval(start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 10_000))
        let initialFrontier = try InputFrontier()
        let firstContent = Data("早期日报".utf8)
        let first = RiverArtifactRevision(
            id: "daily-review-r1",
            logicalKey: "daily-review:1970-01-01",
            kind: .dailyReview,
            revisionNumber: 1,
            originDeviceID: device,
            clock: HybridLogicalClock(physicalMilliseconds: 1, deviceID: device),
            inputFrontier: initialFrontier,
            inputSnapshotHash: "before-late-event",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "model",
            content: firstContent,
            contentHash: SHA256Hex.hash(firstContent),
            dependencies: [ArtifactDependency(type: "time_range", id: "1970-01-01", rangeStart: range.start, rangeEnd: range.end)]
        )
        XCTAssertTrue(store.insertArtifactRevision(first))

        let lateEvent = RawEvent(
            timestamp: Date(timeIntervalSince1970: 5_000),
            source: .manual,
            kind: .quickCapture,
            payload: RawEventPayload(text: "晚到的记录")
        )
        XCTAssertTrue(store.insertRawEvent(lateEvent))
        XCTAssertEqual(store.canonicalArtifactRevisions().first?.id, first.id)
        XCTAssertEqual(store.canonicalArtifactRevisions().first?.status, .stale)
        XCTAssertEqual(store.localArtifactRevisions().first?.status, .current, "published revision fields stay immutable")
        let invalidations = store.allStateOperations().filter { $0.operationType == "artifact.stale" }
        XCTAssertEqual(invalidations.count, 1)

        XCTAssertTrue(store.insertRawEvent(lateEvent), "redelivery must remain idempotent")
        XCTAssertEqual(store.allStateOperations().filter { $0.operationType == "artifact.stale" }.count, 1)

        let secondContent = Data("补全后的日报".utf8)
        let fresh = RiverArtifactRevision(
            id: "daily-review-r2",
            logicalKey: first.logicalKey,
            kind: first.kind,
            revisionNumber: 2,
            originDeviceID: device,
            clock: HybridLogicalClock(physicalMilliseconds: 2, deviceID: device),
            inputFrontier: try InputFrontier(sequences: [device.rawValue: 1]),
            inputSnapshotHash: "after-late-event",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "model",
            content: secondContent,
            contentHash: SHA256Hex.hash(secondContent),
            dependencies: first.dependencies
        )
        XCTAssertTrue(store.insertArtifactRevision(fresh))
        XCTAssertEqual(store.canonicalArtifactRevisions().first?.id, fresh.id)
        XCTAssertEqual(store.canonicalArtifactRevisions().first?.status, .current)
    }

    func testLatestLocationEventRestoresCoordinateEvidence() throws {
        let (store, _) = try makeStore()
        let event = RawEvent(
            timestamp: Date(timeIntervalSince1970: 9_000),
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(
                latitude: 31.2304,
                longitude: 121.4737,
                horizontalAccuracy: 80,
                locationName: "图书馆"
            )
        )
        XCTAssertTrue(store.insertRawEvent(event))

        let latest = store.latestRawEvent(source: .location, kind: .locationUpdate)
        XCTAssertEqual(latest?.payload.latitude, 31.2304)
        XCTAssertEqual(latest?.payload.longitude, 121.4737)
        XCTAssertEqual(latest?.payload.locationName, "图书馆")
    }

    func testImportedPhoneVisitUsesSharedConfirmedPlaceNameInMacTimeline() throws {
        let (store, databaseURL) = try makeStore()
        let phone = RiverDeviceID(rawValue: "iphone_test")
        let arrivalID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let arrivalTime = DiaryEntry.dateFormatter.date(from: "2026-09-15")!
            .addingTimeInterval(8.5 * 3600)
        let encoder = JSONEncoder()
        let arrival = RiverEvent(
            id: arrivalID,
            originDeviceID: phone,
            originSequence: 1,
            observedAt: arrivalTime,
            source: "core_location",
            kind: "location.visit.arrival",
            payload: try encoder.encode(RiverEventPayload(latitude: 31.2304, longitude: 121.4737, horizontalAccuracy: 30))
        )
        let mapCandidate = RiverEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            originDeviceID: phone,
            originSequence: 2,
            observedAt: arrivalTime.addingTimeInterval(2),
            source: "mapkit",
            kind: "location.placeCandidate",
            payload: try encoder.encode(RiverEventPayload(
                latitude: 31.2305, longitude: 121.4738, horizontalAccuracy: 30,
                locationName: "某大学", mapAddress: "上海市长宁区", poiCategory: "School", mapProvider: "MapKit"
            ))
        )
        XCTAssertTrue(store.insertRawEvent(RawEvent(replica: arrival)))
        XCTAssertTrue(store.insertRawEvent(RawEvent(replica: mapCandidate)))
        let placeID = "place:\(arrivalID.uuidString.lowercased())"
        let rename = try JSONEncoder().encode("宿舍")
        XCTAssertNotNil(store.appendStateOperation(
            targetID: placeID,
            fieldKey: "userDefinedName",
            operationType: "place.rename",
            payload: rename
        ))
        XCTAssertTrue(store.rebuildPlaces())

        let activity = ActivityStore(
            activityDirectory: databaseURL.deletingLastPathComponent().appendingPathComponent("activity"),
            userDefaults: UserDefaults(suiteName: "location-marker-\(UUID().uuidString)" )!,
            v2Store: store
        )
        let markers = activity.locationMarkers(for: arrivalTime)

        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.title, "到达 宿舍")
        XCTAssertTrue(markers.first?.detail.contains("上海市长宁区") == true)
        XCTAssertEqual(markers.first?.originDeviceID, phone.rawValue)
    }

    func testEpisodeRoundTripPreservesProvenance() throws {
        let (store, _) = try makeStore()
        let rawA = UUID()
        let rawB = UUID()
        let activity = Activity(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 300),
            groupKey: "xcode",
            primaryApp: "Xcode",
            category: .focused,
            evidenceIDs: [rawA]
        )
        XCTAssertTrue(store.insertActivity(activity))

        let episode = Episode(
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 300),
            title: "Developing River",
            summary: "Reviewed architecture changes.",
            category: .work,
            confidence: 78,
            confidenceFactors: [ConfidenceFactor(name: "same-app", value: 0.9)],
            activityIDs: [activity.id],
            evidenceIDs: [rawB, rawA]
        )
        XCTAssertTrue(store.insertEpisode(episode))

        let loaded = store.episodes(between: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, episode.title)
        XCTAssertEqual(loaded[0].confidence, 78)
        XCTAssertEqual(loaded[0].confidenceFactors, episode.confidenceFactors)
        XCTAssertEqual(loaded[0].activityIDs, [activity.id])
        XCTAssertEqual(Set(loaded[0].evidenceIDs), Set([rawA, rawB]))
    }

    func testMemoryAndAnalysisRoundTrip() throws {
        let (store, _) = try makeStore()
        let episodeID = UUID()
        let memory = Memory(
            title: "常在深夜写代码",
            kind: .habit,
            confidence: 70,
            sourceEpisodeIDs: [episodeID]
        )
        XCTAssertTrue(store.insertMemory(memory))
        XCTAssertEqual(store.memories().count, 1)
        XCTAssertEqual(store.memories().first?.sourceEpisodeIDs, [episodeID])

        let evidence = UUID()
        let run = AnalysisRun(
            task: .weeklyReview,
            inputContextReference: UUID(),
            outputText: "本周主要在开发 River。",
            evidenceIDs: [evidence],
            model: "test-model"
        )
        XCTAssertTrue(store.insertAnalysisRun(run))
        let runs = store.analysisRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.evidenceIDs, [evidence])
        XCTAssertEqual(runs.first?.model, "test-model")
    }

    func testMemoryConfirmationRoundTripUpdatesEffectiveMemoryState() throws {
        let (store, _) = try makeStore()
        let memory = Memory(title: "确认测试")
        XCTAssertTrue(store.insertMemory(memory))
        XCTAssertTrue(store.setMemoryConfirmation(memory.id, confirmed: false, note: "需要修正"))
        XCTAssertEqual(store.memoryConfirmation(for: memory.id)?.confirmed, false)
        XCTAssertEqual(store.memoryConfirmation(for: memory.id)?.note, "需要修正")
        XCTAssertEqual(store.memories().first?.isUserConfirmed, false)
        XCTAssertNotNil(store.memories().first?.lastConfirmedAt)
        XCTAssertTrue(store.setMemoryConfirmation(memory.id, confirmed: true))
        XCTAssertEqual(store.memoryConfirmation(for: memory.id)?.confirmed, true)
        XCTAssertEqual(store.memories().first?.isUserConfirmed, true)
    }

    func testContextSnapshotCanBackAnalysisRunReference() throws {
        let (store, _) = try makeStore()
        let snapshotID = UUID()
        XCTAssertTrue(store.insertContextSnapshot(id: snapshotID, payloadJSON: #"{"query":"这周"}"#, model: "test-model"))
        XCTAssertTrue(store.contextSnapshotExists(snapshotID))
        XCTAssertEqual(store.contextSnapshot(id: snapshotID)?.payloadJSON, #"{"query":"这周"}"#)
        let run = AnalysisRun(task: .memorySearch, inputContextReference: snapshotID, outputText: "结果")
        XCTAssertTrue(store.insertAnalysisRun(run))
        let loaded = try XCTUnwrap(store.analysisRuns().first)
        XCTAssertEqual(loaded.inputContextReference, snapshotID)
        XCTAssertNotNil(loaded.inputContextReference.flatMap(store.contextSnapshot(id:)))
    }

    func testClearDerivedKeepsEvidence() throws {
        let (store, _) = try makeStore()
        let raw = RawEvent(source: .manual, kind: .quickCapture, payload: RawEventPayload(text: "留着"))
        let episode = Episode(startTime: Date(), endTime: Date(), title: "will be cleared")
        XCTAssertTrue(store.insertRawEvent(raw))
        XCTAssertTrue(store.insertEpisode(episode))
        XCTAssertTrue(store.insertMemory(Memory(title: "m")))

        store.clearDerivedData()

        XCTAssertEqual(store.countRows(in: .rawEvents), 1)
        XCTAssertEqual(store.countRows(in: .episodes), 0)
        XCTAssertEqual(store.countRows(in: .memories), 0)
        XCTAssertEqual(store.countRows(in: .analysisRuns), 0)
    }

    func testUserPrefsPersist() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.setUserPref(key: "savedQuery.pinned", value: "本周工作"))
        XCTAssertEqual(store.userPref(key: "savedQuery.pinned"), "本周工作")
        XCTAssertNil(store.userPref(key: "missing"))
    }
}
