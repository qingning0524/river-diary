import Foundation
import CryptoKit
import RiverDiaryCore
import SQLite3
import XCTest
@testable import RiverDiary

@MainActor
final class RiverLocalDatabaseSessionProjectionTests: XCTestCase {
    func testEvidenceLookupBatchesRemainCompleteOrderedAndDeduplicated() throws {
        let database = try RiverLocalDatabase(databaseURL: makeDatabaseURL(), testDeviceID: RiverDeviceID(rawValue: "iphone-evidence-batch-test"))
        var ids: [UUID] = []
        for index in 0..<1_010 {
            let event = try database.append(source: "manual", kind: "manual.note", payload: RiverEventPayload(text: "record \(index)"), observedAt: Date(timeIntervalSince1970: Double(index)))
            ids.append(event.id)
        }
        let result = try database.events(ids: Array(ids.reversed()) + [ids[0], UUID()])
        XCTAssertEqual(result.map(\.id), ids)
        XCTAssertEqual(result.count, 1_010)
        XCTAssertEqual(try database.savedEventCount(), 1_010)
    }

    func testSchemaV6UpgradeRebuildsPersistedSessionsAndFrontier() throws {
        let databaseURL = try makeDatabaseURL()
        let deviceID = RiverDeviceID(rawValue: "iphone-session-migration-test")
        let app = RiverLocalDatabasePayloadFixtures.app

        do {
            let database = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: deviceID)
            _ = try database.append(
                source: "shortcuts", kind: "app.opened", payload: app,
                observedAt: Date(timeIntervalSince1970: 100)
            )
            _ = try database.append(
                source: "shortcuts", kind: "app.closed", payload: app,
                observedAt: Date(timeIntervalSince1970: 160)
            )
            XCTAssertEqual(try database.allSessions().count, 1)
        }

        try executeSQL("""
        DELETE FROM timeline_sessions;
        DROP TABLE timeline_session_frontiers;
        DROP TABLE timeline_session_dirty_devices;
        CREATE TABLE timeline_session_dirty_devices(device_id TEXT PRIMARY KEY);
        DELETE FROM sync_state WHERE key = 'derived.timelineSessions.dirty';
        PRAGMA user_version = 6;
        """, at: databaseURL)

        let reopened = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: deviceID)
        let migrated = try XCTUnwrap(try reopened.allSessions().first)
        XCTAssertEqual(migrated.endReason, .observedClose)
        XCTAssertEqual(migrated.duration ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(
            try integerValue("PRAGMA user_version", at: databaseURL),
            Int(RiverLocalDatabase.currentSchemaVersion)
        )
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM timeline_session_dirty_devices", at: databaseURL), 0)
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM timeline_session_frontiers", at: databaseURL), 1)
    }

    func testIncrementalSessionTailUpdatesOnlyTheChangedDeviceRows() throws {
        let databaseURL = try makeDatabaseURL()
        let phoneID = RiverDeviceID(rawValue: "iphone-session-test")
        let macID = RiverDeviceID(rawValue: "mac-session-test")
        let database = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: phoneID)
        let app = RiverLocalDatabasePayloadFixtures.app

        var phoneEvents: [RiverEvent] = []
        for index in 0..<20 {
            let start = TimeInterval(1_000 + index * 100)
            phoneEvents.append(RiverEvent(
                originDeviceID: phoneID, originSequence: UInt64(index * 2 + 1),
                observedAt: Date(timeIntervalSince1970: start), source: "shortcuts", kind: "app.opened",
                payload: try JSONEncoder().encode(app)
            ))
            phoneEvents.append(RiverEvent(
                originDeviceID: phoneID, originSequence: UInt64(index * 2 + 2),
                observedAt: Date(timeIntervalSince1970: start + 60), source: "shortcuts", kind: "app.closed",
                payload: try JSONEncoder().encode(app)
            ))
        }
        phoneEvents.append(RiverEvent(
            originDeviceID: phoneID, originSequence: 41,
            observedAt: Date(timeIntervalSince1970: 3_000), source: "shortcuts", kind: "app.opened",
            payload: try JSONEncoder().encode(app)
        ))
        let phoneBatch = try RiverEventBatch(deviceID: phoneID, events: phoneEvents)
        XCTAssertTrue(try database.restoreOwnedEventBatch(
            phoneBatch, objectID: "test-phone-session-batch", ciphertextHash: "test-phone-hash"
        ))
        XCTAssertEqual(try database.allSessions().count, 21)

        let remoteOpen = RiverEvent(
            originDeviceID: macID,
            originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 3_500),
            source: "shortcuts",
            kind: "app.opened",
            payload: try JSONEncoder().encode(RiverLocalDatabasePayloadFixtures.macApp)
        )
        let remoteBatch = try RiverEventBatch(deviceID: macID, events: [remoteOpen])
        XCTAssertTrue(try database.importBatch(remoteBatch, objectID: "test-mac-session-batch", ciphertextHash: "test-hash"))
        XCTAssertEqual(try database.allSessions().count, 22)

        try executeSQL("""
        CREATE TABLE session_projection_mutations(operation TEXT NOT NULL, device_id TEXT NOT NULL);
        CREATE TRIGGER record_session_projection_insert AFTER INSERT ON timeline_sessions
        BEGIN
          INSERT INTO session_projection_mutations(operation, device_id) VALUES ('insert', NEW.origin_device_id);
        END;
        CREATE TRIGGER record_session_projection_update AFTER UPDATE ON timeline_sessions
        BEGIN
          INSERT INTO session_projection_mutations(operation, device_id) VALUES ('update', NEW.origin_device_id);
        END;
        CREATE TRIGGER record_session_projection_delete AFTER DELETE ON timeline_sessions
        BEGIN
          INSERT INTO session_projection_mutations(operation, device_id) VALUES ('delete', OLD.origin_device_id);
        END;
        """, at: databaseURL)

        _ = try database.append(
            source: "core_location", kind: "location.visit.arrival",
            payload: RiverEventPayload(latitude: 37, longitude: -122),
            observedAt: Date(timeIntervalSince1970: 3_600)
        )
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM session_projection_mutations", at: databaseURL), 0)

        _ = try database.append(
            source: "shortcuts", kind: "app.closed", payload: app,
            observedAt: Date(timeIntervalSince1970: 3_700)
        )
        XCTAssertEqual(
            try strings("SELECT DISTINCT device_id FROM session_projection_mutations ORDER BY device_id", at: databaseURL),
            [phoneID.rawValue]
        )
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM session_projection_mutations", at: databaseURL), 1,
                       "an ordered tail append should update its active row without rewriting completed history")

        let sessions = try database.allSessions()
        XCTAssertEqual(sessions.count, 22)
        XCTAssertEqual(sessions.filter { $0.originDeviceID == phoneID }.count, 21)
        XCTAssertEqual(sessions.first { $0.originDeviceID == phoneID }?.endReason, .observedClose)
        XCTAssertEqual(sessions.first { $0.originDeviceID == macID }?.endReason, .stillOpen)

        try executeSQL("DELETE FROM session_projection_mutations", at: databaseURL)
        _ = try database.append(
            source: "shortcuts", kind: "app.opened", payload: app,
            observedAt: Date(timeIntervalSince1970: 3_650)
        )
        XCTAssertGreaterThan(try integerValue("SELECT COUNT(*) FROM session_projection_mutations", at: databaseURL), 1,
                             "a backdated app Event must use the device full-rebuild path")
        XCTAssertEqual(try database.allSessions().filter { $0.originDeviceID == macID }.count, 1)
    }

    func testShortcutActivityRecorderPersistsEventsAndBuildsSession() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-shortcuts-recorder-test")
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let end = Date(timeIntervalSince1970: 1_420)

        let opened = try RiverAppActivityRecorder.record(
            displayName: " Safari ", appIdentifier: " com.apple.mobilesafari ",
            transition: .opened, observedAt: start, in: database
        )
        let closed = try RiverAppActivityRecorder.record(
            displayName: "Safari", appIdentifier: "com.apple.mobilesafari",
            transition: .closed, observedAt: end, in: database
        )

        XCTAssertEqual(opened.source, "shortcuts")
        XCTAssertEqual(opened.kind, "app.opened")
        XCTAssertEqual(closed.source, "shortcuts")
        XCTAssertEqual(closed.kind, "app.closed")
        XCTAssertNotEqual(opened.id, closed.id)

        let session = try XCTUnwrap(try database.allSessions().first)
        XCTAssertEqual(session.applicationIdentifier, "com.apple.mobilesafari")
        XCTAssertEqual(session.displayName, "Safari")
        XCTAssertEqual(session.start, start)
        XCTAssertEqual(session.end, end)
        XCTAssertEqual(session.endReason, .observedClose)
        XCTAssertEqual(session.duration ?? -1, 420, accuracy: 0.001)
    }

    func testShortcutActivityRecorderRejectsBlankAppIdentityWithoutWriting() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-shortcuts-validation-test")
        )

        XCTAssertThrowsError(try RiverAppActivityRecorder.record(
            displayName: "  ", appIdentifier: "com.apple.mobilesafari",
            transition: .opened, in: database
        ))
        XCTAssertThrowsError(try RiverAppActivityRecorder.record(
            displayName: "Safari", appIdentifier: " \n ",
            transition: .closed, in: database
        ))
        XCTAssertTrue(try database.allEvents().isEmpty)
    }

    func testShortcutOpenDoesNotRebuildFullPlaceOrSharedRecordProjections() throws {
        let databaseURL = try makeDatabaseURL()
        let deviceID = RiverDeviceID(rawValue: "iphone-shortcuts-projection-test")
        let initialDatabase = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: deviceID)
        try initialDatabase.rebuildDerivedState()
        try executeSQL("""
        INSERT INTO places(place_id, latitude, longitude, radius_meters, first_seen, last_seen)
            VALUES ('projection-sentinel-place', 0, 0, 100, 0, 0);
        INSERT INTO shared_user_records(record_id, record_kind, status, logical_key, payload_json, created_at, updated_at)
            VALUES ('projection-sentinel-record', 'pending_confirmation', 'pending', 'test', '{}', 0, 0);
        CREATE TABLE projection_rebuilds(name TEXT NOT NULL);
        CREATE TRIGGER track_place_rebuild AFTER DELETE ON places
        BEGIN INSERT INTO projection_rebuilds(name) VALUES ('places'); END;
        CREATE TRIGGER track_shared_record_rebuild AFTER DELETE ON shared_user_records
        BEGIN INSERT INTO projection_rebuilds(name) VALUES ('shared_user_records'); END;
        """, at: databaseURL)

        let database = try RiverLocalDatabase(
            databaseURL: databaseURL,
            testDeviceID: deviceID,
            rebuildDerivedProjectionsOnOpen: false
        )
        _ = try RiverAppActivityRecorder.record(
            displayName: "Safari", appIdentifier: "com.apple.mobilesafari",
            transition: .opened, observedAt: Date(timeIntervalSince1970: 1_500), in: database
        )

        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM projection_rebuilds", at: databaseURL), 0)
        try database.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM projection_rebuilds", at: databaseURL), 0,
                       "a local app Event is reconciled inline and must not schedule a full projection rebuild")
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM raw_events WHERE kind = 'app.opened'", at: databaseURL), 1)
    }

    func testSyncDerivedReconciliationSkipsCleanStoreAndRunsAfterImportedBatch() throws {
        let databaseURL = try makeDatabaseURL()
        let phoneID = RiverDeviceID(rawValue: "iphone-derived-reconcile-test")
        let database = try RiverLocalDatabase(databaseURL: databaseURL, testDeviceID: phoneID)
        try database.rebuildDerivedState()
        try executeSQL("""
        INSERT INTO places(place_id, latitude, longitude, radius_meters, first_seen, last_seen)
            VALUES ('sync-rebuild-sentinel', 0, 0, 100, 0, 0);
        CREATE TABLE projection_rebuilds(name TEXT NOT NULL);
        CREATE TRIGGER track_place_rebuild AFTER DELETE ON places
        BEGIN INSERT INTO projection_rebuilds(name) VALUES ('places'); END;
        """, at: databaseURL)

        try database.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM projection_rebuilds", at: databaseURL), 0)

        let macID = RiverDeviceID(rawValue: "mac-derived-reconcile-test")
        let event = RiverEvent(
            originDeviceID: macID, originSequence: 1,
            observedAt: Date(timeIntervalSince1970: 2_000), source: "shortcuts", kind: "app.opened",
            payload: try JSONEncoder().encode(RiverLocalDatabasePayloadFixtures.macApp)
        )
        let batch = try RiverEventBatch(deviceID: macID, events: [event])
        XCTAssertTrue(try database.importEventBatch(batch, objectID: batch.id, ciphertextHash: "test-hash"))
        try database.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM projection_rebuilds", at: databaseURL), 1)

        try database.reconcileDerivedStateIfNeeded()
        XCTAssertEqual(try integerValue("SELECT COUNT(*) FROM projection_rebuilds", at: databaseURL), 1)
    }

    func testTimelinePresentationShowsSessionsAsActivitiesAndKeepsOtherEvidenceTyped() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-timeline-presentation-test")
        )
        let dayStart = Calendar.current.startOfDay(for: Date())
        let start = dayStart.addingTimeInterval(8 * 3_600)
        let end = start.addingTimeInterval(42 * 60)
        let opened = try database.append(
            source: "shortcuts", kind: "app.opened",
            payload: RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"), observedAt: start
        )
        let closed = try database.append(
            source: "shortcuts", kind: "app.closed",
            payload: RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"), observedAt: end
        )
        let macID = RiverDeviceID(rawValue: "mac-timeline-presentation-test")
        let macStart = start.addingTimeInterval(10 * 60)
        let macEvents = [
            RiverEvent(originDeviceID: macID, originSequence: 1, observedAt: macStart,
                       source: "macos", kind: "app.opened",
                       payload: try JSONEncoder().encode(RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode"))),
            RiverEvent(originDeviceID: macID, originSequence: 2, observedAt: macStart.addingTimeInterval(20 * 60),
                       source: "macos", kind: "app.closed",
                       payload: try JSONEncoder().encode(RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode")))
        ]
        let macBatch = try RiverEventBatch(deviceID: macID, events: macEvents)
        XCTAssertTrue(try database.importBatch(macBatch, objectID: macBatch.id, ciphertextHash: "timeline-fusion-test"))
        _ = try database.append(
            source: "healthkit", kind: "health.steps",
            payload: RiverEventPayload(metrics: RiverEventMetrics(steps: 1_234)), observedAt: end.addingTimeInterval(5)
        )
        _ = try database.append(
            source: "manual", kind: "manual.note",
            payload: RiverEventPayload(text: "给自己留一段安静时间"), observedAt: end.addingTimeInterval(10)
        )

        let rows = RiverIOSProjection.timelineRows(database: database, date: dayStart)
        let appRows = rows.filter { $0.kind == .app }
        XCTAssertEqual(appRows.count, 1)
        XCTAssertEqual(Set(appRows[0].eventIDs), Set([opened.id, closed.id] + macEvents.map(\.id)))
        XCTAssertEqual(appRows[0].duration ?? 0, 42 * 60, accuracy: 0.01)
        XCTAssertEqual(appRows[0].sourceLabel, "iPhone 与 Mac 的重叠活动")
        XCTAssertTrue(appRows[0].detail.contains("Xcode"))
        XCTAssertEqual(rows.filter { $0.kind == .health }.count, 1)
        XCTAssertEqual(rows.filter { $0.kind == .note }.count, 1)
        XCTAssertFalse(rows.contains { $0.title == "使用 Safari" && $0.id.hasPrefix("event:") },
                       "Covered app Events should stay inside the activity details, not reappear as raw rows.")
    }

    func testSharedSemanticTimelineArtifactRequiresLocalEvidenceBeforeDisplay() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-semantic-timeline-test")
        )
        let dayStart = Calendar.current.startOfDay(for: Date())
        let start = dayStart.addingTimeInterval(10 * 3_600)
        let end = start.addingTimeInterval(30 * 60)
        let event = try database.append(
            source: "shortcuts", kind: "app.opened",
            payload: RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"), observedAt: start
        )
        let missingEvidenceID = UUID()
        let digest = RiverIOSSemanticTimelineFixture(
            dayKey: RiverIOSProjection.dayKey(dayStart),
            segments: [
                .init(candidateIDs: ["candidate:local"], title: "连续整理旅行资料", summary: "Safari 活动与之后的浏览记录有时间连续性。",
                      evidenceRefs: ["raw:\(event.id.uuidString.lowercased())"], start: start, end: end),
                .init(candidateIDs: ["candidate:remote-only"], title: "不可验证的远端片段", summary: "这台 iPhone 上没有对应记录。",
                      evidenceRefs: ["raw:\(missingEvidenceID.uuidString.lowercased())"], start: start, end: end)
            ]
        )
        let content = try JSONEncoder().encode(digest)
        let deviceID = database.deviceID
        let artifact = RiverArtifactRevision(
            id: "semantic-timeline-local-evidence",
            logicalKey: "timelineDigest|d-\(digest.dayKey)",
            kind: .semanticTimeline,
            revisionNumber: 1,
            originDeviceID: deviceID,
            clock: HybridLogicalClock(physicalMilliseconds: 100, deviceID: deviceID),
            inputFrontier: try database.currentInputFrontier(),
            inputSnapshotHash: "test-snapshot",
            pipelineVersion: "1.0",
            promptVersion: "1",
            modelProvider: "test",
            modelIdentifier: "fixture",
            content: content,
            contentHash: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined(),
            status: .provisional
        )
        try database.insertArtifactRevision(artifact)

        let insights = RiverIOSProjection.timelineInsights(database: database, date: dayStart)
        XCTAssertEqual(insights.count, 1, "An Artifact segment without matching local Event evidence must stay hidden.")
        XCTAssertEqual(insights[0].title, "连续整理旅行资料")
        XCTAssertEqual(insights[0].eventIDs, [event.id])
        XCTAssertEqual(insights[0].sourceLabel, "River 暂定理解 · 等待其他设备核对")
    }

    func testFootprintProjectionSeparatesRepeatedVisitsWithoutInventingPlaceMeaning() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-footprint-projection-test")
        )
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3_600)
        let coordinate = (latitude: 31.23, longitude: 121.47)
        _ = try database.append(
            source: "core_location", kind: "location.visit.arrival",
            payload: RiverEventPayload(latitude: coordinate.latitude, longitude: coordinate.longitude), observedAt: start
        )
        _ = try database.append(
            source: "core_location", kind: "location.significant",
            payload: RiverEventPayload(latitude: coordinate.latitude + 0.0001, longitude: coordinate.longitude),
            observedAt: start.addingTimeInterval(30 * 60)
        )
        _ = try database.append(
            source: "core_location", kind: "location.visit.departure",
            payload: RiverEventPayload(latitude: coordinate.latitude, longitude: coordinate.longitude),
            observedAt: start.addingTimeInterval(60 * 60)
        )
        _ = try database.append(
            source: "core_location", kind: "location.visit.arrival",
            payload: RiverEventPayload(latitude: coordinate.latitude, longitude: coordinate.longitude),
            observedAt: start.addingTimeInterval(4 * 60 * 60)
        )

        let stops = RiverIOSProjection.footprintStops(events: database.timelineEvents, places: [])
        XCTAssertEqual(stops.count, 2, "A departure ends a visit even when the later visit is at the same coordinates.")
        XCTAssertEqual(stops[0].eventIDs.count, 3)
        XCTAssertEqual(stops[1].eventIDs.count, 1)
        XCTAssertTrue(stops.allSatisfy { $0.title.hasPrefix("位置线索") }, "Unmatched coordinates must not be given a fabricated place name.")

        let candidatePlace = RiverPlace(
            id: "map-candidate", latitude: coordinate.latitude, longitude: coordinate.longitude,
            radiusMeters: 200, mapName: "上海图书馆", mapAddress: "徐汇区", poiCategory: "library",
            mapProvider: "test", mapResultIdentifier: nil, userDefinedName: nil, semanticType: nil,
            isUserConfirmed: false, confidence: 0.72, firstSeen: start, lastSeen: start,
            visitCount: 1, totalDurationSeconds: 0
        )
        let candidateStops = RiverIOSProjection.footprintStops(events: database.timelineEvents, places: [candidatePlace])
        XCTAssertEqual(candidateStops.first?.displayTitle, "可能是 上海图书馆")
        XCTAssertTrue(candidateStops.allSatisfy(\.isNameCandidate))

        let confirmedPlace = RiverPlace(
            id: "confirmed-place", latitude: coordinate.latitude, longitude: coordinate.longitude,
            radiusMeters: 200, mapName: "上海图书馆", mapAddress: "徐汇区", poiCategory: "library",
            mapProvider: "test", mapResultIdentifier: nil, userDefinedName: "我常去的图书馆", semanticType: "library",
            isUserConfirmed: true, confidence: 1, firstSeen: start, lastSeen: start,
            visitCount: 1, totalDurationSeconds: 0
        )
        let confirmedStops = RiverIOSProjection.footprintStops(events: database.timelineEvents, places: [confirmedPlace])
        XCTAssertEqual(confirmedStops.first?.displayTitle, "我常去的图书馆")
        XCTAssertTrue(confirmedStops.allSatisfy { !$0.isNameCandidate })
    }

    func testHabitAnswerUndoWritesRuleRetirementAndReopenedCardAtomically() throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-habit-undo-test")
        )
        let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000880")!
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-000000000881")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let activeRule = RiverSharedStateRecord(
            id: ruleID, kind: .habitRule, status: "active", logicalKey: "pattern:com.example.app",
            payloadJSON: "{\"id\":\"\(ruleID.uuidString)\",\"status\":\"active\",\"scopeText\":\"Safari\"}",
            createdAt: date, updatedAt: date
        )
        let answeredCard = RiverSharedStateRecord(
            id: cardID, kind: .habitCard, status: "answered", logicalKey: "pattern:com.example.app",
            payloadJSON: "{\"question\":\"通常算作工作吗？\",\"status\":\"answered\",\"createdRuleID\":\"\(ruleID.uuidString)\"}",
            createdAt: date, updatedAt: date
        )
        try database.saveSharedUserRecords([activeRule, answeredCard])
        let operationCountBeforeUndo = try database.allStateOperations().count

        let retiredRule = RiverSharedStateRecord(
            id: ruleID, kind: .habitRule, status: "retired", logicalKey: activeRule.logicalKey,
            payloadJSON: "{\"id\":\"\(ruleID.uuidString)\",\"status\":\"retired\"}",
            createdAt: date, updatedAt: date.addingTimeInterval(10)
        )
        let reopenedCard = RiverSharedStateRecord(
            id: cardID, kind: .habitCard, status: "shown", logicalKey: answeredCard.logicalKey,
            payloadJSON: "{\"question\":\"通常算作工作吗？\",\"status\":\"shown\",\"userReopenedAt\":\"2023-11-14T22:13:30Z\"}",
            createdAt: date, updatedAt: date.addingTimeInterval(10), shownAt: date.addingTimeInterval(10)
        )
        try database.saveSharedUserRecordsAtomically([retiredRule, reopenedCard])

        let operations = try database.allStateOperations().sorted { $0.originSequence < $1.originSequence }
        XCTAssertEqual(operations.count, operationCountBeforeUndo + 2)
        XCTAssertEqual(operations.suffix(2).last!.originSequence, operations.suffix(2).first!.originSequence + 1)
        XCTAssertEqual(database.sharedUserRecords.first { $0.id == cardID }?.status, "shown")
        XCTAssertEqual(database.sharedUserRecords.first { $0.id == ruleID }?.status, "retired")
    }

    func testDailyReviewCanUseManualJournalOnlyWhenManualTextIsSelected() async throws {
        let database = try RiverLocalDatabase(
            databaseURL: makeDatabaseURL(),
            testDeviceID: RiverDeviceID(rawValue: "iphone-journal-ai-scope-test")
        )
        let dayKey = RiverIOSProjection.dayKey(Date())
        let journalText = "今天我把行程留白，慢慢读完一本书。"
        let journal = try XCTUnwrap(RiverSharedStateRecord.journalEntry(RiverJournalEntryContent(
            dayKey: dayKey, body: journalText, updatedAt: Date()
        )))
        try database.saveSharedUserRecord(journal)

        let previousEndpoint = UserDefaults.standard.object(forKey: "river.ai.endpoint")
        let previousModel = UserDefaults.standard.object(forKey: "river.ai.model")
        let previousManualScope = UserDefaults.standard.object(forKey: "river.ai.includeManualText")
        defer {
            restore(previousEndpoint, forKey: "river.ai.endpoint")
            restore(previousModel, forKey: "river.ai.model")
            restore(previousManualScope, forKey: "river.ai.includeManualText")
        }

        MockRiverAIURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockRiverAIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let ai = IPhoneAIStore(database: database, session: session)
        ai.endpoint = "http://localhost/v1/chat/completions"
        ai.model = "test-local-model"
        ai.includeManualText = false

        await ai.analyzeToday()
        XCTAssertEqual(MockRiverAIURLProtocol.capturedRequestBodies.count, 0,
                       "A manual journal must stay out of the prompt until that category is selected.")

        ai.includeManualText = true
        await ai.analyzeToday()
        XCTAssertNil(ai.errorMessage, ai.errorMessage ?? "AI request did not complete.")
        XCTAssertEqual(MockRiverAIURLProtocol.capturedRequestBodies.count, 1)
        let requestBody = MockRiverAIURLProtocol.capturedRequestBodies[0]
        XCTAssertFalse(requestBody.isEmpty, "The local mock should capture the request body.")
        let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        let messages = try XCTUnwrap(requestJSON["messages"] as? [[String: Any]])
        let userPrompt = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(userPrompt.contains(journalText))
        XCTAssertEqual(ai.dailyReview, "只基于手写记录生成的本地回顾。")
        let artifact = try XCTUnwrap(database.canonicalArtifactRevisions().first {
            $0.logicalKey == RiverCanonicalArtifactKey.dailyReview(dayKey: dayKey) && $0.kind == .dailyReview
        })
        XCTAssertTrue(artifact.dependencies.contains { $0.type == "shared_record" && $0.id == "journal:\(dayKey)" })
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func testRiverNodeActionsUndoHabitAndReopenResolvedQuestion() throws {
        let keys = [
            "river.location.enabled", "river.ai.endpoint", "river.ai.model", "river.ai.includePlaces",
            "river.ai.includeHealth", "river.ai.includeManualText", "river.ai.includeSharedMemories", "river.ai.networkConsent"
        ]
        let savedValues = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in keys { restore(savedValues[key], forKey: key) }
        }
        UserDefaults.standard.set(false, forKey: "river.location.enabled")
        UserDefaults.standard.set(false, forKey: "river.ai.networkConsent")

        let databaseURL = try makeDatabaseURL()
        let node = RiverNodeStore(
            databaseURL: databaseURL,
            testDeviceID: RiverDeviceID(rawValue: "iphone-node-actions-test")
        )
        let database = try XCTUnwrap(node.database)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000882")!
        let ruleID = UUID(uuidString: "00000000-0000-0000-0000-000000000883")!
        let rule = RiverSharedStateRecord(
            id: ruleID, kind: .habitRule, status: "active", logicalKey: "pattern:com.example.app",
            payloadJSON: "{\"id\":\"\(ruleID.uuidString)\",\"status\":\"active\"}",
            createdAt: date, updatedAt: date
        )
        let answeredCard = RiverSharedStateRecord(
            id: cardID, kind: .habitCard, status: "answered", logicalKey: "pattern:com.example.app",
            payloadJSON: "{\"question\":\"通常算作工作吗？\",\"status\":\"answered\",\"createdRuleID\":\"\(ruleID.uuidString)\"}",
            createdAt: date, updatedAt: date
        )
        try database.saveSharedUserRecords([rule, answeredCard])

        node.undoSharedHabitCard(answeredCard)
        XCTAssertEqual(database.sharedUserRecords.first { $0.id == cardID }?.status, "shown")
        XCTAssertEqual(database.sharedUserRecords.first { $0.id == ruleID }?.status, "retired")
        XCTAssertTrue(try XCTUnwrap(database.sharedUserRecords.first { $0.id == cardID }).payloadJSON.contains("userReopenedAt"))

        let naturalCard = RiverSharedStateRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000884")!,
            kind: .habitCard, status: "shown", logicalKey: "pattern:com.example.safari",
            payloadJSON: "{\"question\":\"Safari 通常用来做什么？\",\"appName\":\"Safari\",\"bundleID\":\"com.apple.mobilesafari\",\"examples\":[]}",
            createdAt: date, updatedAt: date
        )
        try database.saveSharedUserRecord(naturalCard)
        node.answerSharedHabitCard(
            naturalCard, naturalLanguage: "我用 Safari 查阅旅行资料。", saveAsLongTermRule: true
        )
        let savedAnswer = try XCTUnwrap(database.sharedUserRecords.first { $0.id == naturalCard.id })
        XCTAssertEqual(savedAnswer.status, "answered")
        let savedRule = try XCTUnwrap(database.sharedUserRecords.first {
            $0.kind == .habitRule && $0.status == "active" && $0.id != ruleID
        })
        let rulePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(savedRule.payloadJSON.utf8)) as? [String: Any])
        XCTAssertEqual(rulePayload["naturalLanguageRule"] as? String, "我用 Safari 查阅旅行资料。")

        let question = try XCTUnwrap(RiverSharedStateRecord.timelineClarification(
            candidateID: "node-reopen-question", observation: "你在持续使用 Safari。",
            opening: "这段时间通常在做什么？", evidenceRefs: [], createdAt: date
        ))
        try database.saveSharedUserRecord(question)
        node.resolveSharedPendingConfirmation(question, as: .corrected, correction: "查阅旅行资料")
        let resolvedQuestion = try XCTUnwrap(database.sharedUserRecords.first { $0.id == question.id })
        XCTAssertEqual(resolvedQuestion.status, "corrected")

        node.reopenSharedPendingConfirmation(resolvedQuestion)
        let reopenedQuestion = try XCTUnwrap(database.sharedUserRecords.first { $0.id == question.id })
        XCTAssertEqual(reopenedQuestion.status, "pending")
        XCTAssertNotNil(reopenedQuestion.pendingConfirmationContent?.userReopenedAt)
    }

    func testTwoSQLiteNodesConvergeEventsAndSharedConfirmationThroughEncryptedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-two-sqlite-nodes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let phoneID = RiverDeviceID(rawValue: "iphone-sqlite-sync-test")
        let macID = RiverDeviceID(rawValue: "mac-sqlite-sync-test")
        let phone = try RiverLocalDatabase(
            databaseURL: root.appendingPathComponent("phone.sqlite"), testDeviceID: phoneID
        )
        let mac = try RiverLocalDatabase(
            databaseURL: root.appendingPathComponent("mac.sqlite"), testDeviceID: macID
        )
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

        let phoneEvent = try phone.append(
            source: "shortcuts", kind: "app.opened",
            payload: RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari"),
            observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let macEvent = try mac.append(
            source: "macos", kind: "mac.application.active",
            payload: RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode"),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )
        let confirmation = try XCTUnwrap(RiverSharedStateRecord.timelineClarification(
            candidateID: "sqlite-sync-candidate",
            observation: "14:00–14:30 正在处理 River Diary。",
            opening: "这段活动的主要目标是什么？",
            evidenceRefs: ["raw:\(phoneEvent.id.uuidString.lowercased())"],
            createdAt: Date(timeIntervalSince1970: 2_100)
        ))
        try phone.saveSharedUserRecord(confirmation)

        let directory = ReplicationDirectory(rootURL: root.appendingPathComponent("Replication", isDirectory: true))
        let key = SyncEncryptionKey()
        let phoneSync = try RiverSyncCoordinator(store: phone, directory: directory, key: key)
        let macSync = try RiverSyncCoordinator(store: mac, directory: directory, key: key)
        var phoneReport: SyncRunReport?
        var macReport: SyncRunReport?
        for _ in 0..<6 {
            phoneReport = try phoneSync.synchronize()
            macReport = try macSync.synchronize()
            if phoneReport?.isVerified == true && macReport?.isVerified == true { break }
        }

        XCTAssertTrue(try XCTUnwrap(phoneReport).isVerified)
        XCTAssertTrue(try XCTUnwrap(macReport).isVerified)
        XCTAssertEqual(Set(try phone.allEvents().map(\.id)), Set(try mac.allEvents().map(\.id)))
        XCTAssertEqual(Set(try phone.allEvents().map(\.id)), Set([phoneEvent.id, macEvent.id]))
        XCTAssertEqual(Set(try phone.allStateOperations().map(\.id)), Set(try mac.allStateOperations().map(\.id)))
        XCTAssertEqual(try phone.canonicalStateDigest(), try mac.canonicalStateDigest())
        XCTAssertEqual(phone.sharedUserRecords.first(where: { $0.id == confirmation.id })?.status, "pending")
        XCTAssertEqual(mac.sharedUserRecords.first(where: { $0.id == confirmation.id })?.status, "pending")
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-session-projection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("river-node.sqlite")
    }

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw SQLiteTestError(message: "SQLite open failed: \(openStatus)")
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        let message = errorMessage.map { String(cString: $0) } ?? ""
        sqlite3_free(errorMessage)
        guard status == SQLITE_OK else { throw SQLiteTestError(message: message) }
    }

    private func integerValue(_ sql: String, at url: URL) throws -> Int {
        guard let value = try queryValue(sql, at: url) else { throw SQLiteTestError(message: "No integer result") }
        return value
    }

    private func strings(_ sql: String, at url: URL) throws -> [String] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw SQLiteTestError(message: "SQLite open failed: \(openStatus)")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { result.append(String(cString: text)) }
        }
        return result
    }

    private func queryValue(_ sql: String, at url: URL) throws -> Int? {
        var database: OpaquePointer?
        let openStatus = sqlite3_open(url.path, &database)
        guard openStatus == SQLITE_OK, let database else {
            throw SQLiteTestError(message: "SQLite open failed: \(openStatus)")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private struct RiverIOSSemanticTimelineFixture: Encodable {
    struct Segment: Encodable {
        let candidateIDs: [String]
        let title: String
        let summary: String
        let evidenceRefs: [String]
        let start: Date
        let end: Date
    }

    let dayKey: String
    let segments: [Segment]
}

private final class MockRiverAIURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var bodies: [Data] = []
    private static let responseBody = Data(#"{"choices":[{"message":{"content":"只基于手写记录生成的本地回顾。"}}]}"#.utf8)

    static var capturedRequestBodies: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    static func reset() {
        lock.lock()
        bodies = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "localhost"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var requestBody = request.httpBody
        if requestBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4_096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            requestBody = body.isEmpty ? nil : body
        }
        Self.lock.lock()
        Self.bodies.append(requestBody ?? Data())
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private struct SQLiteTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private enum RiverLocalDatabasePayloadFixtures {
    static let app = RiverEventPayload(appName: "Safari", bundleID: "com.apple.mobilesafari")
    static let macApp = RiverEventPayload(appName: "Xcode", bundleID: "com.apple.dt.Xcode")
}
