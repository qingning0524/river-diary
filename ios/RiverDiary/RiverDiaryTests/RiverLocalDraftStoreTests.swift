import XCTest
@testable import RiverDiary

@MainActor final class RiverLocalDraftStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    func testDraftsRestoreAcrossInstancesAndRemainSeparatedByDayAndKind() throws {
        let directory = try directory(), store = RiverLocalDraftStore(directory: directory)
        store.update("journal one", for: "2026-10-03", kind: .journal, moodScore: 75, ratingEnabled: true)
        store.update("question one", for: "2026-10-03", kind: .question)
        store.update("another day", for: "2026-10-02", kind: .journal)
        store.flush()
        let restored = RiverLocalDraftStore(directory: directory)
        XCTAssertEqual(restored.text(for: "2026-10-03", kind: .journal), "journal one")
        XCTAssertEqual(restored.rating(for: "2026-10-03")?.score, 75)
        XCTAssertEqual(restored.rating(for: "2026-10-03")?.enabled, true)
        XCTAssertEqual(restored.text(for: "2026-10-03", kind: .question), "question one")
        XCTAssertEqual(restored.text(for: "2026-10-02", kind: .journal), "another day")
        XCTAssertNil(restored.text(for: "2026-10-01", kind: .journal))
    }
    func testClearingSavedDraftCancelsPendingWriteWithoutRemovingOtherDrafts() throws {
        let directory = try directory(), store = RiverLocalDraftStore(directory: directory)
        store.update("keep", for: "2026-10-02", kind: .journal);store.flush()
        store.update("not yet written", for: "2026-10-03", kind: .journal)
        store.remove(for: "2026-10-03", kind: .journal);store.flush()
        let restored = RiverLocalDraftStore(directory: directory)
        XCTAssertNil(restored.text(for: "2026-10-03", kind: .journal))
        XCTAssertEqual(restored.text(for: "2026-10-02", kind: .journal), "keep")
    }
    func testWriteFailureKeepsPendingTextAndInvalidKeysCannotEscapeTheDirectory() throws {
        let root = try directory();try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("file");try Data("block".utf8).write(to: file)
        let store = RiverLocalDraftStore(directory: file)
        store.update("recover me", for: "2026-10-03", kind: .journal);store.flush()
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(store.text(for: "2026-10-03", kind: .journal), "recover me")
        store.update("invalid", for: "../../outside", kind: .journal)
        XCTAssertNil(store.text(for: "../../outside", kind: .journal))
    }
}
