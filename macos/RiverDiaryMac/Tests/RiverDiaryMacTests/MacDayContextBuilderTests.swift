import Foundation
import XCTest

@testable import RiverDiaryMac

final class MacDayContextBuilderTests: XCTestCase {
    func testBuildsReadableSectionsFromMacSources() throws {
        let note = DailyNoteEntry(
            title: "窗边",
            body: "去河边走走。",
            source: "备忘录",
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let visit = ChromeVisit(
            url: "https://example.com/a",
            title: "一篇文章",
            visitedAt: Date(timeIntervalSince1970: 1_800_000_000),
            visitCount: 1,
            domain: "example.com",
            browser: "Safari"
        )
        let context = MacDayContextBuilder.build(
            day: "2026-10-21",
            deviceID: "device-a",
            deviceName: "Mac",
            browser: BrowserHistoryReadResult(visits: [visit], issue: nil),
            notes: [note],
            markdown: [],
            kindle: [],
            calendar: nil,
            weather: nil,
            git: GitActivityReadResult(repos: [GitRepoSummary(name: "river", path: "/tmp/river", commits: 3)], issue: nil),
            screen: ScreenTimeSnapshot(totalMinutes: 120, topApps: ["Xcode"], focusMinutes: 60, focusBlocks: 1)
        )

        let built = try XCTUnwrap(context)
        XCTAssertEqual(built.deviceName, "Mac")
        XCTAssertEqual(built.sections.map(\.kind), ["browser", "notes", "git", "focus", "screenTime"])
        XCTAssertTrue(built.summaryLine.contains("1 次访问"))
        XCTAssertTrue(built.sections.first { $0.kind == "notes" }?.items.first?.detail?.contains("去河边走走") == true)
    }

    func testEmptySourcesProduceNoSnapshot() {
        let context = MacDayContextBuilder.build(
            day: "2026-10-21",
            deviceID: "device-a",
            deviceName: "Mac",
            browser: nil,
            notes: [],
            markdown: [],
            kindle: [],
            calendar: nil,
            weather: nil,
            git: nil,
            screen: nil
        )
        XCTAssertNil(context)
    }

    func testFullBodiesOnlyWhenExplicitlyShared() throws {
        let body = String(repeating: "河", count: 400)
        let note = DailyNoteEntry(title: "长笔记", body: body, source: "备忘录", modifiedAt: Date())
        let visit = ChromeVisit(
            url: "https://example.com/full",
            title: "全文",
            visitedAt: Date(),
            visitCount: 1,
            domain: "example.com",
            browser: "Safari"
        )

        let summary = try XCTUnwrap(MacDayContextBuilder.build(
            day: "2026-10-21", deviceID: "device-a", deviceName: "Mac",
            browser: BrowserHistoryReadResult(visits: [visit], issue: nil),
            notes: [note], markdown: [], kindle: [], calendar: nil, weather: nil,
            git: nil, screen: nil
        ))
        let summaryNote = try XCTUnwrap(summary.sections.first { $0.kind == "notes" }?.items.first)
        XCTAssertEqual(summaryNote.detail?.count, 160)

        let full = try XCTUnwrap(MacDayContextBuilder.build(
            day: "2026-10-21", deviceID: "device-a", deviceName: "Mac",
            browser: BrowserHistoryReadResult(visits: [visit], issue: nil),
            notes: [note], markdown: [], kindle: [], calendar: nil, weather: nil,
            git: nil, screen: nil,
            shareBrowserURLs: true, shareNoteBodies: true
        ))
        let fullNote = try XCTUnwrap(full.sections.first { $0.kind == "notes" }?.items.first)
        let fullBrowser = try XCTUnwrap(full.sections.first { $0.kind == "browser" }?.items.first)
        XCTAssertEqual(fullNote.detail, body)
        XCTAssertEqual(fullBrowser.detail, "https://example.com/full")
    }
}
