import Foundation
import SQLite3

enum ChromeHistoryReader {
    private static let chromeEpochOffset: Double = 11644473600 // seconds between 1601-01-01 and 1970-01-01

    static func readTodaysVisits() -> [ChromeVisit] {
        let historyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History")

        guard FileManager.default.fileExists(atPath: historyPath.path) else { return [] }

        // Chrome locks the original file; copy to temp before reading.
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chrome-history-\(UUID().uuidString).db")

        do {
            try FileManager.default.copyItem(at: historyPath, to: tempURL)
        } catch {
            return []
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let chromeTimeStart = Int64((startOfToday.timeIntervalSince1970 + chromeEpochOffset) * 1_000_000)

        let query = """
            SELECT urls.url, urls.title, visits.visit_time, visits.visit_count
            FROM visits
            JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time >= \(chromeTimeStart)
              AND urls.url LIKE 'http%'
              AND urls.url NOT LIKE 'chrome://%'
              AND urls.url NOT LIKE 'about:%'
            ORDER BY visits.visit_time DESC
            LIMIT 1000
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var visits: [ChromeVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let chromeTime = sqlite3_column_double(statement, 2)
            let count = Int(sqlite3_column_int64(statement, 3))

            guard !url.isEmpty else { continue }

            let unixTime = chromeTime / 1_000_000 - chromeEpochOffset
            let visitedAt = Date(timeIntervalSince1970: unixTime)

            visits.append(ChromeVisit(
                url: url,
                title: title,
                visitedAt: visitedAt,
                visitCount: count,
                domain: extractDomain(from: url)
            ))
        }

        return visits
    }

    static func extractDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        return host
            .replacingOccurrences(of: "www.", with: "")
            .lowercased()
    }

    static func topDomains(from visits: [ChromeVisit], limit: Int = 5) -> [String] {
        var counts: [String: Int] = [:]
        for visit in visits {
            guard !visit.domain.isEmpty else { continue }
            counts[visit.domain, default: 0] += visit.visitCount
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
