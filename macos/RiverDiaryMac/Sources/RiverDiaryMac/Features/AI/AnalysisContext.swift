import Foundation

// MARK: - 统一分析上下文（A 层）
//
// 设计承接 personal-context-learning-strategy.md 9.2 节的输入契约：
// 每次模型请求前，先按范围装配一份结构化上下文——本机事实、用户已确认的
// 个人规则、已确认的长期记忆、近期 AI 结论——连同指纹持久化到 context_snapshots，
// AnalysisRun.inputContextReference 指回它。"这次 AI 读了什么"从此可追溯；
// 用户确认过的知识（规则/记忆）从此进入每一次分析。

/// 一天的可核事实。进入 prompt 前已按本地日界裁剪，不含任何窗口标题原文。
struct AnalysisDayFacts: Codable, Hashable, Sendable {
    var dayKey: String
    var diaryOverview: String?
    var captureCount: Int
    var sessionCount: Int
    var recordedMinutes: Int
    var focusMinutes: Int
    var topApps: [String]
}

/// 近期 AI 结论的轻量引用（结果链：日报 → 周报 → 月信 → 询问）。
struct AnalysisConclusionSummary: Codable, Hashable, Sendable, Identifiable {
    var taskKey: String
    var rangeKey: String
    var headline: String
    var createdAt: Date

    var id: String { "\(taskKey)|\(rangeKey)" }
}

/// 一次 AI 请求读取的完整上下文。
struct AnalysisContext: Codable, Sendable {
    var schemaVersion: Int
    var taskKey: String
    var rangeKey: String
    var startDate: String?
    var endDate: String?
    var days: [AnalysisDayFacts]
    /// 用户在习惯回顾里确认过的规则（scopeText → 类别）。
    var personalRules: [String]
    /// 用户在记忆页确认过的长期记忆。
    var confirmedMemories: [String]
    var recentConclusions: [AnalysisConclusionSummary]
    /// 本次请求允许引用的证据白名单（EvidenceReference 字符串）。
    var evidenceRefs: [String]
    /// Task-specific evidence summaries that were rendered verbatim into the prompt.
    var detailLines: [String]? = nil
    var fingerprint: String
    var model: String
    var createdAt: Date
}

/// 日报的轻量结构化摘要：写进 analysis_runs.digest_json，
/// 供周报 prompt、月度信与询问页直接消费，不必重新解析全文。
struct DailyDigest: Codable, Hashable, Sendable {
    var headline: String
    var points: [String]
}

@MainActor
enum ContextAssembler {
    struct Assembled {
        /// context_snapshots 行 ID（AnalysisRun.inputContextReference 指向它）。
        let snapshotID: UUID?
        let fingerprint: String
        /// 渲染好的 prompt 段落；没有内容时为占位文本，调用方直接插值。
        let ruleLines: String
        let memoryLines: String
        let conclusionLines: String
    }

    // MARK: 范围键

    static func dayRangeKey(_ dayKey: String) -> String { "d-\(dayKey)" }

    static func weekRangeKey(startDate: String) -> String { "w-\(startDate)" }

    // MARK: 日事实

    /// 从原始记录计算一天的可核事实（进入上下文与指纹，窗口标题原文不进入）。
    static func dayFacts(
        dayKey: String,
        entries: [DiaryEntry],
        captures: [QuickCapture],
        sessions: [ActivitySession]
    ) -> AnalysisDayFacts {
        let daySessions = sessions.filter { DiaryEntry.dateFormatter.string(from: $0.start) == dayKey }
        let recorded = daySessions.reduce(TimeInterval(0)) { $0 + $1.duration }
        let focus = daySessions.filter { ActivityClassifier.isFocus($0.category) }.reduce(TimeInterval(0)) { $0 + $1.duration }
        var appDurations: [String: TimeInterval] = [:]
        for session in daySessions { appDurations[session.appName, default: 0] += session.duration }
        let overview = entries.first(where: { $0.date == dayKey })?.displayOverview
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AnalysisDayFacts(
            dayKey: dayKey,
            diaryOverview: (overview?.isEmpty == false) ? String(overview!.prefix(160)) : nil,
            captureCount: captures.filter { DiaryEntry.dateFormatter.string(from: $0.createdAt) == dayKey }.count,
            sessionCount: daySessions.count,
            recordedMinutes: Int(recorded / 60),
            focusMinutes: Int(focus / 60),
            topApps: appDurations.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        )
    }

    // MARK: 装配

    /// 装配并持久化一份上下文。规则/记忆/结论从共享 V2 库读取；
    /// 指纹覆盖全部输入，任何一项变化都会得到新指纹（缓存失效的正确粒度）。
    static func assemble(
        v2Store: V2Store,
        task: AITask,
        startDate: String?,
        endDate: String?,
        days: [AnalysisDayFacts],
        evidenceRefs: [String],
        detailLines: [String] = [],
        conclusions: [AnalysisConclusionSummary],
        model: String,
        now: Date = Date()
    ) -> Assembled {
        let rules = activeRuleLines(v2Store: v2Store, now: now)
        let memories = confirmedMemoryLines(v2Store: v2Store)
        let ruleFingerprint = rules.map { "\($0)|\(Self.stable($0))" }.joined(separator: "|")
        let memoryFingerprint = memories.map { Self.stable($0) }.joined(separator: "|")
        let conclusionFingerprint = conclusions
            .map { "\($0.taskKey)|\($0.rangeKey)|\($0.createdAt.timeIntervalSince1970)|\(Self.stable($0.headline))" }
            .sorted()
            .joined(separator: "|")
        let dayFingerprint = days
            .map { day in
                "\(day.dayKey)|\(day.captureCount)|\(day.sessionCount)|\(day.recordedMinutes)|\(day.focusMinutes)|"
                    + "\(Self.stable(day.diaryOverview ?? ""))|\(day.topApps.joined(separator: ","))"
            }
            .joined(separator: "\n")
        let fingerprintSource = [
            "v1",
            task.rawValue,
            startDate ?? "",
            endDate ?? "",
            dayFingerprint,
            ruleFingerprint,
            memoryFingerprint,
            conclusionFingerprint,
            evidenceRefs.sorted().joined(separator: ","),
            detailLines.joined(separator: "\n"),
        ].joined(separator: "\n")
        let fingerprint = SHA256Hex.hash(Data(fingerprintSource.utf8))

        let context = AnalysisContext(
            schemaVersion: 1,
            taskKey: task.rawValue,
            rangeKey: rangeKey(task: task, startDate: startDate, endDate: endDate),
            startDate: startDate,
            endDate: endDate,
            days: days,
            personalRules: rules,
            confirmedMemories: memories,
            recentConclusions: conclusions,
            evidenceRefs: evidenceRefs,
            detailLines: detailLines.isEmpty ? nil : detailLines,
            fingerprint: fingerprint,
            model: model,
            createdAt: now
        )

        let snapshotID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = (try? encoder.encode(context)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let persisted = v2Store.insertContextSnapshot(id: snapshotID, payloadJSON: payload, model: model, createdAt: now)
            && v2Store.contextSnapshotExists(snapshotID)

        return Assembled(
            snapshotID: persisted ? snapshotID : nil,
            fingerprint: fingerprint,
            ruleLines: renderLines(rules, empty: "无已确认的个人规则。"),
            memoryLines: renderLines(memories, empty: "无已确认的长期记忆。"),
            conclusionLines: renderLines(
                conclusions.map { summary in
                    let dateText = DiaryEntry.dateFormatter.string(from: summary.createdAt)
                    return "\(dateText) · \(summary.headline)"
                },
                empty: "暂无近期 AI 结论。"
            )
        )
    }

    static func rangeKey(task: AITask, startDate: String?, endDate: String?) -> String {
        if task == .timelineDigest || task == .analysisDaily, let day = endDate ?? startDate {
            return dayRangeKey(day)
        }
        if task == .analysisWeekly, let start = startDate {
            return weekRangeKey(startDate: start)
        }
        return "\(task.rawValue)-\(startDate ?? "")-\(endDate ?? "")"
    }

    // MARK: 用户知识（C1 反馈线）

    /// 用户在习惯回顾里确认过的规则。只有 userConfirmed + active 且在有效期内的
    /// 规则才会进入 prompt——自主观察中的候选不冒充用户知识。
    static func activeRules(v2Store: V2Store, now: Date = Date()) -> [HabitPersonalRule] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return v2Store.habitRuleRows().compactMap { row in
            guard let data = row.payloadJSON.data(using: .utf8),
                  let rule = try? decoder.decode(HabitPersonalRule.self, from: data) else { return nil }
            guard rule.status == .active, rule.origin == .userConfirmed else { return nil }
            if let validTo = rule.validTo, validTo < now { return nil }
            // 尚未生效的规则（validFrom 在未来）不属于"有效期"，不得进入 prompt。
            guard rule.validFrom <= now else { return nil }
            return rule
        }.sorted { $0.validFrom < $1.validFrom }
    }

    static func activeRuleLines(v2Store: V2Store, now: Date = Date()) -> [String] {
        activeRules(v2Store: v2Store, now: now).map { rule in
            let confirmedAt = DiaryEntry.dateFormatter.string(from: rule.validFrom)
            if let naturalLanguageRule = rule.naturalLanguageRule?.trimmingCharacters(in: .whitespacesAndNewlines),
               !naturalLanguageRule.isEmpty {
                let evidence = (rule.supportingEvidenceRefs ?? []).prefix(5).joined(separator: ",")
                let evidenceText = evidence.isEmpty ? "" : "；原始支持来源：\(evidence)"
                return "- 用户确认的个人习惯：\(naturalLanguageRule)（\(confirmedAt) 起适用\(evidenceText)）"
            }
            return "- 旧版较宽的应用归类参考：\(rule.scopeText) → 曾记为「\(rule.conclusionCategory)」（\(confirmedAt) 确认）。只作倾向参考；必须结合当天内容，不能单凭应用名推断这次活动。"
        }
    }

    /// 用户确认过的长期记忆（只取 is_confirmed = true 的覆盖记录）。
    static func confirmedMemoryLines(v2Store: V2Store, limit: Int = 8) -> [String] {
        let memories = v2Store.memories()
        guard !memories.isEmpty else { return [] }
        let confirmations = v2Store.memoryConfirmations(ids: memories.map(\.id))
        return memories
            .filter { confirmations[$0.id]?.confirmed == true }
            .sorted { $0.lastConfirmedAt ?? $0.createdAt > $1.lastConfirmedAt ?? $1.createdAt }
            .prefix(limit)
            .map { memory in
                let body = memory.body.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = body.isEmpty ? "" : "：\(String(body.prefix(120)))"
                return "- \(memory.title)\(detail)"
            }
    }

    /// 单条结果的 headline：优先 digest_json，否则正文首个有内容的行。
    static func headline(of record: V2Store.AnalysisRunRecord) -> String {
        if let json = record.digestJSON, let data = json.data(using: .utf8),
           let digest = try? JSONDecoder().decode(DailyDigest.self, from: data),
           !digest.headline.isEmpty {
            return digest.headline
        }
        return AnalysisDigestParser.fallbackHeadline(ofOutput: record.run.outputText)
    }

    // MARK: 近期结论（B2/B3 结果链）

    /// 拉取某任务在时间范围内的最新结论摘要：优先 digest_json 的 headline，
    /// 否则取输出正文的第一个有内容行。
    static func conclusionSummaries(
        v2Store: V2Store,
        task: RiverTaskKind,
        between start: Date,
        end: Date,
        limit: Int = 7
    ) -> [AnalysisConclusionSummary] {
        v2Store.analysisRunRecords(task: task, between: start, end: end)
            .suffix(limit)
            .compactMap { record in
                let headline = Self.headline(of: record)
                guard !headline.isEmpty else { return nil }
                return AnalysisConclusionSummary(
                    taskKey: task.rawValue,
                    rangeKey: record.rangeKey,
                    headline: headline,
                    createdAt: record.run.createdAt
                )
            }
    }

    // MARK: Helpers

    private static func renderLines(_ lines: [String], empty: String) -> String {
        lines.isEmpty ? empty : lines.joined(separator: "\n")
    }

    private static func stable(_ text: String) -> String {
        String(SHA256Hex.hash(Data(text.utf8)).prefix(16))
    }
}

// MARK: - 日报结构化摘要（B2）

enum AnalysisDigestParser {
    // (?s) 让 . 跨行：模型把摘要 JSON 排版成多行时同样能解析并从正文剥除。
    private static let digestPattern = "(?s)<!--\\s*digest:\\s*(\\{.*?\\})\\s*-->"

    /// 从日报答案尾部提取 `<!-- digest: {...} -->` 并把它从可见文本里剥掉。
    /// 解析失败时回退到正文首行作为 headline，答案原样保留。
    static func extract(from answer: String) -> (digest: DailyDigest, cleanAnswer: String) {
        var digest = fallbackDigest(ofOutput: answer)
        var clean = answer
        if let regex = try? NSRegularExpression(pattern: digestPattern) {
            let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            if let match = regex.firstMatch(in: answer, options: [], range: range),
               match.numberOfRanges > 1,
               let jsonRange = Range(match.range(at: 1), in: answer),
               let data = answer[jsonRange].data(using: .utf8),
               let parsed = try? JSONDecoder().decode(DailyDigest.self, from: data),
               isValid(parsed) {
                digest = clamp(parsed)
                clean = (answer as NSString).replacingCharacters(in: match.range, with: "")
            }
        }
        clean = clean
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (digest, clean)
    }

    /// 周报/月信/询问页消费摘要时的兜底 headline。
    static func fallbackHeadline(ofOutput text: String) -> String {
        let visible = EvidenceReference.displayText(from: text)
        for line in visible.components(separatedBy: .newlines) {
            let trimmed = line
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed == "结论" || trimmed == "概览" { continue }
            return String(trimmed.prefix(80))
        }
        return ""
    }

    static func stripDigestComment(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: digestPattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackDigest(ofOutput text: String) -> DailyDigest {
        DailyDigest(headline: fallbackHeadline(ofOutput: text), points: [])
    }

    private static func isValid(_ digest: DailyDigest) -> Bool {
        !digest.headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func clamp(_ digest: DailyDigest) -> DailyDigest {
        var result = digest
        result.headline = String(result.headline.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        result.points = Array(result.points
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
            .map { String($0.prefix(120)) })
        return result
    }
}

// MARK: - 记忆候选解析（C3）

/// 模型提交的记忆候选。只能成为"待确认"记忆行（isUserConfirmed = false），
/// 绝不自我确认——可靠标签只来自用户反馈或独立强证据。
struct MemoryCandidate: Hashable, Sendable {
    var title: String
    var body: String
    var kind: MemoryKind
    var evidenceRefs: [String]
}

enum MemoryCandidateParser {
    /// 允许进入长期记忆的类型；其余（如 other）不生成候选。
    private static let allowedKinds: Set<String> = [
        MemoryKind.longTermFact.rawValue,
        MemoryKind.habit.rawValue,
        MemoryKind.projectTrajectory.rawValue,
        MemoryKind.interpersonal.rawValue,
        MemoryKind.journey.rawValue,
    ]

    /// 输出里是否存在可解析的 JSON 载荷（区分"确认没有候选"与"输出坏掉"）。
    static func containsJSONPayload(_ raw: String) -> Bool {
        parsePayload(raw, allowedRefs: []) != nil
    }

    /// 解析原始 JSON 载荷（不做条目级过滤），失败返回 nil。
    static func parsePayload(_ raw: String, allowedRefs: Set<String>) -> [MemoryCandidate]? {
        struct Payload: Decodable {
            struct Candidate: Decodable {
                var title: String?
                var body: String?
                var kind: String?
                var evidence: [String]?
            }
            var candidates: [Candidate]?
        }
        // 模型偶尔会包一层代码围栏或前导文字：先找第一个 '{' 到最后一个 '}'。
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let json = String(raw[start...end])
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else { return nil }

        var seen = Set<String>()
        var result: [MemoryCandidate] = []
        for candidate in payload.candidates ?? [] {
            guard result.count < 5 else { break }
            let title = (candidate.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let body = (candidate.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard title.count >= 2, title.count <= 40, !body.isEmpty else { continue }
            guard let kindRaw = candidate.kind, allowedKinds.contains(kindRaw),
                  let kind = MemoryKind(rawValue: kindRaw) else { continue }
            let refs = EvidenceReference.sanitize(candidate.evidence ?? [], allowed: allowedRefs).kept
            let fingerprint = String(SHA256Hex.hash(Data("\(title)|\(body)".utf8)).prefix(16))
            guard seen.insert(fingerprint).inserted else { continue }
            result.append(MemoryCandidate(
                title: title,
                body: String(body.prefix(200)),
                kind: kind,
                evidenceRefs: refs
            ))
        }
        return result
    }

    static func parse(_ raw: String, allowedRefs: Set<String>, limit: Int = 3) -> [MemoryCandidate] {
        guard let all = parsePayload(raw, allowedRefs: allowedRefs) else { return [] }
        return Array(all.prefix(limit))
    }
}

// MARK: - 询问页的 AI 结论候选（B3）

@MainActor
enum AIConclusionSearch {
    /// 从近期 analysis_runs 里找与问题相关的结论：查询串的每个 2-gram
    /// （对中文足够）命中输出正文即算相关，按新到旧排序。
    static func notes(
        matching query: String,
        v2Store: V2Store,
        now: Date = Date(),
        limit: Int = 3
    ) -> [AnalysisConclusionSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let grams = bigrams(of: trimmed)
        guard !grams.isEmpty else { return [] }
        let windowStart = now.addingTimeInterval(-30 * 86_400)
        var result: [AnalysisConclusionSummary] = []
        var seenTasks = Set<String>()
        for task in [RiverTaskKind.dailyOverview, .weeklyReview, .timelineDigest] {
            let records = v2Store.analysisRunRecords(task: task, between: windowStart, end: now)
            for record in records.reversed() {
                guard result.count < limit else { break }
                let text = EvidenceReference.displayText(from: record.run.outputText)
                guard grams.contains(where: text.contains) else { continue }
                let headline = ContextAssembler.headline(of: record)
                guard !headline.isEmpty else { continue }
                let summary = AnalysisConclusionSummary(
                    taskKey: task.rawValue,
                    rangeKey: record.rangeKey,
                    headline: headline,
                    createdAt: record.run.createdAt
                )
                guard seenTasks.insert(summary.id).inserted else { continue }
                result.append(summary)
            }
            if result.count >= limit { break }
        }
        return result
    }

    private static func bigrams(of text: String) -> Set<String> {
        let characters = Array(text)
        guard characters.count >= 2 else { return [] }
        var result = Set<String>()
        for index in 0..<(characters.count - 1) {
            result.insert(String(characters[index...index + 1]))
        }
        return result
    }
}
