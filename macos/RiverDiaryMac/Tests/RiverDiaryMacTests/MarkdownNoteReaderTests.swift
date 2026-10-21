import Foundation
import XCTest

@testable import RiverDiaryMac

final class MarkdownNoteReaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-markdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    func testParseUsesFrontMatterTitleAndStripsIt() throws {
        let text = """
        ---
        title: 周末计划
        tags: [life]
        ---
        # 周末
        去河边走走。
        """
        let result = try XCTUnwrap(MarkdownNoteReader.parse(text: text, fileName: "2026-10-21.md"))
        XCTAssertEqual(result.title, "周末计划")
        XCTAssertEqual(result.body, "去河边走走。")
    }

    func testParseUsesFirstHeadingAndBody() throws {
        let result = try XCTUnwrap(MarkdownNoteReader.parse(
            text: "# 今天的记录\n把数据源整理完。\n\n明天继续。",
            fileName: "note.md"
        ))
        XCTAssertEqual(result.title, "今天的记录")
        XCTAssertEqual(result.body, "把数据源整理完。\n\n明天继续。")
    }

    func testParseFallsBackToFileName() throws {
        let result = try XCTUnwrap(MarkdownNoteReader.parse(text: "没有标题的正文。", fileName: "随手记.md"))
        XCTAssertEqual(result.title, "随手记")
        XCTAssertEqual(result.body, "没有标题的正文。")
    }

    func testReadTodayIncludesOnlyTodayAndSkipsHiddenDirectories() throws {
        let now = Date()
        try write("今天.md", text: "# 今天\n今天的正文", modified: now)
        try write("昨天.md", text: "# 昨天\n昨天的正文", modified: now.addingTimeInterval(-2 * 86_400))

        let hidden = directory.appendingPathComponent(".obsidian", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try write(".obsidian/配置.md", text: "不应被读取", modified: now)

        let result = MarkdownNoteReader.readToday(folder: directory, now: now)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.title, "今天")
        XCTAssertEqual(result.entries.first?.source, "Markdown")
    }

    func testReadTodayReportsMissingFolder() {
        let missing = directory.appendingPathComponent("missing", isDirectory: true)
        let result = MarkdownNoteReader.readToday(folder: missing)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.issue)
    }

    private func write(_ relativePath: String, text: String, modified: Date) throws {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
}
