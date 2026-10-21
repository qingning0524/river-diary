import Foundation
import SQLCipher
import XCTest

@testable import RiverDiaryMac

final class BrowserHistoryReaderTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testSafariReadsOnlyTodaysHTTPVisits() throws {
        let url = try makeDatabase()
        try execute(url, """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT);
            CREATE TABLE history_visits (history_item INTEGER, visit_time REAL, title TEXT);
            """)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Calendar.current.startOfDay(for: now)
        try insertSafariVisit(
            db: url,
            itemID: 1,
            url: "https://example.com/article",
            title: "Example",
            visitTime: start.addingTimeInterval(3_600)
        )
        try insertSafariVisit(
            db: url,
            itemID: 2,
            url: "https://old.example.com/",
            title: "Old",
            visitTime: start.addingTimeInterval(-86_400)
        )

        let visits = try XCTUnwrap(BrowserHistoryReader.readSafariVisits(historyPath: url, now: now))
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.browser, "Safari")
        XCTAssertEqual(visits.first?.domain, "example.com")
        XCTAssertEqual(visits.first?.title, "Example")
    }

    func testChromiumReadsTodaysVisitsAndBrowserName() throws {
        let url = try makeDatabase()
        try execute(url, """
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE visits (url INTEGER, visit_time REAL);
            """)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = Calendar.current.startOfDay(for: now)
        let offset: Double = 11_644_473_600
        try insertChromiumVisit(
            db: url,
            url: "https://www.swift.org/",
            title: "Swift",
            visitTime: (start.addingTimeInterval(600).timeIntervalSince1970 + offset) * 1_000_000
        )

        let visits = try XCTUnwrap(BrowserHistoryReader.readChromiumVisits(
            historyPath: url, browser: "Arc", now: now
        ))
        XCTAssertEqual(visits.count, 1)
        XCTAssertEqual(visits.first?.browser, "Arc")
        XCTAssertEqual(visits.first?.domain, "swift.org")
    }

    func testMissingPathIsUnreadableNotEmpty() {
        XCTAssertNil(BrowserHistoryReader.readSafariVisits(
            historyPath: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).db")
        ))
    }

    func testDedupeKeepsNewestVisitPerURLAndSecond() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = [
            ChromeVisit(url: "https://a.com", title: "A", visitedAt: now, visitCount: 1, domain: "a.com", browser: "Chrome"),
            ChromeVisit(url: "https://a.com", title: "A", visitedAt: now, visitCount: 1, domain: "a.com", browser: "Safari"),
            ChromeVisit(url: "https://b.com", title: "B", visitedAt: now.addingTimeInterval(-1), visitCount: 1, domain: "b.com", browser: "Safari")
        ]
        let deduped = BrowserHistoryReader.dedupe(visits)
        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped.first?.url, "https://a.com")
        XCTAssertEqual(Set(deduped.map(\.url)), ["https://a.com", "https://b.com"])
    }

    func testTopDomainsCountsVisits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let visits = [
            ChromeVisit(url: "https://a.com/1", title: "", visitedAt: now, visitCount: 2, domain: "a.com"),
            ChromeVisit(url: "https://a.com/2", title: "", visitedAt: now, visitCount: 3, domain: "a.com"),
            ChromeVisit(url: "https://b.com/", title: "", visitedAt: now, visitCount: 1, domain: "b.com")
        ]
        XCTAssertEqual(BrowserHistoryReader.topDomains(from: visits), ["a.com", "b.com"])
    }

    // MARK: - Fixture

    private func makeDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-browser-test-\(UUID().uuidString).db")
        temporaryFiles.append(url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("Could not create fixture database")
        }
        sqlite3_close(db)
        return url
    }

    private func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("Could not open fixture database")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            XCTFail("Fixture schema failed")
            return
        }
    }

    private func insertSafariVisit(
        db url: URL,
        itemID: Int,
        url pageURL: String,
        title: String,
        visitTime: Date
    ) throws {
        try insert(db: url, sql: "INSERT INTO history_items (id, url) VALUES (?,?)") { statement in
            sqlite3_bind_int(statement, 1, Int32(itemID))
            sqlite3_bind_text(statement, 2, pageURL, -1, self.SQLiteTransient)
        }
        try insert(db: url, sql: "INSERT INTO history_visits (history_item, visit_time, title) VALUES (?,?,?)") { statement in
            sqlite3_bind_int(statement, 1, Int32(itemID))
            sqlite3_bind_double(statement, 2, visitTime.timeIntervalSinceReferenceDate)
            sqlite3_bind_text(statement, 3, title, -1, self.SQLiteTransient)
        }
    }

    private func insertChromiumVisit(
        db url: URL,
        url pageURL: String,
        title: String,
        visitTime: Double
    ) throws {
        try insert(db: url, sql: "INSERT INTO urls (id, url, title) VALUES (1,?,?)") { statement in
            sqlite3_bind_text(statement, 1, pageURL, -1, self.SQLiteTransient)
            sqlite3_bind_text(statement, 2, title, -1, self.SQLiteTransient)
        }
        try insert(db: url, sql: "INSERT INTO visits (url, visit_time) VALUES (1,?)") { statement in
            sqlite3_bind_double(statement, 1, visitTime)
        }
    }

    private func insert(db url: URL, sql: String, bindings: (OpaquePointer) -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw XCTSkip("Could not open fixture database")
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            XCTFail("Fixture insert prepare failed")
            return
        }
        defer { sqlite3_finalize(statement) }
        bindings(statement!)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            XCTFail("Fixture insert failed")
            return
        }
    }

    private var SQLiteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
