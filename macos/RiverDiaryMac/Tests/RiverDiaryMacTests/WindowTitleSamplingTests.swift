import XCTest

@testable import RiverDiaryMac

/// 窗口标题的重采样规则。
///
/// 背景：实测本机 2297 条片段里只有 1 条带标题。原因不是"没授权"这一条——
/// 标题只在应用切换的那一瞬间读一次，那一刻目标应用往往还没有窗口。于是每一段
/// 都永远没有标题，而"缺少窗口标题"正是待确认队列的判据之一：判据退化成恒真。
///
/// 所以这里量的是三件事：**读不到时不许擦掉已有的标题**、**没标题时补上**、
/// **标题真的换了要切开而不是盖掉**，以及抖动不许把一段阅读切成渣。
final class WindowTitleSamplingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ offset: TimeInterval) -> Date {
        start.addingTimeInterval(offset)
    }

    private func decide(
        current: String?,
        pending: WindowTitleSampling.Pending? = nil,
        sampled: String?,
        offset: TimeInterval
    ) -> WindowTitleSampling.Decision {
        WindowTitleSampling.decide(
            currentTitle: current,
            pending: pending,
            sampled: sampled,
            now: at(offset)
        )
    }

    // MARK: 读不到

    func testAFailedReadNeverErasesAKnownTitle() {
        for sampled in [nil, "", "   ", "\u{00A0}"] {
            let decision = decide(current: "设计文档 - Notion", sampled: sampled, offset: 0)
            XCTAssertEqual(decision.action, .ignore, "读失败把标题擦掉了：\(sampled ?? "nil")")
            XCTAssertNil(decision.pending)
        }
    }

    func testAOneCharacterTitleIsNotEvidence() {
        XCTAssertNil(WindowTitleSampling.normalize("·"))
        XCTAssertNil(WindowTitleSampling.normalize(" "))
        XCTAssertEqual(WindowTitleSampling.normalize("  设计文档  "), "设计文档")
    }

    // MARK: 补上

    func testASessionWithNoTitleAdoptsTheFirstReading() {
        // 切换的那一刻读不到（应用还在启动），25 秒后读到了。
        let decision = decide(current: nil, sampled: "收件箱 - Gmail", offset: 25)
        XCTAssertEqual(decision.action, .adopt("收件箱 - Gmail"))
        XCTAssertNil(decision.pending)
    }

    func testAnEmptyTitleCountsAsMissing() {
        XCTAssertEqual(decide(current: "  ", sampled: "GitHub", offset: 0).action, .adopt("GitHub"))
    }

    // MARK: 切开

    func testAStableNewTitleSplitsAtTheFirstSighting() {
        // 12:00:00 读到新标题；12:00:25 还是它；12:01:00 确认。
        let first = decide(current: "文档", sampled: "视频", offset: 0)
        XCTAssertEqual(first.action, .ignore, "第一次看到新标题不该立刻切开")
        let pending = try? XCTUnwrap(first.pending)

        let same = decide(current: "文档", pending: pending, sampled: "视频", offset: 25)
        XCTAssertEqual(same.action, .ignore, "两次采样之间还不到确认间隔")
        XCTAssertEqual(same.pending, pending)

        let confirmed = decide(current: "文档", pending: pending, sampled: "视频", offset: 60)
        // 切点是**第一次看到**它的时刻，不是确认的时刻：标题什么时候换的我们不知道，
        // 但不会晚于第一次读到的瞬间。
        XCTAssertEqual(confirmed.action, .split(at: at(0), title: "视频"))
        XCTAssertNil(confirmed.pending)
    }

    func testAFlickeringTitleDoesNotSplitTheSession() {
        // 一条通知让标题闪了一下，下一次采样就回来了。
        let first = decide(current: "文档", sampled: "(3) Slack", offset: 0)
        XCTAssertEqual(first.action, .ignore)
        let back = decide(current: "文档", pending: first.pending, sampled: "文档", offset: 25)
        XCTAssertEqual(back.action, .ignore)
        XCTAssertNil(back.pending, "回到原样之后不该留着疑似标题")
    }

    func testTwoDifferentNewTitlesInARowDoNotSplit() {
        // 每次采样都不一样（页面里在加载的东西一直在改标题）：永远不确认。
        var pending: WindowTitleSampling.Pending?
        var offset: TimeInterval = 0
        for title in ["A 加载中", "B 加载中", "C 加载中", "D 加载中"] {
            let decision = decide(current: "文档", pending: pending, sampled: title, offset: offset)
            XCTAssertEqual(decision.action, .ignore, "「\(title)」不该单独构成一次切换")
            pending = decision.pending
            offset += 25
        }
        XCTAssertEqual(pending?.title, "D 加载中")
    }

    /// 未读数会不停变：「(3) Slack」→「(4) Slack」。归一化之后它们是同一个标题。
    func testAnUnreadBadgeCountIsNotATitleChange() {
        XCTAssertEqual(WindowTitleSampling.normalize("(3) Slack"), "Slack")
        XCTAssertEqual(WindowTitleSampling.normalize("(12)Slack"), "Slack")
        XCTAssertEqual(decide(current: "(3) Slack", sampled: "(4) Slack", offset: 0).action, .ignore)
        // 括号里不是数字的是标题本身，不能剥掉。
        XCTAssertEqual(WindowTitleSampling.normalize("(草稿) 周报"), "(草稿) 周报")
        // 长得像计数的三位以上也可能真的是标题：(2024) 年度总结。
        XCTAssertEqual(WindowTitleSampling.normalize("(2024) 年度总结"), "(2024) 年度总结")
    }

    func testWhitespaceOnlyDifferencesAreNotATitleChange() {
        XCTAssertEqual(decide(current: "设计文档", sampled: "  设计文档  ", offset: 0).action, .ignore)
    }

    // MARK: 切分本身

    func testSplitClampsTheBoundaryIntoTheSession() {
        var session = ActivitySession(
            appName: "Chrome", bundleID: "test.Chrome", windowTitle: "文档",
            category: "浏览", start: at(0), end: at(600)
        )
        session.windowTitle = "文档"

        // 时钟回拨：切点落在这一段开始之前。
        let early = session.split(at: at(-3600), now: at(600), windowTitle: "视频")
        XCTAssertEqual(early.closed.end, session.start, "越界的切点削出了负长度的一段")
        XCTAssertEqual(early.closed.duration, 0)
        XCTAssertEqual(early.next.start, session.start)

        // 切点在这段之后（同步一次读到很晚的时刻）。
        let late = session.split(at: at(7200), now: at(600), windowTitle: "视频")
        XCTAssertEqual(late.closed.end, at(600))
        XCTAssertEqual(late.next.start, at(600))
        XCTAssertEqual(late.next.duration, 0)

        // 正常切点：两段首尾相接，时间没有丢也没有重叠。
        let normal = session.split(at: at(200), now: at(600), windowTitle: "视频")
        XCTAssertEqual(normal.closed.start, at(0))
        XCTAssertEqual(normal.closed.end, at(200))
        XCTAssertEqual(normal.next.start, at(200))
        XCTAssertEqual(normal.next.end, at(600))
        XCTAssertEqual(normal.closed.duration + normal.next.duration, session.duration)
    }

    func testSplitGivesTheNewSegmentItsOwnIdentityAndCategory() {
        let session = ActivitySession(
            appName: "Chrome", bundleID: "test.Chrome", windowTitle: "季度报表 - 表格",
            category: ActivityClassifier.category(appName: "Chrome", title: "季度报表 - 表格"),
            start: at(0), end: at(600)
        )
        let (closed, next) = session.split(at: at(200), now: at(600), windowTitle: "搞笑视频 - YouTube")

        XCTAssertNotEqual(closed.id, next.id, "两段共用一个 id 会被当成同一条记录")
        XCTAssertEqual(closed.windowTitle, "季度报表 - 表格", "旧段的标题不该被新标题盖掉")
        XCTAssertEqual(next.windowTitle, "搞笑视频 - YouTube")
        XCTAssertEqual(next.category, ActivityClassifier.category(appName: "Chrome", title: "搞笑视频 - YouTube"))
        XCTAssertNotEqual(next.category, closed.category, "换了标题之后类别没有重算")
    }
}
