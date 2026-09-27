import XCTest
@testable import RiverDiaryMac

@MainActor
final class HabitReviewTests: XCTestCase {
    // MARK: Fixtures

    private func makeStore() throws -> V2Store {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-habit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return V2Store(databaseURL: directory.appendingPathComponent("habit.db"))
    }

    /// 构造某 bundle 在指定日期的一段前台活动。
    private func session(
        _ bundleID: String,
        appName: String,
        day: Date,
        startHour: Int,
        durationMinutes: Int,
        calendar: Calendar
    ) -> ActivitySession {
        let dayStart = calendar.startOfDay(for: day)
        let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: dayStart) ?? dayStart
        return ActivitySession(
            appName: appName,
            bundleID: bundleID,
            windowTitle: nil,
            category: ActivityClassifier.category(appName: appName, title: nil),
            start: start,
            end: start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        )
    }

    private let calendar: Calendar = {
        // 固定周起点（周日），避免依赖测试机的地区设置。
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        return cal
    }()

    /// 一个"过去"的基准时刻：今天往后推 2 天，避免跨入今天（引擎只看完整日）。
    private var referenceNow: Date {
        let todayStart = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -2, to: todayStart)!.addingTimeInterval(21 * 3_600)
    }

    private func day(offsetFromNow: Int, of now: Date) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: offsetFromNow, to: start)!
    }

    // MARK: 候选生成

    func testCandidatesRequireThreeIndependentDays() throws {
        let now = referenceNow
        let codexDays = [-2, -4, -6, -8].map { day(offsetFromNow: $0, of: now) }
        var sessions: [ActivitySession] = []
        for (index, dayDate) in codexDays.enumerated() {
            sessions.append(session(
                "com.openai.codex",
                appName: "Codex",
                day: dayDate,
                startHour: 10 + index,
                durationMinutes: index == 0 ? 84 : 58,
                calendar: calendar
            ))
        }
        // 只有两天记录的另一个应用，不应成为候选。
        sessions.append(session("com.apple.finder", appName: "访达", day: codexDays[0], startHour: 15, durationMinutes: 40, calendar: calendar))
        sessions.append(session("com.apple.finder", appName: "访达", day: codexDays[1], startHour: 15, durationMinutes: 40, calendar: calendar))

        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.bundleID, "com.openai.codex")
        XCTAssertEqual(candidates.first?.days.count, 4)
        // 单日不足阈值的片段不算有效样本。
        let shortDay = candidates.first!.days.first!.duration
        XCTAssertGreaterThanOrEqual(shortDay, 20 * 60)
    }

    func testOneDayWithFragmentedSessionsCountsAsOneSample() throws {
        let now = referenceNow
        let dayDate = day(offsetFromNow: -1, of: now)
        let sessions = [
            session("com.openai.codex", appName: "Codex", day: dayDate, startHour: 9, durationMinutes: 15, calendar: calendar),
            session("com.openai.codex", appName: "Codex", day: dayDate, startHour: 12, durationMinutes: 30, calendar: calendar),
            session("com.openai.codex", appName: "Codex", day: dayDate, startHour: 18, durationMinutes: 10, calendar: calendar),
        ]
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        // 同一天被切成 3 段：一天仍然只算一个样本，且总量不足阈值时不产出候选。
        XCTAssertTrue(candidates.isEmpty)
    }

    func testConsistentPlaceNameSurvivesOnlyWhenAllDaysNamed() throws {
        let now = referenceNow
        let days = [-2, -4, -6].map { day(offsetFromNow: $0, of: now) }
        let sessions = days.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 60, calendar: calendar)
        }
        let allKeys = days.map { HabitCandidateEngine.dayKey(for: $0) }

        var partialNames = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "宿舍") })
        partialNames[allKeys[2]] = nil
        let named = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: partialNames, now: now, calendar: calendar)
        XCTAssertEqual(named.first?.consistentPlaceName, nil, "只有部分天有可靠地点时，不能当作一致地点")

        let fullNames = Dictionary(uniqueKeysWithValues: allKeys.map { ($0, "宿舍") })
        let allNamed = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: fullNames, now: now, calendar: calendar)
        XCTAssertEqual(allNamed.first?.consistentPlaceName, "宿舍")
    }

    func testWorthwhileFiltersActiveRuleAndCooling() throws {
        let now = referenceNow
        let days = [-2, -4, -6].map { day(offsetFromNow: $0, of: now) }
        let sessions = days.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 60, calendar: calendar)
        }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        XCTAssertEqual(candidates.count, 1)

        // 1) 活跃规则覆盖：不再询问。
        let rule = HabitPersonalRule(
            dedupKey: HabitCandidateEngine.dedupKey(bundleID: "com.openai.codex"),
            conditionBundleID: "com.openai.codex",
            conditionAppName: "Codex",
            conditionPlaceKey: nil,
            conclusionCategory: "工作",
            scopeText: "Codex"
        )
        let afterRule = HabitCandidateEngine.worthwhileCandidates(
            from: candidates, rules: [rule], cards: [], now: now, calendar: calendar
        )
        XCTAssertTrue(afterRule.isEmpty)

        // 2) 跳过后冷却期内不问，冷却期满重新出现。
        var skippedCard = try makeCard(bundleID: "com.openai.codex", days: days, calendar: calendar)
        skippedCard.status = .skipped
        skippedCard.answerKind = .skip
        skippedCard.answeredAt = calendar.date(byAdding: .day, value: -3, to: now)
        let inCooling = HabitCandidateEngine.worthwhileCandidates(
            from: candidates, rules: [], cards: [skippedCard], now: now, calendar: calendar
        )
        XCTAssertTrue(inCooling.isEmpty, "跳过 3 天后仍在 7 天冷却内")

        let afterCooling = HabitCandidateEngine.worthwhileCandidates(
            from: candidates,
            rules: [],
            cards: [skippedCard],
            now: calendar.date(byAdding: .day, value: 8, to: now)!,
            calendar: calendar
        )
        XCTAssertEqual(afterCooling.count, 1, "冷却期满后可以再次询问")
    }

    func testOnlyTheseExamplesExcludesMarkedDaysAndUsesLongerCooldown() throws {
        let now = referenceNow
        let days = [-2, -4, -6].map { day(offsetFromNow: $0, of: now) }
        let sessions = days.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 60, calendar: calendar)
        }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)

        var caseCard = try makeCard(bundleID: "com.openai.codex", days: days, calendar: calendar)
        caseCard.status = .answered
        caseCard.answerKind = .onlyTheseExamples
        caseCard.answeredAt = calendar.date(byAdding: .day, value: -3, to: now)
        caseCard.markedExampleKeys = days.map {
            HabitCandidateEngine.exampleKey(bundleID: "com.openai.codex", dayKey: HabitCandidateEngine.dayKey(for: $0))
        }

        // "仅这些例子"冷却 14 天：3 天后仍在冷却内。
        let inCooling = HabitCandidateEngine.worthwhileCandidates(
            from: candidates, rules: [], cards: [caseCard], now: now, calendar: calendar
        )
        XCTAssertTrue(inCooling.isEmpty)
    }

    func testStalePatternsAreNotResurrected() throws {
        let now = referenceNow
        // 例子都在 12 天前：超出 staleDays=10，不问。
        let oldDays = [-11, -12, -13].map { day(offsetFromNow: $0, of: now) }
        let sessions = oldDays.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 60, calendar: calendar)
        }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        XCTAssertTrue(candidates.isEmpty, "旧生活阶段的规律不应再弹问题")
    }

    func testCardShapeFollowsDesignContract() throws {
        let now = referenceNow
        let days = [-2, -4, -6].map { day(offsetFromNow: $0, of: now) }
        let sessions = days.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 84, calendar: calendar)
        }
        let candidates = HabitCandidateEngine.candidates(sessions: sessions, placeNameForDay: [:], now: now, calendar: calendar)
        let card = HabitCandidateEngine.makePatternCard(candidate: candidates[0], now: now, calendar: calendar)

        XCTAssertEqual(card.examples.count, 3)
        XCTAssertEqual(Set(card.examples.map(\.dayKey)).count, 3, "例子必须是三个不同日期")
        XCTAssertEqual(card.evidence.map(\.id), ["place", "activity", "unknown"], "依据顺序：地点 → 活动 → 仍不确定")
        XCTAssertTrue(card.question.contains("Codex"))
        XCTAssertTrue(card.question.contains("工作"))
        XCTAssertTrue(card.lead.contains("三个不同日期"))
        XCTAssertNotNil(card.evidence.first(where: { $0.id == "unknown" }))
    }

    // MARK: 存储 / 作答 / 撤销

    func testAnswerCreatesRuleAndSuppressesRegeneration() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        let due = HabitReviewCadence.weekly.currentPeriod(now: referenceNow, time: .evening, calendar: calendar).dueDate
        let evalNow = due.addingTimeInterval(120)
        let sessions = codexSessions(now: evalNow)

        store.evaluateIfNeeded(sessions: sessions, now: evalNow)
        XCTAssertEqual(store.pendingCount, 1, "三个独立日的 Codex 模式应生成一张卡")

        let card = try XCTUnwrap(store.pendingCards.first)
        store.answer(card, kind: .longTermRule, now: due.addingTimeInterval(300))

        // 规则：用户确认、active、validFrom = 回答时刻，不改写过去。
        XCTAssertEqual(store.rules.count, 1)
        let rule = store.rules[0]
        XCTAssertEqual(rule.status, .active)
        XCTAssertEqual(rule.origin, .userConfirmed)
        XCTAssertEqual(rule.conclusionCategory, "工作")
        XCTAssertEqual(rule.conditionBundleID, "com.openai.codex")
        XCTAssertEqual(rule.validFrom, due.addingTimeInterval(300))
        XCTAssertEqual(rule.supportingExampleKeys.count, 3)

        // 同一周期不重建；卡片已回答。
        store.evaluateIfNeeded(sessions: sessions, now: due.addingTimeInterval(600))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.batches.count, 1)

        // 持久化往返：新实例读回同一份知识与批次。
        let reloaded = HabitReviewStore(v2Store: v2, calendar: calendar)
        XCTAssertEqual(reloaded.rules.map(\.id), store.rules.map(\.id))
        XCTAssertEqual(reloaded.batches.count, 1)
        XCTAssertEqual(reloaded.cards.first?.status, .answered)
    }

    func testUndoRetiresRuleAndRestoresCard() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        let due = HabitReviewCadence.weekly.currentPeriod(now: referenceNow, time: .evening, calendar: calendar).dueDate
        let evalNow = due.addingTimeInterval(120)
        let sessions = codexSessions(now: evalNow)

        store.evaluateIfNeeded(sessions: sessions, now: evalNow)
        let card = try XCTUnwrap(store.pendingCards.first)
        store.answer(card, kind: .longTermRule)
        XCTAssertEqual(store.rules[0].status, .active)

        store.undoAnswer(store.cards[0])
        XCTAssertEqual(store.rules[0].status, .retired, "撤销只退役规则，保留记录")
        XCTAssertNotNil(store.rules[0].validTo)
        XCTAssertEqual(store.pendingCards.count, 1, "撤销后卡片回到待答")
        XCTAssertEqual(store.pendingCards[0].answerKind, nil)

        let reloaded = HabitReviewStore(v2Store: v2, calendar: calendar)
        XCTAssertEqual(reloaded.rules[0].status, .retired)
        XCTAssertEqual(reloaded.pendingCards.count, 1)
    }

    func testOnlyTheseExamplesDoesNotCreateRule() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        let due = HabitReviewCadence.weekly.currentPeriod(now: referenceNow, time: .evening, calendar: calendar).dueDate
        let evalNow = due.addingTimeInterval(120)
        let sessions = codexSessions(now: evalNow)

        store.evaluateIfNeeded(sessions: sessions, now: evalNow)
        let card = try XCTUnwrap(store.pendingCards.first)
        store.answer(card, kind: .onlyTheseExamples)

        XCTAssertTrue(store.rules.isEmpty, "'仅这些例子'不建立跨事件规则")
        XCTAssertEqual(store.cards[0].markedExampleKeys.count, 3)
        XCTAssertEqual(store.cards[0].status, .answered)
    }

    func testSkipEntersCooldownAndPeriodKeyPreventsRebuild() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        let due = HabitReviewCadence.weekly.currentPeriod(now: referenceNow, time: .evening, calendar: calendar).dueDate
        let evalNow = due.addingTimeInterval(120)
        let sessions = codexSessions(now: evalNow)

        store.evaluateIfNeeded(sessions: sessions, now: evalNow)
        let card = try XCTUnwrap(store.pendingCards.first)
        store.answer(card, kind: .skip)

        // 同一周期：即使跳过了也不重建同一个问题。
        store.evaluateIfNeeded(sessions: sessions, now: due.addingTimeInterval(3_600))
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.batches.count, 1)
    }

    func testQuietPeriodGeneratesNothing() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        let due = HabitReviewCadence.weekly.currentPeriod(now: referenceNow, time: .evening, calendar: calendar).dueDate
        let evalNow = due.addingTimeInterval(120)

        // 只有两天：没有值得问的问题，安静跳过，不产生空包。
        let sessions = [
            session("com.openai.codex", appName: "Codex", day: day(offsetFromNow: -2, of: evalNow), startHour: 10, durationMinutes: 60, calendar: calendar),
            session("com.openai.codex", appName: "Codex", day: day(offsetFromNow: -4, of: evalNow), startHour: 10, durationMinutes: 60, calendar: calendar),
        ]

        store.evaluateIfNeeded(sessions: sessions, now: evalNow)
        XCTAssertEqual(store.pendingCount, 0)
        XCTAssertEqual(store.batches.count, 0, "没有值得问的问题时不应生成问题包")
    }

    func testManualCadenceOnlyGeneratesOnDemand() throws {
        let v2 = try makeStore()
        let store = HabitReviewStore(v2Store: v2, calendar: calendar)
        store.setCadence(.manual)
        let now = referenceNow
        let sessions = codexSessions(now: now)

        store.evaluateIfNeeded(sessions: sessions, now: now, allowManualGeneration: false)
        XCTAssertEqual(store.pendingCount, 0, "手动节奏不主动生成")

        store.evaluateIfNeeded(sessions: sessions, now: now, allowManualGeneration: true)
        XCTAssertEqual(store.pendingCount, 1, "打开回顾页时才生成")
    }

    func testCadencePeriodMath() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.firstWeekday = 2 // 周一为一周起点，验证周日回顾日的推导
        let time = HabitReviewTimePreset.evening

        // 周三 → 本周日 20:00
        let wednesday = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 12))!
        let weekly = HabitReviewCadence.weekly.currentPeriod(now: wednesday, time: time, calendar: gregorian)
        let sunday = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 20))!
        XCTAssertEqual(weekly.dueDate, sunday)
        XCTAssertTrue(weekly.key.hasPrefix("w-2026-09-27"))
        XCTAssertFalse(HabitReviewCadence.weekly.isDue(now: wednesday, time: time, calendar: gregorian))
        XCTAssertTrue(HabitReviewCadence.weekly.isDue(now: sunday.addingTimeInterval(60), time: time, calendar: gregorian))

        // 周日 19:00：还未到期。
        let sundayMorning = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))!
        XCTAssertFalse(HabitReviewCadence.weekly.isDue(now: sundayMorning, time: time, calendar: gregorian))

        // 每月：2026-09 的月末是 9/30。
        let midSeptember = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 8))!
        let monthly = HabitReviewCadence.monthly.currentPeriod(now: midSeptember, time: time, calendar: gregorian)
        XCTAssertEqual(monthly.dueDate, gregorian.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 20))!)
        XCTAssertTrue(monthly.key.hasPrefix("m-2026-09"))

        // 每 3 天：9/27 之前最近块首 9/25（2026-01-01 起按 3 天分块）。
        let saturday = gregorian.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
        let threeDay = HabitReviewCadence.everyThreeDays.currentPeriod(now: saturday, time: time, calendar: gregorian)
        XCTAssertEqual(threeDay.dueDate, gregorian.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 20))!)
    }

    // MARK: Helpers

    private func codexSessions(now: Date) -> [ActivitySession] {
        [-2, -4, -6].map { day(offsetFromNow: $0, of: now) }.map {
            session("com.openai.codex", appName: "Codex", day: $0, startHour: 10, durationMinutes: 84, calendar: calendar)
        }
    }

    private func makeCard(bundleID: String, days: [Date], calendar: Calendar) throws -> HabitReviewCard {
        let examples = days.map { dayDate in
            HabitExample(
                dayKey: HabitCandidateEngine.dayKey(for: dayDate),
                dateText: HabitCandidateEngine.shortDateText(dayDate),
                duration: 3_600,
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

}
