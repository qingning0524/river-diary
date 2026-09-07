import Foundation
import SQLite3

enum AppleNotesReader {
    static func readTodaysNotes() -> [DailyNoteEntry] {
        let notesPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")

        guard FileManager.default.fileExists(atPath: notesPath.path) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(notesPath.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        // Core Data timestamps are seconds since 2001-01-01
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfTodayCoreData = startOfToday.timeIntervalSince(Date(timeIntervalSinceReferenceDate: 0))

        let query = """
            SELECT ZTITLE1, ZMODIFICATIONDATE1
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE ZTITLE1 IS NOT NULL
              AND ZTITLE1 != ''
              AND (ZMARKEDFORDELETION IS NULL OR ZMARKEDFORDELETION != 1)
              AND ZMODIFICATIONDATE1 >= \(startOfTodayCoreData)
            ORDER BY ZMODIFICATIONDATE1 DESC
            LIMIT 50
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var entries: [DailyNoteEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let title = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let modDate = sqlite3_column_double(statement, 1)

            guard !title.isEmpty else { continue }

            entries.append(DailyNoteEntry(
                title: title,
                modifiedAt: Date(timeIntervalSinceReferenceDate: modDate)
            ))
        }

        return entries
    }
}
