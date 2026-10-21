import Foundation
import Testing
@testable import RiverDiaryCore

struct DayContextSnapshotTests {
    private var snapshot: DayContextSnapshot {
        DayContextSnapshot(
            deviceID: "device-a",
            deviceName: "Mac",
            day: "2026-10-21",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sections: [
                DayContextSection(
                    kind: "notes",
                    title: "备忘录",
                    summary: "1 条",
                    items: [DayContextItem(title: "窗边", detail: "去河边走走。", count: nil, at: nil)]
                )
            ]
        )
    }

    @Test func roundTripsISO8601JSON() throws {
        let json = try snapshot.encodedJSON()
        let decoded = try #require(DayContextSnapshot.decodeJSON(json))
        #expect(decoded == snapshot)
        #expect(decoded.searchText.contains("窗边"))
    }

    @Test func mirrorEntryKeepsContextReadableAndStable() throws {
        let archive = MemoryMirrorArchive(exportedAt: "2026-10-21T12:00:00Z", entries: [])
            .appendingContexts([snapshot])
        #expect(archive.version == 2)
        #expect(archive.contexts == [snapshot])
        let entry = MemoryMirrorArchive.contextEntry(from: snapshot)
        #expect(entry.kind == "context")
        #expect(entry.source.type == "context")
        #expect(entry.title == "Mac 的一天")
        #expect(entry.body.contains("备忘录：1 条"))
        #expect(entry.id == "context-device-a-2026-10-21")
    }
}
