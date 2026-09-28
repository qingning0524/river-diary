import XCTest
import RiverDiaryCore
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
