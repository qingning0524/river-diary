import Foundation
import SQLCipher

/// 一次读取的结果。`issue` 只在“确实读不到”时非空：
/// 没有笔记、没有今天的修改都不是错误，不能把它们显示成权限失败。
struct AppleNotesReadResult: Equatable {
    var entries: [DailyNoteEntry]
    var issue: String?
}

enum AppleNotesReader {
    static func readTodaysNotes() -> AppleNotesReadResult {
        let notesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

        guard FileManager.default.fileExists(atPath: notesPath.path) else {
            return AppleNotesReadResult(entries: [], issue: nil)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(notesPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return AppleNotesReadResult(
                entries: [],
                issue: "无法打开备忘录数据库；请在系统设置中授予完全磁盘访问后重试。"
            )
        }
        defer { sqlite3_close(db) }

        // Core Data timestamps are seconds since 2001-01-01
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTodayCoreData = startOfToday.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))

        // ZICNOTEDATA.ZDATA 是 gzip 包裹的 protobuf；没有数据的行（例如尚未下载的
        // 云笔记、受锁保护的笔记）直接跳过，不能当成“正文为空”。
        let query = """
            SELECT o.Z_PK, o.ZTITLE1, o.ZMODIFICATIONDATE1, d.ZDATA
            FROM ZICCLOUDSYNCINGOBJECT o
            JOIN ZICNOTEDATA d ON d.ZNOTE = o.Z_PK
            WHERE o.ZTITLE1 IS NOT NULL
              AND o.ZTITLE1 != ''
              AND (o.ZMARKEDFORDELETION IS NULL OR o.ZMARKEDFORDELETION != 1)
              AND o.ZMODIFICATIONDATE1 >= \(startOfTodayCoreData)
              AND d.ZDATA IS NOT NULL
            ORDER BY o.ZMODIFICATIONDATE1 DESC
            LIMIT 50
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return AppleNotesReadResult(entries: [], issue: "备忘录数据库结构无法识别。")
        }
        defer { sqlite3_finalize(statement) }

        var entries: [DailyNoteEntry] = []
        var seenNoteIDs = Set<Int64>()
        var unreadable = 0

        while sqlite3_step(statement) == SQLITE_ROW {
            let noteID = sqlite3_column_int64(statement, 0)
            guard !seenNoteIDs.contains(noteID) else { continue }
            seenNoteIDs.insert(noteID)

            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let modifiedAt = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            guard !title.isEmpty else { continue }

            guard let blob = sqlite3_column_blob(statement, 3) else {
                unreadable += 1
                continue
            }
            let byteCount = Int(sqlite3_column_bytes(statement, 3))
            let compressed = Data(bytes: blob, count: byteCount)
            guard let body = AppleNotesPayload.extractBody(from: compressed, title: title) else {
                unreadable += 1
                continue
            }

            entries.append(DailyNoteEntry(title: title, body: body, source: "备忘录", modifiedAt: modifiedAt))
        }

        return AppleNotesReadResult(
            entries: entries,
            issue: unreadable > 0 ? "\(unreadable) 条备忘录正文无法解析。" : nil
        )
    }
}
