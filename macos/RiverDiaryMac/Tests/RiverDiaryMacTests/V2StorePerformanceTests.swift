import XCTest
import RiverDiaryCore
import SQLCipher
@testable import RiverDiaryMac

@MainActor
final class V2StorePerformanceTests: XCTestCase {
    private func makeStore() throws -> V2Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-v2-performance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return V2Store(databaseURL: directory.appendingPathComponent("facts.db"))
    }

    private func drafts(_ count: Int) -> [V2Store.StateOperationDraft] {
        (0..<count).map { index in
            V2Store.StateOperationDraft(
                id: UUID(), targetID: "record-\(index)", fieldKey: "record",
                operationType: "test.record", payload: Data("value-\(index)".utf8)
            )
        }
    }

    func testAppendingAndRetryingBatchDoesNotScanOperationHistory() throws {
        let store = try makeStore()
        XCTAssertEqual(store.appendStateOperationsAtomically(drafts(256))?.count, 256)
        let database = try XCTUnwrap(store.db)
        let trace = StateOperationScanTrace()
        trace.install(on: database)
        defer { trace.uninstall(from: database) }

        let input = drafts(32)
        let appended = try XCTUnwrap(store.appendStateOperationsAtomically(input))
        let frontier = try store.currentInputFrontier()
        XCTAssertEqual(store.appendStateOperationsAtomically(input), appended)
        XCTAssertEqual(try store.currentInputFrontier(), frontier)
        XCTAssertEqual(trace.fullScanSteps, 0,
                          "Duplicate checks must not reread the entire operation history for every draft.")
        trace.uninstall(from: database)
        XCTAssertEqual(store.countRows(in: .stateOperations), 288)
    }

    func testImportingAndRetryingBatchDoesNotScanOperationHistory() throws {
        let store = try makeStore()
        XCTAssertEqual(store.appendStateOperationsAtomically(drafts(256))?.count, 256)
        let device = RiverDeviceID(rawValue: "remote-operation-performance")
        let operations = try makeOperations(device: device, count: 32)
        let batch = try StateOperationBatch(deviceID: device, operations: operations)
        let database = try XCTUnwrap(store.db)
        let trace = StateOperationScanTrace()
        trace.install(on: database)
        defer { trace.uninstall(from: database) }

        XCTAssertTrue(store.importStateOperationBatch(batch, objectID: "transport-one", ciphertextHash: "one"))
        XCTAssertTrue(store.importStateOperationBatch(batch, objectID: "transport-two", ciphertextHash: "two"))
        XCTAssertEqual(store.importedOperationFrontier(for: device), 32)
        XCTAssertEqual(trace.fullScanSteps, 0)
        trace.uninstall(from: database)
        XCTAssertEqual(store.allStateOperations().filter { $0.actorDeviceID == device }, operations)
    }

    func testImportIdentityConflictRollsBackEarlierOperationsAndFrontier() throws {
        let store = try makeStore()
        let device = RiverDeviceID(rawValue: "remote-operation-conflict")
        let original = try makeOperations(device: device, count: 1)[0]
        let firstBatch = try StateOperationBatch(deviceID: device, operations: [original])
        XCTAssertTrue(store.importStateOperationBatch(firstBatch, objectID: "original", ciphertextHash: "one"))
        let before = store.allStateOperations()
        let frontier = store.importedOperationFrontier(for: device)
        let fresh = try makeOperations(device: device, count: 1, firstSequence: 2)[0]
        let conflict = StateOperation(
            id: original.id, actorDeviceID: device, originSequence: 3, clock: original.clock,
            causalFrontier: original.causalFrontier, targetID: original.targetID,
            fieldKey: original.fieldKey, operationType: original.operationType, payload: original.payload
        )
        let invalidBatch = try StateOperationBatch(deviceID: device, operations: [fresh, conflict])

        XCTAssertFalse(store.importStateOperationBatch(invalidBatch, objectID: "conflict", ciphertextHash: "two"))
        XCTAssertEqual(store.allStateOperations(), before)
        XCTAssertEqual(store.importedOperationFrontier(for: device), frontier)
        XCTAssertEqual(store.countRows(in: .syncImports), 1)
    }

    func testEpisodeLookupDeduplicatesAndChunksAtDatabaseParameterLimit() throws {
        let store = try makeStore()
        let episodes = (0..<24).map { index in
            Episode(startTime: Date(timeIntervalSince1970: Double(index)),
                    endTime: Date(timeIntervalSince1970: Double(index + 1)), title: "episode-\(index)")
        }
        for episode in episodes { XCTAssertTrue(store.insertEpisode(episode)) }
        let database = try XCTUnwrap(store.db)
        let originalLimit = sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, 8)
        defer { sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, originalLimit) }
        let ids = episodes.reversed().flatMap { [$0.id, $0.id] } + [UUID()]

        XCTAssertEqual(store.episodes(ids: ids).map(\.id), episodes.map(\.id))
        XCTAssertEqual(store.episodes(ids: []), [])
    }

    private func makeOperations(device: RiverDeviceID, count: Int, firstSequence: UInt64 = 1) throws -> [StateOperation] {
        let frontier = try InputFrontier()
        return (0..<count).map { index in
            let sequence = firstSequence + UInt64(index)
            return StateOperation(
                actorDeviceID: device, originSequence: sequence,
                clock: HybridLogicalClock(physicalMilliseconds: sequence, deviceID: device),
                causalFrontier: frontier, targetID: "remote-\(sequence)", fieldKey: "record",
                operationType: "test.record", payload: Data("value-\(sequence)".utf8)
            )
        }
    }

    func testMemoryConfirmationLookupChunksWithoutLosingDecisionsOrNotes() throws {
        let store = try makeStore()
        let ids = (0..<24).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            XCTAssertTrue(store.setMemoryConfirmation(id, confirmed: index.isMultiple(of: 2), note: "note-\(index)"))
        }
        let database = try XCTUnwrap(store.db)
        let originalLimit = sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, 8)
        defer { sqlite3_limit(database, SQLITE_LIMIT_VARIABLE_NUMBER, originalLimit) }

        let confirmations = store.memoryConfirmations(ids: ids + ids + [UUID()])

        XCTAssertEqual(confirmations.count, ids.count)
        for (index, id) in ids.enumerated() {
            XCTAssertEqual(confirmations[id]?.confirmed, index.isMultiple(of: 2))
            XCTAssertEqual(confirmations[id]?.note, "note-\(index)")
        }
        XCTAssertTrue(store.memoryConfirmations(ids: []).isEmpty)
    }
}

/// Records SQLite's actual table scan work, independent of wall-clock timing.
private final class StateOperationScanTrace {
    var fullScanSteps = 0

    func install(on database: OpaquePointer) {
        sqlite3_trace_v2(database, UInt32(SQLITE_TRACE_PROFILE), { _, context, rawStatement, _ in
            guard let context, let rawStatement else { return 0 }
            let statement = OpaquePointer(rawStatement)
            guard let sql = sqlite3_sql(statement), String(cString: sql).contains("FROM state_operations") else { return 0 }
            let trace = Unmanaged<StateOperationScanTrace>.fromOpaque(context).takeUnretainedValue()
            trace.fullScanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            return 0
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func uninstall(from database: OpaquePointer) {
        sqlite3_trace_v2(database, 0, nil, nil)
    }
}
