import XCTest
@testable import RiverDiaryMac

// MARK: - 全量审计修复的回归测试
//
// 每个用例对应审计报告中的一项 P1/P2 修复；文件按修复批次组织。

@MainActor
final class AuditFixRegressionTests: XCTestCase {
    private func makeV2() throws -> V2Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return V2Store(databaseURL: directory.appendingPathComponent("audit.db"))
    }

    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal
    }()

    private func session(_ bundleID: String, _ appName: String, _ day: Date, hour: Int, minutes: Int) -> ActivitySession {
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: calendar.startOfDay(for: day))!
        return ActivitySession(
            appName: appName,
            bundleID: bundleID,
            windowTitle: nil,
            category: ActivityClassifier.category(appName: appName, title: nil),
            start: start,
            end: start.addingTimeInterval(TimeInterval(minutes * 60))
        )
    }

    private func makeCard(bundleID: String, days: [Date]) -> HabitReviewCard {
        let examples = days.map { dayDate in
            HabitExample(
                dayKey: HabitCandidateEngine.dayKey(for: dayDate),
                dateText: HabitCandidateEngine.shortDateText(dayDate),
                duration: 5_400,
                placeSummary: "位置暂不确定",
                appName: "Codex",
                sourceKey: HabitCandidateEngine.exampleKey(bundleID: bundleID, dayKey: HabitCandidateEngine.dayKey(for: dayDate))
            )
        }
        return HabitReviewCard(
            dedupKey: HabitCandidateEngine.dedupKey(bundleID: bundleID),
            question: "通常算作工作吗？",
            lead: "三个不同日期的记录很相似。",
            examples: examples,
            evidence: [],
            proposedCategory: "工作",
            appName: "Codex",
            bundleID: bundleID,
            placeKey: nil
        )
    }

    // MARK: P1-1 upsert 原子性（事务化）

    func testUpsertAnalysisRunKeepsSingleRowPerKey() throws {
        let v2 = try makeV2()
        let key = "dailyOverview|d-2026-09-20"
        for version in 1...5 {
            XCTAssertTrue(v2.upsertAnalysisRun(
                AnalysisRun(task: .dailyOverview, outputText: "v\(version)"),
                dedupKey: key, rangeKey: "d-2026-09-20", evidenceRefs: ["diary:2026-09-20"]
            ))
        }
        XCTAssertEqual(v2.countRows(in: .analysisRuns), 1, "重复 upsert 不得留下同键多行")
        XCTAssertEqual(v2.latestAnalysisRun(dedupKey: key)?.run.outputText, "v5")
    }

    func testSetMemoryConfirmationKeepsLayersConsistent() throws {
        let v2 = try makeV2()
        let memory = Memory(title: "长期项目", body: "河流日记", kind: .projectTrajectory)
        XCTAssertTrue(v2.insertMemory(memory))
        XCTAssertTrue(v2.setMemoryConfirmation(memory.id, confirmed: true))
        XCTAssertEqual(v2.memories().first?.isUserConfirmed, true)
        XCTAssertEqual(v2.memoryConfirmation(for: memory.id)?.confirmed, true)
        XCTAssertTrue(v2.setMemoryConfirmation(memory.id, confirmed: false))
        XCTAssertEqual(v2.memories().first?.isUserConfirmed, false)
    }

    // MARK: P1-6 CJK 邻接的引用提取

    func testEvidenceExtractionFindsCJKAdjacentReferences() {
        let answer = "完成了写作任务，依据raw:11111111-1111-1111-1111-111111111111。详见diary:2026-09-20，另见 capture:22222222-2222-2222-2222-222222222222。"
        let refs = EvidenceReference.extract(from: answer)
        XCTAssertEqual(refs.count, 3, "中文紧邻的引用必须能提取")
        XCTAssertTrue(refs.contains("raw:11111111-1111-1111-1111-111111111111"))
        XCTAssertTrue(refs.contains("diary:2026-09-20"))

        // 尾部负向断言：36 位之后还有十六进制字符说明不是合法 UUID 引用。
        XCTAssertTrue(EvidenceReference.extract(from: "依据raw:11111111-1111-1111-1111-111111111111abc").isEmpty)
    }

    // MARK: P1-4 习惯例子排除

    func testOnlyTheseExamplesExcludesMarkedDaysFromNewCandidates() throws {
        let now = Date()
        // 6 个独立日，全部 ≥ 阈值；前 3 个（-1,-2,-4）会被"只确认这 3 次"标记。
        let allDays = [-1, -2, -4, -5, -7, -8].map {
            calendar.startOfDay(for: now).addingTimeInterval(TimeInterval($0 * 86_400))
        }
        let sessions = allDays.map { session("com.openai.codex", "Codex", $0, hour: 10, minutes: 90) }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        XCTAssertEqual(candidates.first?.days.count, 6)

        var answered = makeCard(bundleID: "com.openai.codex", days: Array(allDays.prefix(3)))
        answered.status = .answered
        answered.answerKind = .onlyTheseExamples
        answered.answeredAt = now.addingTimeInterval(-20 * 86_400) // 14 天冷却已过
        answered.markedExampleKeys = allDays.prefix(3).map {
            HabitCandidateEngine.exampleKey(bundleID: "com.openai.codex", dayKey: HabitCandidateEngine.dayKey(for: $0))
        }

        let worthwhile = HabitCandidateEngine.worthwhileCandidates(
            from: candidates, rules: [], cards: [answered], now: now, calendar: calendar
        )
        guard let candidate = worthwhile.first else {
            return XCTFail("仍有 3 个未标记的新日子，应产生新候选")
        }
        let newDayKeys = Set(candidate.days.map(\.dayKey))
        XCTAssertEqual(newDayKeys, Set(allDays.suffix(3).map { HabitCandidateEngine.dayKey(for: $0) }),
                       "新候选只包含未确认的日子")
        let card = HabitCandidateEngine.makePatternCard(candidate: candidate, now: now, calendar: calendar)
        let exampleKeys = Set(card.examples.map(\.sourceKey))
        for marked in answered.markedExampleKeys {
            XCTAssertFalse(exampleKeys.contains(marked), "已确认过的例子不得再次出现在新卡上")
        }
    }

    // MARK: P2-习惯：地点缺失时不重复出卡

    func testMissingPlaceDataDoesNotReaskPlaceScopedRule() throws {
        let now = Date()
        let days = [-2, -4, -6].map { calendar.startOfDay(for: now).addingTimeInterval(TimeInterval($0 * 86_400)) }
        let sessions = days.map { session("com.openai.codex", "Codex", $0, hour: 10, minutes: 60) }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        let rule = HabitPersonalRule(
            dedupKey: "pattern:com.openai.codex",
            conditionBundleID: "com.openai.codex",
            conditionAppName: "Codex",
            conditionPlaceKey: "宿舍",
            conclusionCategory: "工作",
            scopeText: "Codex · 宿舍附近",
            status: .active, origin: .userConfirmed, recordedAt: now, validFrom: now
        )
        let worthwhile = HabitCandidateEngine.worthwhileCandidates(
            from: candidates, rules: [rule], cards: [], now: now, calendar: calendar
        )
        XCTAssertTrue(worthwhile.isEmpty, "位置数据暂时缺失时，地点级规则应视为覆盖，不得降级出第二条规则")
    }

    // MARK: P1-7 TimelineSegment 空洞

    func testLateNightSegmentDoesNotAbsorbDaytimeSessions() throws {
        let day = calendar.startOfDay(for: Date())
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let daytime = ActivitySession(
            appName: "Codex", bundleID: "com.openai.codex", windowTitle: nil, category: "工作",
            start: at(12, 0), end: at(13, 0)
        )
        let lateEvening = ActivitySession(
            appName: "Chrome", bundleID: "com.google.Chrome", windowTitle: nil, category: "浏览",
            start: at(23, 10), end: at(23, 40)
        )

        let segments = TimelineSegmentEngine.segments(for: day, sessions: [daytime, lateEvening])
        let lateNight = try XCTUnwrap(segments.first { $0.period == .lateNight })
        XCTAssertEqual(lateNight.totalDuration, 30 * 60, "深夜段只含 23:10–23:40，不得吞并白天会话")
        XCTAssertEqual(lateNight.sessions.map(\.appName), ["Chrome"])

        let afternoon = try XCTUnwrap(segments.first { $0.period == .afternoon })
        XCTAssertEqual(afternoon.totalDuration, 60 * 60)
        XCTAssertEqual(afternoon.sessions.map(\.appName), ["Codex"])

        // 空段不得认领快记；有活动的段只认领落在自己匹配窗口内的快记。
        let capture = QuickCapture(text: "随手一记", createdAt: at(12, 30))
        let withCapture = TimelineSegmentEngine.segments(for: day, sessions: [daytime], quickCaptures: [capture])
        let emptyLateNight = try XCTUnwrap(withCapture.first { $0.period == .lateNight })
        XCTAssertTrue(emptyLateNight.captures.isEmpty, "没有活动匹配的深夜段不得认领全天快记")
        let afternoonWithCapture = try XCTUnwrap(withCapture.first { $0.period == .afternoon })
        XCTAssertEqual(afternoonWithCapture.captures.map(\.text), ["随手一记"])
    }

    // MARK: P2-活动：sessions(from:to:) 裁剪

    func testSessionsRangeQueryClipsBoundarySessions() throws {
        let activityDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-audit-activity-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: activityDirectory)
        defer { try? FileManager.default.removeItem(at: activityDirectory) }
        let store = ActivityStore(
            activityDirectory: activityDirectory,
            userDefaults: UserDefaults(suiteName: "audit-\(UUID().uuidString)")!,
            v2Store: try makeV2()
        )
        let day = calendar.startOfDay(for: Date())
        let realStart = calendar.date(bySettingHour: 9, minute: 30, second: 0, of: day)!
        let realEnd = calendar.date(bySettingHour: 10, minute: 20, second: 0, of: day)!
        store.injectSessionsForAudit([
            ActivitySession(
                appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: nil, category: "工作",
                start: realStart, end: realEnd
            )
        ])
        // 会话 09:30–10:20；窗口 [10:00, 12:00] 必须返回裁剪后的 10:00–10:20。
        let windowStart = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)!
        let windowEnd = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let result = store.sessions(from: windowStart, to: windowEnd)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, windowStart)
        XCTAssertEqual(result[0].end, calendar.date(bySettingHour: 10, minute: 20, second: 0, of: day)!)
    }

    // MARK: P2-习惯：位置事件精度过滤

    func testInvalidAccuracyLocationSamplesAreIgnored() throws {
        let v2 = try makeV2()
        let now = Date()
        let days = [-2, -4, -6].map { calendar.startOfDay(for: now).addingTimeInterval(TimeInterval($0 * 86_400)) }
        for day in days {
            // 无效精度（-1）与超距精度（900m）不得成为地点证据；每天只有一条有效"宿舍"。
            XCTAssertTrue(v2.insertRawEvent(RawEvent(
                timestamp: day.addingTimeInterval(9 * 3_600), source: .location, kind: .locationUpdate,
                payload: RawEventPayload(latitude: 30, longitude: 120, horizontalAccuracy: -1, locationName: "公司")
            )))
            XCTAssertTrue(v2.insertRawEvent(RawEvent(
                timestamp: day.addingTimeInterval(10 * 3_600), source: .location, kind: .locationUpdate,
                payload: RawEventPayload(latitude: 30, longitude: 120, horizontalAccuracy: 900, locationName: "公司")
            )))
            XCTAssertTrue(v2.insertRawEvent(RawEvent(
                timestamp: day.addingTimeInterval(11 * 3_600), source: .location, kind: .locationUpdate,
                payload: RawEventPayload(latitude: 30, longitude: 120, horizontalAccuracy: 15, locationName: "宿舍")
            )))
        }
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        store.setCadence(.manual)
        let sessions = days.map { session("com.openai.codex", "Codex", $0, hour: 10, minutes: 84) }
        XCTAssertTrue(store.generateBatchIfValuable(sessions: sessions, now: now))
        let card = try XCTUnwrap(store.pendingCards.first)
        XCTAssertEqual(card.placeKey, "宿舍", "无效样本被过滤后，有效样本才是当日地点")
        XCTAssertTrue(card.question.contains("宿舍"))
    }

    // MARK: P2-采集：记忆候选解析失败可区分

    func testMemoryCandidateParserDistinguishesGarbageFromEmpty() {
        XCTAssertFalse(MemoryCandidateParser.containsJSONPayload("模型输出完全坏掉"))
        XCTAssertTrue(MemoryCandidateParser.containsJSONPayload("{\"candidates\":[]}"), "确认没有候选也是有效载荷")
        XCTAssertNil(MemoryCandidateParser.parsePayload("坏输出", allowedRefs: []))
        XCTAssertEqual(MemoryCandidateParser.parse(
            "{\"candidates\":[{\"title\":\"长期项目\",\"body\":\"持续开发河流日记\",\"kind\":\"projectTrajectory\",\"evidence\":[]}]}",
            allowedRefs: []
        ).count, 1)
    }

    // MARK: P2-AI：validFrom 未来的规则不进 prompt

    func testFutureValidFromRuleIsExcludedFromContext() throws {
        let v2 = try makeV2()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let future = HabitPersonalRule(
            dedupKey: "pattern:x", conditionBundleID: "com.x", conditionAppName: "X",
            conditionPlaceKey: nil, conclusionCategory: "工作", scopeText: "X",
            status: .active, origin: .userConfirmed,
            recordedAt: Date(), validFrom: Date().addingTimeInterval(7 * 86_400)
        )
        XCTAssertTrue(v2.upsertHabitRule(id: future.id, status: future.status.rawValue, payloadJSON: String(data: try encoder.encode(future), encoding: .utf8)!, updatedAt: Date()))
        XCTAssertTrue(ContextAssembler.activeRules(v2Store: v2).isEmpty, "尚未生效的规则不属于有效期")
    }

    // MARK: P2-AI：周报 30 天档

    func testWeeklyAnalysisScalesWithRequestedRange() {
        let days = AIAssistantStore.daysBetween("2026-09-01", "2026-09-30")
        XCTAssertEqual(days.count, 30)
        XCTAssertEqual(days.first, "2026-09-01")
        XCTAssertEqual(days.last, "2026-09-30")
        XCTAssertTrue(AIAssistantStore.daysBetween("2026-09-05", "2026-09-01").isEmpty, "起止颠倒返回空")
    }

    // MARK: P2-习惯：everyThreeDays 负模 + digest 多行 JSON

    func testEveryThreeDaysBlockMathIsMonotonic() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        let before = cal.date(from: DateComponents(year: 2025, month: 12, day: 28, hour: 12))!
        let period = HabitReviewCadence.everyThreeDays.currentPeriod(
            now: before, time: .evening, calendar: cal
        )
        let blockStart = cal.startOfDay(for: period.dueDate)
        // 锚点 2026-01-01 向前的三天块：…、12/20、12/23、12/26（覆盖 26/27/28）。
        XCTAssertEqual(HabitReviewCadence.dayStamp(blockStart, calendar: cal), "2025-12-26",
                       "锚点之前的日期也要落在正确的三天块里（floorMod 语义）")
    }

    func testDigestParserHandlesMultilineJSON() {
        let answer = """
        **结论**
        今天完成了引擎整理。

        <!-- digest: {
          "headline": "9/20 全天开发",
          "points": ["上午写引擎", "晚上测试"]
        } -->
        """
        let (digest, clean) = AnalysisDigestParser.extract(from: answer)
        XCTAssertEqual(digest.headline, "9/20 全天开发")
        XCTAssertEqual(digest.points, ["上午写引擎", "晚上测试"])
        XCTAssertFalse(clean.contains("digest:"), "多行摘要注释同样要从可见正文剥除")
    }

    // MARK: P2-视图：复盘范围切换（丢弃临时答案，保留归档结果）

    func testDiscardTransientAnswerKeepsArchivedResult() throws {
        let v2 = try makeV2()
        let store = AIAssistantStore(v2Store: v2)
        store.seedTransientAnswerForAudit(.analysisWeekly, answer: "旧范围的临时答案")
        store.discardTransientAnswer(for: .analysisWeekly)
        XCTAssertNil(store.state(for: .analysisWeekly), "未归档的旧范围答案应被丢弃")

        let dayKey = "2026-09-20"
        XCTAssertTrue(v2.upsertAnalysisRun(
            AnalysisRun(task: .dailyOverview, outputText: "已归档日报"),
            dedupKey: "dailyOverview|\(ContextAssembler.dayRangeKey(dayKey))",
            rangeKey: ContextAssembler.dayRangeKey(dayKey), evidenceRefs: []
        ))
        store.restoreAnalysisResults(startDate: dayKey, endDate: dayKey)
        store.discardTransientAnswer(for: .analysisDaily)
        XCTAssertEqual(store.state(for: .analysisDaily)?.answer, "已归档日报", "已归档结果由恢复路径管理，不得丢弃")
    }

    // MARK: P2-活动：融合引擎小时对齐

    func testHourlyTimelineDoesNotLeakSecondsAcrossHours() {
        let day = calendar.startOfDay(for: Date())
        let start = calendar.date(bySettingHour: 9, minute: 30, second: 37, of: day)!
        let end = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: day)!
        let sessions = [ActivitySession(
            appName: "Xcode", bundleID: "com.apple.dt.Xcode", windowTitle: nil, category: "工作",
            start: start, end: end
        )]
        let hours = ActivityFusionEngine.dayStats(
            dateKey: HabitCandidateEngine.dayKey(for: day),
            entry: nil,
            liveSessions: sessions
        ).timeline
        let hour9 = hours.first { $0.hour == 9 }
        let hour10 = hours.first { $0.hour == 10 }
        XCTAssertEqual(hour9?.duration ?? 0, 29 * 60 + 23, accuracy: 2, "9 点段应到 10:00:00 为止")
        XCTAssertEqual(hour10?.duration ?? 0, 60 * 60, accuracy: 2, "10 点段是完整的 60 分钟")
    }
}
