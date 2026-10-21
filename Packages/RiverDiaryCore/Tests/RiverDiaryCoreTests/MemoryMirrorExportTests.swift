import Foundation
import XCTest
@testable import RiverDiaryCore

final class MemoryMirrorExportTests: XCTestCase {
    func testLegacyDiaryBecomesStableMirror() throws {
        let source = """
        {
          "generated": "2026-10-20 21:30",
          "today": "2026-10-20",
          "poem": "",
          "entries": [
            {
              "page_id": "2026-10-20",
              "date": "2026-10-20",
              "title": "窗边的十分钟",
              "overview": "上午把桌面清理出一块空白。",
              "thoughts": ["烧水时没有急着打开电脑。"],
              "did": [{"sub": "工作", "items": ["整理桌面", "写完一页"]}],
              "tags": ["早晨", "工作"],
              "mood": "平静"
            }
          ]
        }
        """.data(using: .utf8)!

        let archive = try MemoryMirrorArchive.legacy(fromDiaryJSON: source, personaName: "林岸")
        XCTAssertEqual(archive.format, "river.memory-mirror")
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(archive.persona?.name, "林岸")
        XCTAssertEqual(archive.entries.count, 1)
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertEqual(entry.id, "2026-10-20")
        XCTAssertEqual(entry.occurredAt, "2026-10-20T12:00:00")
        XCTAssertEqual(entry.title, "窗边的十分钟")
        XCTAssertTrue(entry.body.contains("烧水"))
        XCTAssertTrue(entry.body.contains("桌面"))
        XCTAssertEqual(entry.facts, ["整理桌面", "写完一页"])
        XCTAssertEqual(entry.tags, ["早晨", "工作"])
        XCTAssertEqual(entry.mood, "平静")
        XCTAssertEqual(entry.source.type, "user")
        XCTAssertFalse(entry.favorite)
    }

    func testMirrorKeepsFactsAndSkipsInvalidEntries() throws {
        let source = """
        {"entries": [
          {"date": "不是日期", "body": "x"},
          {"page_id": "a", "date": "2026-02-02", "title": "可以读", "thoughts": ["一句"]}
        ]}
        """.data(using: .utf8)!
        let archive = try MemoryMirrorArchive.legacy(fromDiaryJSON: source)
        XCTAssertEqual(archive.entries.count, 1)
        XCTAssertEqual(archive.entries[0].title, "可以读")
    }

    func testEmptyOrInvalidDiaryDoesNotInventData() throws {
        XCTAssertThrowsError(try MemoryMirrorArchive.legacy(fromDiaryJSON: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? MemoryMirrorExportError, .invalidDiary)
        }
        XCTAssertThrowsError(try MemoryMirrorArchive.legacy(fromDiaryJSON: Data("{\"entries\":[]}".utf8))) { error in
            XCTAssertEqual(error as? MemoryMirrorExportError, .emptyDiary)
        }
    }

    func testEncodedMirrorUsesWebKeys() throws {
        let source = """
        {"entries": [{"date": "2026-02-02", "title": "标题", "thoughts": ["正文"], "did": [{"items": ["事实"]}]}]}
        """.data(using: .utf8)!
        let data = try MemoryMirrorArchive.legacy(fromDiaryJSON: source).encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"format\" : \"river.memory-mirror\""))
        XCTAssertTrue(text.contains("\"occurred_at\""))
        XCTAssertTrue(text.contains("\"collection_ids\""))
        XCTAssertTrue(text.contains("\"source\""))
    }
}
