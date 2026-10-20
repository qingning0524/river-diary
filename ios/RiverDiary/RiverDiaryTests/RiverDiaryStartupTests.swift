import XCTest
@testable import RiverDiary

@MainActor
final class RiverDiaryStartupTests: XCTestCase {
    func testFreshInstallDoesNotRequireAPersonalArchive() {
        let store = DiaryStore(snapshotURL: nil)
        XCTAssertNotNil(store.data)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.loadError)
    }

    func testCorruptedArchiveIsReportedInsteadOfPresentedAsEmptySuccess() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("corrupted".utf8).write(to: url)
        let store = DiaryStore(snapshotURL: url)
        XCTAssertNotNil(store.loadError)
        XCTAssertNil(store.data)
    }
}
