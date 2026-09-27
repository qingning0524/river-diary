import Foundation

struct MoodSignal: Identifiable, Hashable {
    let word: String
    let count: Int
    var id: String { word }
}

struct MoodReading: Hashable {
    let title: String
    let summary: String
    let signals: [MoodSignal]
    let score: Int
}

/// 单字关键词（累/困/倦）的子串计数会被常见复合词误触发：
/// 「积累了不少经验」「遇到了一点困难」都会被判成疲惫。计数/检索前剥掉
/// 这批高频复合词，单字关键词本身保留（"今天很累"是合法信号）。
/// MoodAnalyzer 与 CareAdvisor 共用。
private func textWithoutFalsePositiveCompounds(_ text: String) -> String {
    ["积累", "累计", "累加", "困难", "困局"].reduce(text) { result, compound in
        result.replacingOccurrences(of: compound, with: " ")
    }
}

enum MoodAnalyzer {
    private static let lexicon: [String: [String]] = [
        "平静": ["平静", "坦然", "稳定", "放松", "舒缓", "治愈", "安心", "慢慢"],
        "清醒": ["清醒", "专注", "深度", "文档", "学习", "开发", "梳理", "方案", "研究", "代码"],
        "敏感": ["回忆", "敏感", "波动", "情绪", "难受", "焦虑", "纠结", "害怕", "担心", "眼泪"],
        "疲惫": ["疲惫", "累", "熬夜", "无力", "失眠", "低落", "困", "倦"],
        "期待": ["计划", "期待", "成长", "重建", "希望", "想试", "开始", "决定", "目标"]
    ]

    static func reading(for text: String) -> MoodReading {
        var counts: [String: Int] = [:]
        let cleaned = textWithoutFalsePositiveCompounds(text)
        for (label, words) in lexicon {
            counts[label] = words.reduce(0) { total, word in
                total + cleaned.components(separatedBy: word).count - 1
            }
        }

        var unsortedSignals: [MoodSignal] = []
        for (label, count) in counts where count > 0 {
            unsortedSignals.append(MoodSignal(word: label, count: count))
        }

        let signals = unsortedSignals.sorted { lhs, rhs in
            if lhs.count == rhs.count { return lhs.word < rhs.word }
            return lhs.count > rhs.count
        }

        let title = signals.first?.word ?? "安静"
        let score = max(20, min(96, 58 + signalStrength(signals)))
        let summary = summary(title: title, text: text, signalCount: signals.reduce(0) { $0 + $1.count })
        return MoodReading(title: title, summary: summary, signals: Array(signals.prefix(4)), score: score)
    }

    static func readings(for entries: [DiaryEntry]) -> [MoodReading] {
        entries.suffix(7).reversed().map { reading(for: $0.displayOverview) }
    }

    static func frequentSignals(entries: [DiaryEntry], limit: Int = 8) -> [MoodSignal] {
        var counts: [String: Int] = [:]
        for entry in entries.suffix(30) {
            for signal in reading(for: entry.displayOverview).signals {
                counts[signal.word, default: 0] += signal.count
            }
        }

        return counts.map { MoodSignal(word: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count { return lhs.word < rhs.word }
                return lhs.count > rhs.count
            }
            .prefix(limit)
            .map { $0 }
    }

    static func matchingSignals(in text: String) -> [String] {
        lexicon.filter { words in words.value.contains { text.contains($0) } }.map(\.key).sorted()
    }

    private static func signalStrength(_ signals: [MoodSignal]) -> Int {
        guard let primary = signals.first else { return -4 }
        switch primary.word {
        case "平静", "期待": return 14
        case "清醒": return 10
        case "敏感": return -6
        case "疲惫": return -16
        default: return 0
        }
    }

    private static func summary(title: String, text: String, signalCount: Int) -> String {
        let clipped = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clipped.isEmpty else { return "暂时没有文字记录。" }
        let excerpt = clipped.count > 42 ? String(clipped.prefix(42)) + "…" : clipped
        return "「\(excerpt)」"
    }
}

enum CareAdvisor {
    static func level(entry: DiaryEntry?, previous: DiaryEntry?, quickText: String) -> CareLevel {
        let text = textWithoutFalsePositiveCompounds((entry?.displayOverview ?? "") + " " + quickText)
        let hardWords = ["撑不住", "崩溃", "没有意义", "活不下去", "害怕", "绝望", "失眠", "熬夜"]
        let softWords = ["疲惫", "累", "无力", "低落", "难受", "焦虑", "崩溃"]

        if hardWords.contains(where: text.contains) { return .support }

        // 缺分数 ≠ 低分：entry 存在但 mood/score 都为 nil 时，旧写法
        // `?? 100` 兜不住（mood 计算属性内部已经 `?? 0`），连续两天没打分
        // 会触发"建议专业支持"。只有真实打了低分才算低。
        let todayScore = entry.flatMap { $0.metrics?.mood ?? $0.score }
        let yesterdayScore = previous.flatMap { $0.metrics?.mood ?? $0.score }
        let lowToday = (todayScore.map { $0 <= 38 }) == true
        let lowYesterday = (yesterdayScore.map { $0 <= 38 }) == true
        if lowToday && lowYesterday { return .support }
        if lowToday || softWords.contains(where: text.contains) { return .gentle }
        return .none
    }

    static func title(for level: CareLevel) -> String {
        switch level {
        case .gentle: "今天可以先少记一点"
        case .support: "我看见了这几天的重量"
        case .none: ""
        }
    }

    static func message(for level: CareLevel) -> String {
        switch level {
        case .gentle: "当天内容已经整理好了。今天不必完整复盘，只确认一句也行，也可以留到明天再看。"
        case .support: "最近有些沉重的字眼，也连续出现低落。不急着总结，可以只留一句，或暂时不整理。愿意的话，和信任的人或专业支持聊聊。"
        case .none: ""
        }
    }
}

enum AIDraftEngine {
    static func compose(
        entry: DiaryEntry,
        previous: DiaryEntry?,
        quickCaptures: [QuickCapture],
        autoPaused: Bool,
        activitySessions: [ActivitySession] = []
    ) -> AIDraft {
        let sourceTexts = sourceTexts(for: entry)
        let quickTexts = quickCaptures.map(\.text)
        let activityText = ActivityDraftBridge.sourceText(sessions: activitySessions)
        let allText = (sourceTexts + quickTexts + [activityText]).joined(separator: "\n")
        let reading = MoodAnalyzer.reading(for: allText)
        let evidence = buildEvidence(entry: entry, quickCaptures: quickCaptures, activitySessions: activitySessions)
        let care = CareAdvisor.level(entry: entry, previous: previous, quickText: quickTexts.joined(separator: " "))

        if autoPaused {
            return AIDraft(
                headline: "自动整理已暂停",
                narrative: "这一天先按原文保留，没有另写一段。准备好后可以重新打开自动整理。",
                category: entry.category ?? "随想",
                tags: entry.tags ?? [],
                mood: entry.mood,
                energy: entry.energy,
                focus: entry.focus,
                output: entry.output,
                confidence: 100,
                confidenceFactors: ["自动整理已由你暂停；已有内容按原文保留。"],
                evidence: evidence,
                signals: [],
                care: care,
                isEmpty: true
            )
        }

        if sourceTexts.isEmpty && quickTexts.isEmpty && activitySessions.isEmpty {
            return AIDraft(
                headline: "记录还不多",
                narrative: "这一天还没有可读内容。可以先在菜单栏快记一句，稍后会并进草稿。",
                category: "随想",
                tags: [],
                mood: entry.mood,
                energy: entry.energy,
                focus: entry.focus,
                output: entry.output,
                confidence: 12,
                confidenceFactors: ["还没有可读内容，所以不会补写。"],
                evidence: [],
                signals: [],
                care: care,
                isEmpty: true
            )
        }

        let rawExcerpts = directExcerpts(entry: entry, quickCaptures: quickCaptures)
        let headlineSource = rawExcerpts.first
            ?? (entry.daily?.isEmpty == false ? entry.daily! : entry.displayOverview)
        let headline = headlineSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "这一天"
            : excerpt(headlineSource, limit: 18)
        let narrative = narrative(entry: entry, rawExcerpts: rawExcerpts, activitySessions: activitySessions)
        let tags = suggestTags(entry: entry, reading: reading)
        let metrics = entry.metrics
        var evidenceKinds: [String] = []
        if !entry.displayOverview.isEmpty { evidenceKinds.append("总览") }
        if !(entry.thoughts ?? []).isEmpty { evidenceKinds.append("想法") }
        if !(entry.memos ?? []).isEmpty { evidenceKinds.append("随笔") }
        if !quickCaptures.isEmpty { evidenceKinds.append("快记") }
        if entry.screenMinutes != nil { evidenceKinds.append("屏幕") }
        if entry.hasMovementSignal { evidenceKinds.append("运动") }
        if entry.metrics != nil { evidenceKinds.append("状态指标") }
        let confidenceNotes = [
            "证据类型：\(evidenceKinds.isEmpty ? "暂无" : evidenceKinds.joined(separator: "、"))",
            "实时片段：\(activitySessions.isEmpty ? "无" : "\(activitySessions.count) 段")",
            "评分只看证据覆盖，不因文字长度无限加分。"
        ]
        let confidence = draftConfidence(
            entry: entry,
            evidence: evidence,
            quickCaptures: quickCaptures,
            activitySessions: activitySessions,
            allText: allText
        )
        let activity = ActivityDraftBridge.summary(sessions: activitySessions)
        let focusFromActivity = metrics?.focus.map(Int.init) ?? (activity.totalActive > 0 ? max(24, min(92, Int(activity.focusRatio * 100))) : max(24, reading.score - 8))

        return AIDraft(
            headline: headline,
            narrative: narrative,
            category: entry.category ?? primaryCategory(for: tags),
            tags: tags,
            mood: metrics?.mood.map(Int.init) ?? reading.score,
            energy: metrics?.energy.map(Int.init) ?? max(28, reading.score - 12),
            focus: focusFromActivity,
            output: metrics?.output.map(Int.init) ?? max(22, reading.score - 14),
            confidence: confidence,
            confidenceFactors: confidenceNotes,
            evidence: evidence,
            signals: reading.signals.map(\.word),
            care: care,
            isEmpty: false
        )
    }

    private static func draftConfidence(
        entry: DiaryEntry,
        evidence: [DraftEvidence],
        quickCaptures: [QuickCapture],
        activitySessions: [ActivitySession],
        allText: String
    ) -> Int {
        // 置信度不再随文本长度或证据数量无限膨胀；只有证据类型、结构化信号和有效活动才加分。
        let substance = allText.trimmingCharacters(in: .whitespacesAndNewlines).count
        let substanceScore = Self.draftSubstanceScore(substance)

        var evidenceKinds: Set<String> = []
        if !entry.displayOverview.isEmpty { evidenceKinds.insert("overview") }
        if !(entry.thoughts ?? []).isEmpty { evidenceKinds.insert("thought") }
        if !(entry.memos ?? []).isEmpty { evidenceKinds.insert("memo") }
        if !quickCaptures.isEmpty { evidenceKinds.insert("quick") }
        if !activitySessions.isEmpty { evidenceKinds.insert("activity") }
        if entry.screenMinutes != nil { evidenceKinds.insert("screen") }
        if !(entry.browseSites ?? []).isEmpty { evidenceKinds.insert("browse") }
        if entry.health != nil { evidenceKinds.insert("health") }
        let evidenceScore = min(24, evidenceKinds.count * 5)

        let structuredScore = entry.metrics == nil ? 0 : 10
        let activeLiveMinutes = activitySessions
            .filter { $0.duration >= 60 }
            .reduce(0) { $0 + $1.duration } / 60
        let activityScore = activeLiveMinutes >= 15 ? 8 : (activeLiveMinutes >= 3 ? 4 : 0)
        let movementScore = entry.hasMovementSignal ? 4 : 0

        return min(88, 8 + substanceScore + evidenceScore + structuredScore + activityScore + movementScore)
    }

    /// 三档有效内容分：文本达到 30/120/300 字时分别累加 10/8/4 分。
    /// 三元表达式必须逐档加括号，否则会因优先级问题退化成 0/10 两档。
    static func draftSubstanceScore(_ characterCount: Int) -> Int {
        (characterCount >= 30 ? 10 : 0)
            + (characterCount >= 120 ? 8 : 0)
            + (characterCount >= 300 ? 4 : 0)
    }

    static func causes(entries: [DiaryEntry]) -> [(date: String, title: String, reason: String)] {
        guard !entries.isEmpty else { return [] }
        var causes: [(String, String, String)] = []

        if let low = entries.min(by: { ($0.mood) < ($1.mood) }), low.mood < 55 {
            causes.append((low.shortDate, "安静段", "这一段更安静，情绪 \(low.mood)。"))
        }

        if let best = entries.max(by: { ($0.focus + $0.output) < ($1.focus + $1.output) }), best.focus + best.output >= 110 {
            causes.append((best.shortDate, "活跃段", "专注 \(best.focus) · 产出 \(best.output)。"))
        }

        if let latest = entries.last {
            causes.append((latest.shortDate, "最近", "心情 \(latest.mood) 分。"))
        }

        return Array(causes.prefix(3)).map { (date: $0.0, title: $0.1, reason: $0.2) }
    }

    private static func sourceTexts(for entry: DiaryEntry) -> [String] {
        var texts = [entry.displayOverview]
        texts.append(contentsOf: entry.thoughts ?? [])
        texts.append(contentsOf: entry.memos ?? [])
        texts.append(contentsOf: (entry.didItems ?? []).flatMap { [$0.subtitle ?? ""] + ($0.items ?? []) })
        texts.append(entry.screenNote ?? "")
        texts.append(entry.browseNote ?? "")
        texts.append(contentsOf: (entry.tags ?? []).map { "标签：\($0)" })
        if let minutes = entry.screenMinutes {
            texts.append("屏幕使用 \(ActivityFormatter.time(Double(minutes) * 60))")
        }
        return texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func buildEvidence(entry: DiaryEntry, quickCaptures: [QuickCapture], activitySessions: [ActivitySession]) -> [DraftEvidence] {
        var evidence: [DraftEvidence] = []

        if !entry.displayOverview.isEmpty {
            evidence.append(DraftEvidence(id: entry.id + "-overview", title: "当天总览", detail: entry.displayOverview, source: "日记原文"))
        }

        for (index, thought) in (entry.thoughts ?? []).prefix(4).enumerated() {
            evidence.append(DraftEvidence(id: entry.id + "-thought-\(index)", title: "想法片段", detail: thought, source: "日记原文"))
        }

        for (index, memo) in (entry.memos ?? []).prefix(3).enumerated() {
            evidence.append(DraftEvidence(id: entry.id + "-memo-\(index)", title: "随手记录", detail: memo, source: "日记原文"))
        }

        for capture in quickCaptures {
            evidence.append(DraftEvidence(id: capture.id.uuidString, title: "快记", detail: capture.text, source: capture.source))
        }

        evidence.append(contentsOf: ActivityDraftBridge.evidence(sessions: activitySessions))

        if let minutes = entry.screenMinutes {
            let apps = (entry.screenApps ?? []).prefix(3).map { "\($0.app) \($0.minutes.map { ActivityFormatter.time(Double($0) * 60) } ?? $0.time ?? "")" }.joined(separator: "、")
            evidence.append(
                DraftEvidence(
                    id: entry.id + "-screen",
                    title: "屏幕时间",
                    detail: apps.isEmpty ? "总时长 \(ActivityFormatter.time(Double(minutes) * 60))" : "总时长 \(ActivityFormatter.time(Double(minutes) * 60)) · \(apps)",
                    source: "项目数据"
                )
            )
        }

        if let sites = entry.browseSites, !sites.isEmpty {
            evidence.append(
                DraftEvidence(
                    id: entry.id + "-browse",
                    title: "浏览足迹",
                    detail: sites.prefix(4).map { "\($0.site) \($0.visits ?? 0) 次" }.joined(separator: "、"),
                    source: "项目数据"
                )
            )
        }

        if let note = entry.screenNote, !note.isEmpty {
            evidence.append(DraftEvidence(id: entry.id + "-screen-note", title: "使用观察", detail: note, source: "项目数据"))
        }

        if let health = entry.health {
            evidence.append(
                DraftEvidence(
                    id: entry.id + "-health",
                    title: "运动信号",
                    detail: "步数 \(health.steps ?? 0) · 距离 \(String(format: "%.2f", health.distanceKM ?? 0)) km · 活动热量 \(String(format: "%.1f", health.activeEnergyKcal ?? 0)) kcal",
                    source: "iOS Health"
                )
            )
        }

        if let metrics = entry.metrics {
            evidence.append(
                DraftEvidence(
                    id: entry.id + "-metrics",
                    title: "状态信号",
                    detail: "心情 \(Int(metrics.mood ?? 0)) · 专注 \(Int(metrics.focus ?? 0)) · 产出 \(Int(metrics.output ?? 0)) · 精力 \(Int(metrics.energy ?? 0))",
                    source: "本机评估"
                )
            )
        }

        return Array(evidence.prefix(12))
    }

    private static func directExcerpts(entry: DiaryEntry, quickCaptures: [QuickCapture]) -> [String] {
        var items: [String] = []
        items.append(contentsOf: quickCaptures.map(\.text))
        items.append(contentsOf: entry.thoughts ?? [])
        items.append(contentsOf: entry.memos ?? [])
        for item in entry.didItems ?? [] {
            items.append(contentsOf: item.items ?? [])
        }

        return items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func excerpt(_ text: String, limit: Int) -> String {
        let clipped = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.count > limit ? String(clipped.prefix(limit)) + "…" : clipped
    }

    private static func narrative(
        entry: DiaryEntry,
        rawExcerpts: [String],
        activitySessions: [ActivitySession]
    ) -> String {
        var lines = rawExcerpts.prefix(3).map { excerpt($0, limit: 120) }

        if lines.isEmpty {
            let fallback = entry.daily?.isEmpty == false ? entry.daily! : entry.displayOverview
            if !fallback.isEmpty {
                lines.append(excerpt(fallback, limit: 160))
            }
        }

        if let activityLine = ActivityDraftBridge.narrativeLine(sessions: activitySessions) {
            lines.append(activityLine)
        } else if let minutes = entry.screenMinutes, let top = entry.screenApps?.first {
            lines.append("屏幕 \(ActivityFormatter.time(Double(minutes) * 60))，\(top.app)最多。")
        }

        if let steps = entry.health?.steps {
            lines.append("步数 \(steps)。")
        }

        return lines.joined(separator: "\n")
    }

    private static func suggestTags(entry: DiaryEntry, reading: MoodReading) -> [String] {
        var tags = Set(entry.tags ?? [])
        reading.signals.prefix(2).forEach { tags.insert($0.word) }
        return tags.sorted()
    }

    private static func primaryCategory(for tags: [String]) -> String {
        if tags.contains("工作") || tags.contains("专注") { return "工作" }
        if tags.contains("疲惫") || tags.contains("平静") { return "身心" }
        return "随想"
    }
}

enum ActivityDraftBridge {
    static func sourceText(sessions: [ActivitySession]) -> String {
        guard !sessions.isEmpty else { return "" }
        let usage = usage(sessions: sessions)
        let apps = usage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }.joined(separator: "、")
        let focus = sessions.filter { ["工作", "学习", "创作"].contains($0.category) }.reduce(0) { $0 + $1.duration }
        return "屏幕：\(apps)；专注 \(ActivityFormatter.time(focus))。"
    }

    static func narrativeLine(sessions: [ActivitySession]) -> String? {
        guard !sessions.isEmpty else { return nil }
        let usage = usage(sessions: sessions).prefix(2)
        guard let first = usage.first else { return nil }
        if usage.count > 1, let second = usage.dropFirst().first {
            return "屏幕：\(first.name)、\(second.name)。"
        }
        return "屏幕：\(first.name)。"
    }

    static func usage(sessions: [ActivitySession]) -> [UsageItem] {
        Dictionary(grouping: sessions, by: \.appName)
            .map { app, values in
                UsageItem(
                    name: app,
                    duration: values.reduce(0) { $0 + $1.duration },
                    count: values.count,
                    category: values.first?.category ?? "其他"
                )
            }
            .sorted { $0.duration > $1.duration }
    }

    static func evidence(sessions: [ActivitySession]) -> [DraftEvidence] {
        let usage = usage(sessions: sessions)
        var evidence: [DraftEvidence] = []

        for item in usage.prefix(3) {
            evidence.append(
                DraftEvidence(
                    id: "activity-app-\(item.name)",
                    title: "应用使用",
                    detail: "\(item.name) · \(item.timeText) · \(item.count) 段 · \(item.category)",
                    source: "本机足迹"
                )
            )
        }

        if let longest = sessions.max(by: { $0.duration < $1.duration }), longest.duration > 300 {
            evidence.append(
                DraftEvidence(
                    id: "activity-longest",
                    title: "最长活动",
                    detail: "\(longest.appName) · \(ActivityFormatter.time(longest.duration))\(longest.windowTitle.map { " · \($0)" } ?? "")",
                    source: "本机足迹"
                )
            )
        }

        return evidence
    }

    struct Summary {
        var totalActive: TimeInterval
        var focusRatio: Double
    }

    static func summary(sessions: [ActivitySession]) -> Summary {
        let total = sessions.reduce(0) { $0 + $1.duration }
        let focus = sessions.filter { ["工作", "学习", "创作"].contains($0.category) }.reduce(0) { $0 + $1.duration }
        return Summary(totalActive: total, focusRatio: total > 0 ? focus / total : 0)
    }
}
