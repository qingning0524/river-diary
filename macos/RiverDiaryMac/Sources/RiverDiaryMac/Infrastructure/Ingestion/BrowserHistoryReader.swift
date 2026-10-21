import Foundation
import SQLCipher

struct BrowserHistoryReadResult: Equatable {
    var visits: [ChromeVisit]
    var issue: String?
}

/// 读取今天的浏览器历史。支持 Safari 与 Chromium 系（Chrome/Arc/Edge/Brave）的多配置。
///
/// 关键取舍：
/// - 只读今天的 `http(s)` 访问，标题保留但最多 1000 条；
/// - 原库可能被浏览器锁住，先复制到临时目录再读；
/// - 文件不存在是“没装/没用”，打开失败才是“读不到”，两者不能都显示成 0。
enum BrowserHistoryReader {
    private static let chromiumEpochOffset: Double = 11_644_473_600
    private static let maximumVisits = 1000

    struct ChromiumSource {
        var browser: String
        var root: URL
    }

    static func readTodaysVisits(now: Date = Date()) -> BrowserHistoryReadResult {
        let fileManager = FileManager.default
        var visits: [ChromeVisit] = []
        var attempted = 0
        var failed = 0

        for source in chromiumSources() {
            let paths = chromiumHistoryPaths(root: source.root)
            guard !paths.isEmpty else { continue }
            for historyPath in paths {
                attempted += 1
                if let found = readChromiumVisits(historyPath: historyPath, browser: source.browser, now: now) {
                    visits.append(contentsOf: found)
                } else {
                    failed += 1
                }
            }
        }

        let safari = safariHistoryPath()
        if fileManager.fileExists(atPath: safari.path) {
            attempted += 1
            if let found = readSafariVisits(historyPath: safari, now: now) {
                visits.append(contentsOf: found)
            } else {
                failed += 1
            }
        }

        let issue: String?
        if failed == 0 {
            issue = nil
        } else if failed == attempted {
            issue = "浏览器历史无法读取；请授予完全磁盘访问后重试。"
        } else {
            issue = "\(failed) 个浏览器配置无法读取（可能需要完全磁盘访问）。"
        }

        return BrowserHistoryReadResult(visits: dedupe(visits), issue: issue)
    }

    static func chromiumSources() -> [ChromiumSource] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            ChromiumSource(browser: "Chrome", root: base.appendingPathComponent("Google/Chrome")),
            ChromiumSource(browser: "Arc", root: base.appendingPathComponent("Arc/User Data")),
            ChromiumSource(browser: "Edge", root: base.appendingPathComponent("Microsoft Edge")),
            ChromiumSource(browser: "Brave", root: base.appendingPathComponent("BraveSoftware/Brave-Browser"))
        ]
    }

    static func chromiumHistoryPaths(root: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { url in
                let name = url.lastPathComponent
                guard name == "Default" || name.hasPrefix("Profile ") else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { $0.appendingPathComponent("History") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    static func safariHistoryPath() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Safari/History.db")
    }

    /// Chromium 的 `visits.visit_time` 是 1601-01-01 起的微秒。
    static func readChromiumVisits(
        historyPath: URL,
        browser: String,
        now: Date = Date()
    ) -> [ChromeVisit]? {
        guard let temp = copyForRead(historyPath) else { return nil }
        defer { removeCopy(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let startOfToday = Calendar.current.startOfDay(for: now)
        let chromeTimeStart = Int64((startOfToday.timeIntervalSince1970 + chromiumEpochOffset) * 1_000_000)
        let query = """
            SELECT urls.url, urls.title, visits.visit_time, 1
            FROM visits
            JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time >= \(chromeTimeStart)
              AND urls.url LIKE 'http%'
              AND urls.url NOT LIKE 'chrome://%'
              AND urls.url NOT LIKE 'about:%'
            ORDER BY visits.visit_time DESC
            LIMIT \(maximumVisits)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        var visits: [ChromeVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            guard !url.isEmpty else { continue }
            let chromeTime = sqlite3_column_double(statement, 2)
            let visitedAt = Date(timeIntervalSince1970: chromeTime / 1_000_000 - chromiumEpochOffset)
            visits.append(ChromeVisit(
                url: url,
                title: title,
                visitedAt: visitedAt,
                visitCount: Int(sqlite3_column_int64(statement, 3)),
                domain: extractDomain(from: url),
                browser: browser
            ))
        }
        return visits
    }

    /// Safari 的 `visit_time` 是 2001-01-01 起的秒；新版本把标题放在
    /// `history_visits.title`，旧版本没有这一列，需要退回空标题。
    static func readSafariVisits(
        historyPath: URL,
        now: Date = Date()
    ) -> [ChromeVisit]? {
        guard let temp = copyForRead(historyPath) else { return nil }
        defer { removeCopy(temp) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        let startOfToday = Calendar.current.startOfDay(for: now)
        let safariTimeStart = startOfToday.timeIntervalSinceReferenceDate
        func query(titleExpression: String) -> String {
            """
            SELECT items.url, \(titleExpression), visits.visit_time, 1
            FROM history_visits visits
            JOIN history_items items ON items.id = visits.history_item
            WHERE visits.visit_time >= \(safariTimeStart)
              AND items.url LIKE 'http%'
            ORDER BY visits.visit_time DESC
            LIMIT \(maximumVisits)
            """
        }
        let queries = [query(titleExpression: "visits.title"), query(titleExpression: "''")]

        for query in queries {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                continue
            }
            defer { sqlite3_finalize(statement) }

            var visits: [ChromeVisit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let url = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
                let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
                guard !url.isEmpty else { continue }
                let visitTime = sqlite3_column_double(statement, 2)
                visits.append(ChromeVisit(
                    url: url,
                    title: title,
                    visitedAt: Date(timeIntervalSinceReferenceDate: visitTime),
                    visitCount: Int(sqlite3_column_int64(statement, 3)),
                    domain: extractDomain(from: url),
                    browser: "Safari"
                ))
            }
            return visits
        }
        return nil
    }

    static func dedupe(_ visits: [ChromeVisit]) -> [ChromeVisit] {
        var seen = Set<String>()
        var result: [ChromeVisit] = []
        for visit in visits.sorted(by: { $0.visitedAt > $1.visitedAt }) {
            let key = "\(visit.url)|\(Int(visit.visitedAt.timeIntervalSince1970))"
            guard seen.insert(key).inserted else { continue }
            result.append(visit)
            if result.count >= maximumVisits { break }
        }
        return result
    }

    static func extractDomain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return "" }
        var lowered = host.lowercased()
        for prefix in ["www.", "www2.", "www3."] where lowered.hasPrefix(prefix) {
            lowered.removeFirst(prefix.count)
            break
        }
        return lowered
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

    // MARK: - File copy

    private static func copyForRead(_ source: URL) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("river-browser-\(UUID().uuidString).db")
        do {
            try fileManager.copyItem(at: source, to: temp)
            for suffix in ["-wal", "-shm"] {
                let sidecar = URL(fileURLWithPath: source.path + suffix)
                if fileManager.fileExists(atPath: sidecar.path) {
                    try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: temp.path + suffix))
                }
            }
            return temp
        } catch {
            return nil
        }
    }

    private static func removeCopy(_ temp: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: temp)
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(at: URL(fileURLWithPath: temp.path + suffix))
        }
    }
}
