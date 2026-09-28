import Foundation
import Combine
import RiverDiaryCore

// MARK: - 习惯回顾存储与调度
//
// 设计承接 personal-context-learning-strategy.md 第 9.2/10/12/13 节：
// - 正式调度读取大模型生成的全天时间线摘要，由模型提出跨天交流；
// - 本机负责周期、来源白名单、用户记忆、范围、持久化和撤销；
// - 旧版本机候选入口只留给迁移和旧数据兼容，应用 UI 不再调用；
// - 每个回顾周期只有一个持久化去重键（periodKey），不回补错过的周期；
// - 规则带 recordedAt / validFrom 双时间字段，"从现在起"不改写过去；
// - 跳过进入冷却；作答可撤销；撤销只退役规则，不删除用户回答的记录。

@MainActor
final class HabitReviewStore: ObservableObject {
    static let cadencePrefKey = "habit.review.cadence"
    static let timePrefKey = "habit.review.timePreset"

    @Published private(set) var rules: [HabitPersonalRule] = []
    @Published private(set) var cards: [HabitReviewCard] = []
    @Published private(set) var batches: [HabitReviewBatch] = []
    @Published private(set) var pendingConfirmations: [RiverSharedStateRecord] = []
    @Published private(set) var cadence: HabitReviewCadence = .weekly
    @Published private(set) var timePreset: HabitReviewTimePreset = .evening
    @Published private(set) var lastEvaluatedAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var respondingCardIDs: Set<UUID> = []

    private let v2Store: V2Store
    private let calendar: Calendar
    private var encoder: JSONEncoder
    private var decoder: JSONDecoder
    private var syncChangeObserver: NSObjectProtocol?

    init(v2Store: V2Store, calendar: Calendar = .current) {
        self.v2Store = v2Store
        self.calendar = calendar
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        loadCadence()
        load()
        syncChangeObserver = NotificationCenter.default.addObserver(
            forName: .riverCanonicalSyncDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.loadCadence()
                self?.load()
            }
        }
    }

    deinit {
        if let syncChangeObserver { NotificationCenter.default.removeObserver(syncChangeObserver) }
    }

    // MARK: Loading

    private func loadCadence() {
        if let raw = v2Store.userPref(key: Self.cadencePrefKey),
           let value = HabitReviewCadence(rawValue: raw) {
            cadence = value
        }
        if let raw = v2Store.userPref(key: Self.timePrefKey),
           let value = HabitReviewTimePreset(rawValue: raw) {
            timePreset = value
        }
    }

    private func load() {
        rules = v2Store.habitRuleRows().compactMap { row in
            decode(HabitPersonalRule.self, row.payloadJSON)
        }.sorted { $0.recordedAt < $1.recordedAt }
        cards = v2Store.habitCardRows().compactMap { row in
            decode(HabitReviewCard.self, row.payloadJSON)
        }.sorted { $0.createdAt < $1.createdAt }
        batches = v2Store.habitBatchRows().compactMap { row in
            decode(HabitReviewBatch.self, row.payloadJSON)
        }.sorted { $0.createdAt < $1.createdAt }
        pendingConfirmations = v2Store.sharedUserRecords()
            .filter { $0.kind == .pendingConfirmation && $0.status == "pending" }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func resolvePendingConfirmation(_ record: RiverSharedStateRecord,
                                    as resolution: RiverPendingConfirmationResolution,
                                    correction: String? = nil) -> Bool {
        guard v2Store.resolvePendingConfirmation(record, as: resolution, correction: correction) else {
            lastError = v2Store.lastError ?? "待确认事项保存失败"
            return false
        }
        load()
        lastError = nil
        return true
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Cadence

    func setCadence(_ value: HabitReviewCadence) {
        cadence = value
        _ = v2Store.setUserPref(key: Self.cadencePrefKey, value: value.rawValue)
        _ = v2Store.setSharedHabitPreference(key: Self.cadencePrefKey, value: value.rawValue)
    }

    func setTimePreset(_ value: HabitReviewTimePreset) {
        timePreset = value
        _ = v2Store.setUserPref(key: Self.timePrefKey, value: value.rawValue)
        _ = v2Store.setSharedHabitPreference(key: Self.timePrefKey, value: value.rawValue)
    }

    /// 节奏面板/空态使用的下一次回顾描述。
    var nextReviewText: String? {
        cadence.nextReviewText(now: Date(), time: timePreset, calendar: calendar)
    }

    // MARK: Evaluation

    /// 当前活跃批次（最近一份未整体过期的问题包）。
    var currentBatch: HabitReviewBatch? { batches.last }

    /// 当前批次里仍待回答的卡片，按生成顺序。
    var pendingCards: [HabitReviewCard] {
        guard let batch = currentBatch else { return [] }
        let ids = Set(batch.cardIDs)
        return cards.filter { ids.contains($0.id) && $0.isPending }
    }

    var pendingCount: Int { pendingCards.count }

    /// 回答完毕（含跳过）的卡片，用于原位展示与撤销。
    var settledCards: [HabitReviewCard] {
        guard let batch = currentBatch else { return [] }
        let ids = Set(batch.cardIDs)
        return cards.filter { ids.contains($0.id) && !$0.isPending }
    }

    /// 应用启动/激活时调用：过期旧卡，判断当前周期是否到期，到期则生成问题包。
    /// - Parameter allowManualGeneration: 手动节奏只在用户打开回顾页时允许生成。
    @available(*, deprecated, message: "Production review uses evaluateWithAIIfNeeded(ai:)")
    func evaluateIfNeeded(activity: ActivityStore, now: Date = Date(), allowManualGeneration: Bool = false) {
        guard let windowStart = observationWindowStart(now: now) else { return }
        evaluateIfNeeded(sessions: activity.sessions(from: windowStart, to: now), now: now, allowManualGeneration: allowManualGeneration)
    }

    /// 会话注入的评估入口（测试与未来的调度器共用）。
    func evaluateIfNeeded(sessions: [ActivitySession], now: Date = Date(), allowManualGeneration: Bool = false) {
        expireStaleCards(now: now)

        switch cadence {
        case .manual:
            guard allowManualGeneration else { return }
        case .weekly, .everyThreeDays, .monthly, .smart:
            guard cadence.isDue(now: now, time: timePreset, calendar: calendar) || cadence == .smart else { return }
        }

        generateBatchIfValuable(sessions: sessions, now: now)
    }

    /// Model-backed review generation. Timeline analysis runs every day; this
    /// method only opens the user's review cadence and asks the model to find
    /// worthwhile multi-day conversations from those persisted day digests.
    func evaluateWithAIIfNeeded(
        ai: AIAssistantStore,
        now: Date = Date(),
        allowManualGeneration: Bool = false
    ) async {
        expireStaleCards(now: now)
        expireLegacyPendingCards()
        guard pendingCards.isEmpty else { return }

        switch cadence {
        case .manual:
            guard allowManualGeneration else { return }
        case .weekly, .everyThreeDays, .monthly:
            guard cadence.isDue(now: now, time: timePreset, calendar: calendar) else { return }
        case .smart:
            let sinceLast = lastBatchIntervalDays(now: now)
            let checkpoint = (sinceLast ?? .infinity) >= 31
            guard checkpoint || (sinceLast ?? .infinity) >= 7 else { return }
        }

        let period = cadence.currentPeriod(now: now, time: timePreset, calendar: calendar)
        if batches.contains(where: { $0.periodKey == period.key }) { return }

        guard let windowStart = calendar.date(byAdding: .day, value: -14, to: calendar.startOfDay(for: now)) else { return }
        let dayKeys = (0..<14).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: windowStart) else { return nil }
            return DiaryEntry.dateFormatter.string(from: day)
        }
        guard ai.hasEnoughHabitEvidence(in: dayKeys) else {
            lastError = nil
            return
        }
        guard let generated = await ai.generateHabitReviewProposals(
            periodKey: period.key,
            dayKeys: dayKeys,
            previousCards: cards
        ) else {
            lastError = ai.analysisReady
                ? "暂时无法整理习惯回顾；已有记录仍保留。"
                : "连接并验证 AI 模型后，习惯回顾才能理解跨天活动。"
            return
        }

        let batch = HabitReviewBatch(
            periodKey: period.key,
            cadence: cadence,
            createdAt: now,
            cardIDs: generated.map(\.id),
            introTitle: generated.isEmpty ? "我还没有发现值得打扰你的新问题" : "我最近留意到一些和你有关的事",
            introDetail: generated.isEmpty
                ? "我会继续理解每天的活动；有真正值得确认的模式时再和你聊。"
                : "我结合最近的活动记录整理了这些观察。你可以补充、纠正，也可以直接用自己的话回答。",
            estimatedSeconds: max(0, generated.count * 30)
        )
        persistBatch(batch)
        for card in generated { persistCard(card, batchID: batch.id) }
        batches.append(batch)
        cards.append(contentsOf: generated)
        lastEvaluatedAt = now
        lastError = nil
    }

    private func expireLegacyPendingCards() {
        for index in cards.indices where cards[index].isPending && cards[index].contextExamples == nil {
            cards[index].status = .expired
            cards[index].answerScopeText = "旧版应用分类问题已关闭；原有确认规则仍保留。"
            persistCard(cards[index], batchID: owningBatchID(of: cards[index].id))
        }
    }

    private func lastBatchIntervalDays(now: Date) -> Double? {
        guard let last = batches.last else { return nil }
        return now.timeIntervalSince(last.createdAt) / 86_400
    }

    /// 从活动与位置样本生成问题包。没有值得问的问题时安静返回（0 张）。
    @discardableResult
    @available(*, deprecated, message: "Production review uses AI-authored conversations")
    func generateBatchIfValuable(activity: ActivityStore, now: Date = Date()) -> Bool {
        guard let windowStart = observationWindowStart(now: now) else { return false }
        return generateBatchIfValuable(sessions: activity.sessions(from: windowStart, to: now), now: now)
    }

    /// 会话注入的生成入口（测试与未来的应用级调度共用）。
    @discardableResult
    func generateBatchIfValuable(sessions: [ActivitySession], now: Date = Date()) -> Bool {
        // 已有一份带待答卡片的问题包时不重复生成。
        guard pendingCards.isEmpty else { return false }

        // 同一周期已有批次（即使都已回答）不再重建，防止把旧问题滚成待办。
        let period = cadence.currentPeriod(now: now, time: timePreset, calendar: calendar)
        if cadence != .manual && cadence != .smart,
           batches.contains(where: { $0.periodKey == period.key }) {
            return false
        }

        let candidates = collectCandidates(sessions: sessions, now: now)
        guard !candidates.isEmpty else {
            lastEvaluatedAt = now
            return false
        }

        // 智能积累的触发门槛：攒够 3 个真正不同的高价值问题才出现，
        // 两次回顾至少间隔 7 天；最长 31 天做一次检查点（届时 1 个也整理）。
        if cadence == .smart {
            let sinceLast = lastBatchIntervalDays(now: now)
            let checkpoint = (sinceLast ?? .infinity) >= 31
            if candidates.count < (checkpoint ? 1 : 3) { return false }
            if let sinceLast, sinceLast < 7 { return false }
        }

        let cardsToBundle = candidates.prefix(HabitCandidateEngine.Thresholds().maxCards).map { candidate in
            HabitCandidateEngine.makePatternCard(candidate: candidate, now: now, calendar: calendar)
        }
        let count = cardsToBundle.count
        let batch = HabitReviewBatch(
            periodKey: period.key,
            cadence: cadence,
            createdAt: now,
            cardIDs: cardsToBundle.map(\.id)
        )
        let introTitle = count == 1 ? "有 1 件值得你判断的事" : "有 \(count) 件值得你判断的事"
        let finalBatch = withIntro(batch, title: introTitle, seconds: max(15, count * 15))

        persistBatch(finalBatch)
        for card in cardsToBundle { persistCard(card, batchID: finalBatch.id) }
        batches.append(finalBatch)
        cards.append(contentsOf: cardsToBundle)
        lastEvaluatedAt = now
        return true
    }

    private func withIntro(_ batch: HabitReviewBatch, title: String, seconds: Int) -> HabitReviewBatch {
        var updated = batch
        updated.introTitle = title
        updated.estimatedSeconds = seconds
        return updated
    }

    /// 引擎输入：最近 14 个完整本地日 + 日级地点名。
    private func observationWindowStart(now: Date) -> Date? {
        calendar.date(byAdding: .day, value: -HabitCandidateEngine.Thresholds().windowDays, to: calendar.startOfDay(for: now))
    }

    private func collectCandidates(sessions: [ActivitySession], now: Date) -> [HabitCandidateEngine.Candidate] {
        let placeNames = placeNameByDay(now: now)
        return HabitCandidateEngine.worthwhileCandidates(
            from: HabitCandidateEngine.candidates(
                sessions: sessions,
                placeNameForDay: placeNames,
                now: now,
                calendar: calendar
            ),
            rules: rules,
            cards: cards,
            now: now,
            calendar: calendar
        )
    }

    /// 从位置原始事件取每个本地日的可靠地点名（有名字、精度可用的多数样本）。
    /// internal 以便审计回归测试直接断言精度过滤语义。
    func placeNameByDay(now: Date) -> [String: String] {
        guard let start = observationWindowStart(now: now) else { return [:] }
        let events = v2Store.rawEvents(between: start, end: now).filter { event in
            event.kind == .locationUpdate
                && event.payload.locationName?.isEmpty == false
        }
        var counts: [String: [String: Int]] = [:]
        for event in events {
            // 明显无效的精度不参与：缺失不能当作零。
            if let accuracy = event.payload.horizontalAccuracy, accuracy < 0 || accuracy > 500 { continue }
            guard let name = event.payload.locationName else { continue }
            let dayKey = HabitCandidateEngine.dayKey(for: event.timestamp)
            counts[dayKey, default: [:]][name, default: 0] += 1
        }
        return counts.mapValues { names in
            names.max { $0.value < $1.value }?.key ?? ""
        }
    }

    /// 超过 35 天的待答卡过期退出，不把无限制的旧问题滚成待办。
    func expireStaleCards(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-35 * 86_400)
        for index in cards.indices where cards[index].isPending && cards[index].createdAt < cutoff {
            cards[index].status = .expired
            persistCard(cards[index], batchID: owningBatchID(of: cards[index].id))
        }
    }

    /// 页面打开时把 bundled 卡标记为 shown（提交前再次校验由持久化覆盖）。
    func markBatchShownIfFirstOpen() {
        guard var batch = currentBatch, batch.shownAt == nil else { return }
        batch.shownAt = Date()
        persistBatch(batch)
        if let index = batches.lastIndex(where: { $0.id == batch.id }) {
            batches[index] = batch
        }
        // 状态机里 bundled → shown 此前从未被写入（死状态）：
        // 首次展示即落库，未来任何区分"已展示/未展示"的逻辑才有真实数据。
        for index in cards.indices
        where batch.cardIDs.contains(cards[index].id) && cards[index].status == .bundled {
            cards[index].status = .shown
            persistCard(cards[index], batchID: batch.id)
        }
    }

    /// 卡片真正所属的批次：新卡没有 batch_id 列的语义漂移——
    /// 旧批次卡片在批次 N 出现后被作答，其 batch_id 不应被改写成 N。
    private func owningBatchID(of cardID: UUID) -> UUID? {
        batches.last { $0.cardIDs.contains(cardID) }?.id
    }

    // MARK: Answering

    /// 一次点选的答案。
    struct Answer {
        var kind: HabitAnswerKind
        /// 长期规则的类别（长期回答时必填，默认取卡片建议）。
        var category: String?
        /// 长期规则是否限定地点（默认按卡片地点条件）。
        var limitToPlace: Bool?
    }

    /// 点选后立即保存。范围只按卡片展示的条件生效。
    func answer(_ card: HabitReviewCard, with answer: Answer, now: Date = Date()) {
        guard card.isPending else { return }
        guard var updated = cards.first(where: { $0.id == card.id }) else { return }

        switch answer.kind {
        case .longTermRule:
            let category = answer.category ?? card.proposedCategory
            let limitToPlace = answer.limitToPlace ?? (card.placeKey != nil)
            let place = limitToPlace ? card.placeKey : nil
            let scopeText = [card.appName, place.map { $0 + "附近" }]
                .compactMap { $0 }
                .joined(separator: " · ")
            let rule = HabitPersonalRule(
                dedupKey: card.dedupKey,
                conditionBundleID: card.bundleID,
                conditionAppName: card.appName,
                conditionPlaceKey: place,
                conclusionCategory: category,
                scopeText: scopeText,
                status: .active,
                origin: .userConfirmed,
                recordedAt: now,
                validFrom: now,
                supportingExampleKeys: card.examples.map(\.sourceKey),
                createdFromCardID: card.id
            )
            persistRule(rule)
            rules.append(rule)
            updated.answerKind = .longTermRule
            updated.answerScopeText = "以后\(place.map { "在\($0)附近" } ?? "")使用 \(card.appName) 记为「\(category)」 · 从现在起"
            updated.createdRuleID = rule.id
        case .onlyTheseExamples:
            updated.answerKind = .onlyTheseExamples
            updated.markedExampleKeys = card.examples.map(\.sourceKey)
            updated.answerScopeText = "只确认这次列出的 \(card.examples.count) 条记录，不建立长期规则"
        case .skip:
            updated.answerKind = .skip
            updated.answerScopeText = "暂时不确定；有新线索前不再问"
        case .conversation:
            updated.answerKind = .conversation
            updated.answerScopeText = "这段交流已整理；你可以随时撤销或继续补充。"
        }

        updated.status = answer.kind == .skip ? .skipped : .answered
        updated.answeredAt = now
        persistCard(updated, batchID: owningBatchID(of: updated.id))
        if let index = cards.firstIndex(where: { $0.id == updated.id }) {
            cards[index] = updated
        }
        lastEvaluatedAt = now
    }

    /// 便捷作答（供视图直接把选项映射进来）。
    func answer(_ card: HabitReviewCard, kind: HabitAnswerKind, category: String? = nil, limitToPlace: Bool? = nil, now: Date = Date()) {
        answer(card, with: Answer(kind: kind, category: category, limitToPlace: limitToPlace), now: now)
    }

    func sendMessage(_ text: String, to card: HabitReviewCard, using ai: AIAssistantStore, now: Date = Date()) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, card.isPending,
              !respondingCardIDs.contains(card.id),
              var updated = cards.first(where: { $0.id == card.id }) else { return }
        let priorConversation = updated.conversation ?? []
        updated.conversation = priorConversation + [HabitReviewTurn(role: .user, text: message, createdAt: now)]
        persistCard(updated, batchID: owningBatchID(of: updated.id))
        if let index = cards.firstIndex(where: { $0.id == updated.id }) { cards[index] = updated }
        respondingCardIDs.insert(card.id)
        defer { respondingCardIDs.remove(card.id) }

        guard let response = await ai.respondToHabitReview(
            card: updated,
            conversation: priorConversation,
            userMessage: message
        ) else {
            lastError = ai.analysisReady ? "刚才没能接上这段交流，内容已保留，可以稍后重试。" : "需要连接已验证的 AI 模型才能继续这段交流。"
            return
        }
        guard var latest = cards.first(where: { $0.id == card.id }), latest.isPending else { return }
        latest.conversation = (latest.conversation ?? []) + [HabitReviewTurn(role: .assistant, text: response.reply, createdAt: Date())]
        latest.suggestedReplies = response.suggestedReplies
        latest.ruleSuggestion = response.ruleSuggestion
        latest.conversationResolved = response.resolved
        if response.resolved, response.ruleSuggestion == nil {
            latest.answerKind = .conversation
            latest.status = .answered
            latest.answeredAt = Date()
            latest.answerScopeText = "这段交流已整理；你可以随时撤销或继续补充。"
        }
        persistCard(latest, batchID: owningBatchID(of: latest.id))
        if let index = cards.firstIndex(where: { $0.id == latest.id }) { cards[index] = latest }
        lastError = nil
    }

    func acceptRuleSuggestion(for card: HabitReviewCard, now: Date = Date()) {
        guard card.isPending,
              let text = card.ruleSuggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              var updated = cards.first(where: { $0.id == card.id }) else { return }
        let rule = HabitPersonalRule(
            dedupKey: card.dedupKey,
            conditionBundleID: card.bundleID,
            conditionAppName: card.appName,
            conditionPlaceKey: card.placeKey,
            naturalLanguageRule: text,
            supportingEvidenceRefs: card.evidenceRefs ?? [],
            conclusionCategory: "个人习惯",
            scopeText: text,
            status: .active,
            origin: .userConfirmed,
            recordedAt: now,
            validFrom: now,
            supportingExampleKeys: card.contextExamples?.map(\.id) ?? [],
            createdFromCardID: card.id
        )
        persistRule(rule)
        rules.append(rule)
        updated.createdRuleID = rule.id
        updated.answerKind = .longTermRule
        updated.answerScopeText = "已记住：\(text)"
        updated.status = .answered
        updated.answeredAt = now
        persistCard(updated, batchID: owningBatchID(of: updated.id))
        if let index = cards.firstIndex(where: { $0.id == updated.id }) { cards[index] = updated }
        lastError = nil
    }

    func retireRule(_ rule: HabitPersonalRule, now: Date = Date()) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }),
              rules[index].status == .active else { return }
        rules[index].status = .retired
        rules[index].validTo = now
        persistRule(rules[index])
    }

    /// 撤销本次回答：卡片回到待答，若创建过规则则退役（保留记录，不抹掉过去）。
    func undoAnswer(_ card: HabitReviewCard, now: Date = Date()) {
        guard !card.isPending else { return }
        guard var updated = cards.first(where: { $0.id == card.id }) else { return }

        if let ruleID = updated.createdRuleID,
           let index = rules.firstIndex(where: { $0.id == ruleID }) {
            rules[index].status = .retired
            rules[index].validTo = now
            persistRule(rules[index])
        }

        updated.status = .shown
        updated.answeredAt = nil
        updated.answerKind = nil
        updated.answerScopeText = nil
        updated.createdRuleID = nil
        updated.markedExampleKeys = []
        persistCard(updated, batchID: owningBatchID(of: updated.id))
        if let index = cards.firstIndex(where: { $0.id == updated.id }) {
            cards[index] = updated
        }
    }

    // MARK: Persistence

    private func persistRule(_ rule: HabitPersonalRule) {
        guard let json = encode(rule) else {
            lastError = "规则序列化失败"
            return
        }
        if !v2Store.upsertHabitRule(id: rule.id, status: rule.status.rawValue, payloadJSON: json, updatedAt: Date()) {
            lastError = v2Store.lastError
        }
    }

    private func persistCard(_ card: HabitReviewCard, batchID: UUID?) {
        guard let json = encode(card) else {
            lastError = "问题卡序列化失败"
            return
        }
        if !v2Store.upsertHabitCard(
            id: card.id,
            batchID: batchID,
            dedupKey: card.dedupKey,
            status: card.status.rawValue,
            payloadJSON: json,
            updatedAt: Date()
        ) {
            lastError = v2Store.lastError
        }
    }

    private func persistBatch(_ batch: HabitReviewBatch) {
        guard let json = encode(batch) else {
            lastError = "问题包序列化失败"
            return
        }
        if !v2Store.upsertHabitBatch(
            id: batch.id,
            periodKey: batch.periodKey,
            payloadJSON: json,
            createdAt: batch.createdAt,
            shownAt: batch.shownAt
        ) {
            lastError = v2Store.lastError
        }
    }
}
