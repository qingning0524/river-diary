#if DEBUG
import Darwin
import Foundation
import RiverDiaryCore

/// 仅 Debug：用两个独立进程/独立 CFFIXED_USER_HOME/独立 Keychain 命名空间
/// 验证“源 Mac 导出可移植备份 -> 目标 Mac 用恢复码恢复”。
/// 这不是用户功能，只用于 D0 恢复演练和 CI 证据。
@MainActor
enum MacPortableDrill {
    static func runIfRequested() -> Int32? {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["RIVER_PORTABLE_DRILL"] else { return nil }
        guard let path = env["RIVER_PORTABLE_DRILL_PATH"], !path.isEmpty,
              let code = env["RIVER_PORTABLE_DRILL_KEY"], !code.isEmpty else {
            fputs("DRILL_FAIL missing RIVER_PORTABLE_DRILL_PATH/KEY\n", stderr)
            return 2
        }
        do {
            let key = try SyncEncryptionKey(importCode: code)
            switch mode {
            case "export": return try export(path: path, key: key)
            case "import": return try restore(path: path, key: key)
            default:
                fputs("DRILL_FAIL unknown mode \(mode)\n", stderr)
                return 2
            }
        } catch {
            fputs("DRILL_FAIL \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func export(path: String, key: SyncEncryptionKey) throws -> Int32 {
        let diary = DiaryStore()
        let legacy = AppDatabase()
        let v2 = V2Store()
        defer { legacy.close(); v2.close() }
        let day = DiaryEntry.dateFormatter.date(from: "2026-10-22")!
        try diary.saveWriting(entry: diary.entry(for: day), text: "DRILL-EXPORT-2026-10-22", mood: 7)
        _ = diary.addQuickCapture("DRILL-QUICK-CAPTURE", for: day)
        guard legacy.saveAIResult(
            resultKey: "drill",
            startDate: "2026-10-22",
            endDate: "2026-10-22",
            task: "query",
            model: "drill",
            answer: "DRILL-LEGACY-ANSWER",
            sourceSummary: "drill"
        ) else { throw NSError(domain: "drill", code: 10) }
        let event = RawEvent(
            timestamp: day,
            source: .location,
            kind: .locationUpdate,
            payload: RawEventPayload(locationName: "DRILL-V2-PLACE")
        )
        guard v2.insertRawEvent(event) else { throw NSError(domain: "drill", code: 11) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let portable = try PortableBackupArchive.seal(
            journal: try encoder.encode(try diary.makeBackupPayload()),
            legacyDatabasePlaintext: try legacy.plaintextSnapshot(),
            v2DatabasePlaintext: try v2.plaintextSnapshot(),
            using: key
        )
        try portable.write(to: URL(fileURLWithPath: path), options: .atomic)
        print("DRILL_EXPORT_OK path=\(path) bytes=\(portable.count)")
        return 0
    }

    private static func restore(path: String, key: SyncEncryptionKey) throws -> Int32 {
        let diary = DiaryStore()
        let legacy = AppDatabase()
        let v2 = V2Store()
        defer { legacy.close(); v2.close() }
        let payload = try PortableBackupArchive.open(try Data(contentsOf: URL(fileURLWithPath: path)), using: key)
        guard let legacyPlain = payload.legacyDatabasePlaintext,
              let v2Plain = payload.v2DatabasePlaintext else {
            throw NSError(domain: "drill", code: 12)
        }
        try legacy.validatePlaintextSnapshot(legacyPlain)
        try v2.validatePlaintextSnapshot(v2Plain)
        let legacyBefore = try legacy.encryptedSnapshot()
        let v2Before = try v2.encryptedSnapshot()
        let localBackup = try PortableBackupArchive.localBackupData(
            from: payload,
            legacyDatabaseSnapshot: try legacy.encryptedSnapshot(fromPlaintext: legacyPlain),
            v2DatabaseSnapshot: try v2.encryptedSnapshot(fromPlaintext: v2Plain)
        )
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-portable-drill-\(UUID().uuidString).riverbackup")
        defer { try? FileManager.default.removeItem(at: temp) }
        try localBackup.write(to: temp, options: .atomic)
        try diary.restoreFullBackup(
            from: temp,
            validateDatabaseSnapshots: { legacySnapshot, v2Snapshot in
                guard let legacySnapshot, let v2Snapshot else { throw NSError(domain: "drill", code: 13) }
                try legacy.validateEncryptedSnapshot(legacySnapshot)
                try v2.validateEncryptedSnapshot(v2Snapshot)
            },
            restoreDatabaseSnapshots: { legacySnapshot, v2Snapshot in
                guard let legacySnapshot, let v2Snapshot else { throw NSError(domain: "drill", code: 14) }
                try legacy.restoreEncryptedSnapshot(legacySnapshot)
                try v2.restoreEncryptedSnapshot(v2Snapshot)
            },
            rollbackExternalData: {
                try legacy.restoreEncryptedSnapshot(legacyBefore)
                try v2.restoreEncryptedSnapshot(v2Before)
            },
            recoverySnapshot: RestoreRecoverySnapshot(
                legacyDatabaseSnapshot: legacyBefore,
                v2DatabaseSnapshot: v2Before
            )
        )
        let day = DiaryEntry.dateFormatter.date(from: "2026-10-22")!
        let text = diary.overview(for: diary.entry(for: day))
        let answer = legacy.queryAIResults(startDate: "2026-10-22", endDate: "2026-10-22").first?.answer
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let place = v2.rawEvents(between: day, end: nextDay).first { $0.payload.locationName == "DRILL-V2-PLACE" }?.payload.locationName
        guard text == "DRILL-EXPORT-2026-10-22",
              answer == "DRILL-LEGACY-ANSWER",
              place == "DRILL-V2-PLACE" else {
            throw NSError(domain: "drill", code: 15, userInfo: [NSLocalizedDescriptionKey: "restored data mismatch text=\(text) answer=\(answer ?? "nil")"])
        }
        print("DRILL_IMPORT_OK text=\(text) legacy=\(answer ?? "nil") place=\(place ?? "nil")")
        return 0
    }
}
#endif
