import Foundation

struct MemoryNote: Identifiable, Hashable {
    let id: String
    let date: String
    let text: String
    let tags: [String]
    let signal: String?
    let score: Int
}

struct MemoryAnswer {
    let summary: String
    let entries: [DiaryEntry]
    let notes: [MemoryNote]
    let matchedCaptures: [QuickCapture]
    var manualNotes: [MemoryNote] = []
    let usedFilters: [String]
    let memories: [Memory]
    let reflections: [MonthlyLetter]

    init(summary: String, entries: [DiaryEntry], notes: [MemoryNote], usedFilters: [String], memories: [Memory] = [], reflections: [MonthlyLetter] = [], matchedCaptures: [QuickCapture] = [], manualNotes: [MemoryNote] = []) {
        self.summary = summary
        self.entries = entries
        self.notes = notes
        self.matchedCaptures = matchedCaptures
        self.manualNotes = manualNotes
        self.usedFilters = usedFilters
        self.memories = memories
        self.reflections = reflections
    }
}

/// The single bounded candidate set shared by local Ask, the AI prompt,
/// the evidence inspector, and the V2 context snapshot.
struct AskCandidateSet {
    let entries: [DiaryEntry]
    let captures: [QuickCapture]
    let memories: [Memory]
    let reflections: [MonthlyLetter]
    let manualNotes: [MemoryNote]

    static func make(
        from answer: MemoryAnswer,
        entryLimit: Int = 24,
        captureLimit: Int = 12,
        memoryLimit: Int = 12,
        reflectionLimit: Int = 12,
        manualNoteLimit: Int = 24
    ) -> AskCandidateSet {
        let selectedEntries = Array(answer.entries.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }.prefix(entryLimit))
        let selectedCaptures = Array(answer.matchedCaptures.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt < rhs.createdAt
        }.prefix(captureLimit))
        let selectedMemories = Array(answer.memories.sorted { $0.createdAt > $1.createdAt }.prefix(memoryLimit))
        let selectedReflections = Array(answer.reflections.sorted { $0.updatedAt > $1.updatedAt }.prefix(reflectionLimit))
        let selectedManualNotes = Array(answer.manualNotes.sorted { lhs, rhs in
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date
        }.prefix(manualNoteLimit))
        return AskCandidateSet(
            entries: selectedEntries,
            captures: selectedCaptures,
            memories: selectedMemories,
            reflections: selectedReflections,
            manualNotes: selectedManualNotes
        )
    }
}

enum AskCandidateContextFormatter {
    static func manualNotes(_ notes: [MemoryNote]) -> String {
        guard !notes.isEmpty else { return "- 无" }
        return notes.map { note in
            let source = note.tags.isEmpty ? "用户标注" : note.tags.joined(separator: "、")
            return "- \(note.date) · 来源：\(source) · \(note.text)"
        }.joined(separator: "\n")
    }

    static func manualNoteReferences(_ notes: [MemoryNote]) -> [[String: String]] {
        notes.map { note in
            [
                "id": note.id,
                "date": note.date,
                "kind": note.tags.contains("每日目标") ? "goal" : "timeline_annotation"
            ]
        }
    }
}

struct AskEvidence: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case diary = "日记"
        case capture = "快记"
        case memory = "长期记忆"
        case reflection = "河流信"
        case timeline = "时间线"
        case goal = "每日目标"
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let date: Date?
    let episodes: [Episode]
}

struct AISearchDateReference: Identifiable, Hashable {
    let id: String
    let date: String
    let title: String
    let detail: String
    let source: String
    let score: Int?
}

enum AISearchDateReferenceParser {
    static func references(
        from answer: String,
        entries: [DiaryEntry],
        quickCaptures: [QuickCapture]
    ) -> [AISearchDateReference] {
        guard let regex = try? NSRegularExpression(pattern: "\\b\\d{4}-\\d{2}-\\d{2}\\b") else { return [] }
        let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
        var dates: [String] = []
        for match in regex.matches(in: answer, range: range) {
            guard let swiftRange = Range(match.range, in: answer) else { continue }
            let date = String(answer[swiftRange])
            if !dates.contains(date) { dates.append(date) }
        }

        return dates.compactMap { date in
            if let entry = entries.first(where: { $0.date == date }) {
                return AISearchDateReference(
                    id: "entry-\(date)", date: date, title: entry.shortDate,
                    detail: entry.displayOverview.isEmpty ? "这一天没有留下文字。" : entry.displayOverview,
                    source: "日记", score: entry.overall
                )
            }
            let captures = quickCaptures.filter { DiaryEntry.dateFormatter.string(from: $0.createdAt) == date }
            guard !captures.isEmpty else { return nil }
            return AISearchDateReference(
                id: "capture-\(date)", date: date, title: date,
                detail: captures.map(\.text).joined(separator: " · "), source: "快记", score: nil
            )
        }
    }
}

enum MemorySearchEngine {
    private struct Scope {
        let interval: DateInterval
        let label: String

        func contains(_ date: Date) -> Bool {
            date >= interval.start && date < interval.end
        }

        func overlaps(start: Date, end: Date) -> Bool {
            end > interval.start && start < interval.end
        }
    }

    static func search(
        _ rawQuery: String,
        entries: [DiaryEntry],
        quickCaptures: [QuickCapture] = [],
        memories: [Memory] = [],
        reflections: [MonthlyLetter] = [],
        sourceEpisodes: [String: [Episode]] = [:],
        timelineAnnotations: [String: TimelineAnnotation] = [:],
        sessions: [ActivitySession] = [],
        referenceDate: Date = Date(),
        dailyGoals: [String: DailyGoal] = [:]
    ) -> MemoryAnswer {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        var filtered = entries
        var filteredCaptures = quickCaptures
        var captureNotes = quickCaptures.map { capture in
            MemoryNote(
                id: capture.id.uuidString,
                date: DiaryEntry.dateFormatter.string(from: capture.createdAt),
                text: capture.text,
                tags: [capture.source],
                signal: nil,
                score: 0
            )
        }
        var filters: [String] = []

        let scope = makeScope(lower, referenceDate: referenceDate)
        if let scope {
            filtered = entries.filter { entry in
                guard let date = entry.entryDate else { return false }
                return scope.contains(date)
            }
            captureNotes = captureNotes.filter { note in
                guard let date = DiaryEntry.dateFormatter.date(from: note.date) else { return false }
                return scope.contains(date)
            }
            filteredCaptures = filteredCaptures.filter { scope.contains($0.createdAt) }
            filters.append(scope.label)
        }

        if let number = extractNumber(lower, words: ["低于", "小于", "低过"]) {
            filtered = filtered.filter { $0.overall < number }
            filters.append("综合低于 \(number)")
        } else if let number = extractNumber(lower, words: ["高于", "大于", "超过"]) {
            filtered = filtered.filter { $0.overall > number }
            filters.append("综合高于 \(number)")
        }

        let topicWords = normalizedTopicWords(from: query)
        let annotations = makeManualNotes(
            sessions: sessions,
            annotations: timelineAnnotations,
            scope: scope,
            topicWords: topicWords
        )
        let goals = makeGoalNotes(dailyGoals: dailyGoals, scope: scope, topicWords: topicWords)
        let manualNotes = annotations + goals

        let matchedMemories = memories.filter { memory in
            if let scope {
                let episodes = sourceEpisodes[memory.id.uuidString] ?? []
                if episodes.isEmpty {
                    guard scope.contains(memory.createdAt) else { return false }
                } else {
                    guard episodes.contains(where: { scope.overlaps(start: $0.startTime, end: $0.endTime) }) else { return false }
                }
            }
            let haystack = [memory.title, memory.body, memory.kind.rawValue, memory.kind.displayName].joined(separator: " ")
            let matchesTopic = topicWords.contains { word in
                haystack.localizedCaseInsensitiveContains(word)
            }
            return query.isEmpty || topicWords.isEmpty || matchesTopic
        }
        let matchedReflections = reflections.filter { reflection in
            if let scope {
                guard let monthDate = monthStart(reflection.month),
                      let monthInterval = Calendar.current.dateInterval(of: .month, for: monthDate) else { return false }
                if monthInterval.end <= scope.interval.start || monthInterval.start >= scope.interval.end {
                    return false
                }
            }
            let haystack = [reflection.title, reflection.body, reflection.evidence].joined(separator: " ")
            let matchesTopic = topicWords.contains { word in
                haystack.localizedCaseInsensitiveContains(word)
            }
            return query.isEmpty || topicWords.isEmpty || matchesTopic
        }

        if !topicWords.isEmpty {
            filtered = filtered.filter { entry in
                let haystack = searchableText(entry)
                return topicWords.contains { haystack.localizedCaseInsensitiveContains($0) }
            }
            captureNotes = captureNotes.filter { note in
                topicWords.contains { note.text.localizedCaseInsensitiveContains($0) }
            }
            filteredCaptures = filteredCaptures.filter { capture in
                topicWords.contains { capture.text.localizedCaseInsensitiveContains($0) }
            }
            filters.append("主题：\(topicWords.prefix(3).joined(separator: " / "))")
        }

        if filtered.isEmpty && captureNotes.isEmpty && manualNotes.isEmpty && matchedMemories.isEmpty && matchedReflections.isEmpty {
            return MemoryAnswer(
                summary: "没有找到完全匹配的记录。换个关键词，或看看最近 90 天。",
                entries: [],
                notes: [],
                usedFilters: filters,
                matchedCaptures: filteredCaptures
            )
        }

        let notes = makeNotes(from: filtered) + captureNotes.sorted { $0.date > $1.date } + manualNotes
        let average = filtered.map(\.overall).reduce(0, +) / max(filtered.count, 1)
        let signals = MoodAnalyzer.frequentSignals(entries: filtered, limit: 2).map(\.word)
        let signalText = signals.isEmpty ? "没有稳定重复的情绪词" : "常出现「\(signals.joined(separator: "、"))」"
        var summary: String
        if filtered.isEmpty {
            var foundSources: [String] = []
            if !captureNotes.isEmpty { foundSources.append("\(captureNotes.count) 条快记") }
            if !manualNotes.isEmpty { foundSources.append("\(manualNotes.count) 条人工补充证据") }
            if !matchedMemories.isEmpty { foundSources.append("\(matchedMemories.count) 条长期记忆") }
            if !matchedReflections.isEmpty { foundSources.append("\(matchedReflections.count) 封河流信") }
            summary = foundSources.isEmpty
                ? "没有找到完全匹配的记录。换个关键词，或看看最近 90 天。"
                : "找到\(foundSources.joined(separator: "、" ) )，没有匹配的日记。"
        } else {
            summary = "找到 \(filtered.count) 天记录，平均 \(average) 分，\(signalText)。"
        }
        if !filtered.isEmpty, !matchedMemories.isEmpty { summary += " 另外找到 \(matchedMemories.count) 条长期记忆。" }
        if !filtered.isEmpty, !matchedReflections.isEmpty { summary += " 另外找到 \(matchedReflections.count) 封河流信。" }
        if !filtered.isEmpty, !manualNotes.isEmpty { summary += " 另外找到 \(manualNotes.count) 条人工补充的地点、活动或目标。" }

        return MemoryAnswer(
            summary: summary,
            entries: filtered,
            notes: Array(notes.prefix(12)),
            usedFilters: filters,
            memories: matchedMemories,
            reflections: matchedReflections,
            matchedCaptures: filteredCaptures,
            manualNotes: manualNotes
        )
    }

    private static func normalizedTopicWords(from query: String) -> [String] {
        // Chinese queries usually do not contain whitespace. Prefer known
        // product-domain terms found within the sentence before falling back
        // to whitespace tokenization (e.g. “哪天去了图书馆” -> 图书馆).
        let knownTerms = ["图书馆", "咖啡馆", "办公室", "学校", "家", "目标", "学习", "工作", "娱乐", "沟通", "通勤"]
        let embeddedTerms = knownTerms.filter { query.localizedCaseInsensitiveContains($0) }
        if !embeddedTerms.isEmpty { return embeddedTerms }

        // Remove range/threshold phrases first, then strip common question
        // scaffolding so “本月提到工作了吗？” becomes “工作”.
        var text = query.replacingOccurrences(
            of: "(\\d{4}-\\d{2}-\\d{2}|这一天|当天|今天|昨天|前天|本周|这周|上周|本月|这个月|最近\\s*\\d+\\s*天|最近|低于\\s*\\d+|小于\\s*\\d+|低过\\s*\\d+|高于\\s*\\d+|大于\\s*\\d+|超过\\s*\\d+)",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(有哪几天|哪几天|哪些天|哪天|去了|去过|去到|去|待在|待了|在哪里|到哪里|提到|有没有|是否|了吗|吗|的|记录|看看|找出|什么|主要|做了|做什么)",
            with: " ",
            options: .regularExpression
        )

        let rawWords = text
            .split(whereSeparator: { character in
                character.isWhitespace || "，。！？?！、：:；;（）()\"“”".contains(character)
            })
            .map(String.init)
            .filter { $0.count >= 2 }

        var words: [String] = []
        for word in rawWords {
            let normalized: String
            switch word {
            case "很累", "累", "疲劳", "疲倦", "困倦", "无力": normalized = "疲惫"
            case "安静", "稳定", "放松": normalized = "平静"
            default: normalized = word
            }
            if !words.contains(normalized) { words.append(normalized) }
        }
        return words
    }

    private static func searchableText(_ entry: DiaryEntry) -> String {
        ([entry.displayOverview, entry.daily ?? ""]
         + (entry.thoughts ?? [])
         + (entry.memos ?? [])
         + (entry.tags ?? [])
         + MoodAnalyzer.reading(for: entry.displayOverview).signals.map(\.word)
        ).joined(separator: "\n")
    }

    private static func makeScope(_ query: String, referenceDate: Date) -> Scope? {
        let calendar = Calendar.current
        if query.contains("这一天") || query.contains("当天") {
            guard let interval = calendar.dateInterval(of: .day, for: referenceDate) else { return nil }
            return Scope(interval: interval, label: "所选日期")
        }
        if query.contains("今天") {
            guard let interval = calendar.dateInterval(of: .day, for: referenceDate) else { return nil }
            return Scope(interval: interval, label: calendar.isDateInToday(referenceDate) ? "今天" : "所选日期")
        }
        if query.contains("昨天") {
            let date = calendar.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
            guard let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
            return Scope(interval: interval, label: "昨天")
        }
        if query.contains("前天") {
            let date = calendar.date(byAdding: .day, value: -2, to: referenceDate) ?? referenceDate
            guard let interval = calendar.dateInterval(of: .day, for: date) else { return nil }
            return Scope(interval: interval, label: "前天")
        }
        if query.contains("本周") || query.contains("这周") {
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else { return nil }
            return Scope(interval: interval, label: "本周")
        }
        if query.contains("上周") {
            let previous = calendar.date(byAdding: .day, value: -7, to: referenceDate) ?? referenceDate
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: previous) else { return nil }
            return Scope(interval: interval, label: "上周")
        }
        if query.contains("本月") || query.contains("这个月") {
            guard let interval = calendar.dateInterval(of: .month, for: referenceDate) else { return nil }
            return Scope(interval: interval, label: "本月")
        }
        if let days = extractRecentDays(query) {
            let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -days + 1, to: referenceDate) ?? referenceDate)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate)) ?? referenceDate
            return Scope(interval: DateInterval(start: start, end: end), label: "最近 \(days) 天")
        }
        if let range = extractDateRange(query),
           let start = DiaryEntry.dateFormatter.date(from: range.start),
           let endDate = DiaryEntry.dateFormatter.date(from: range.end),
           let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) {
            return Scope(interval: DateInterval(start: calendar.startOfDay(for: start), end: end), label: "\(range.start) – \(range.end)")
        }
        if let explicitDate = extractDate(query), let date = DiaryEntry.dateFormatter.date(from: explicitDate),
           let interval = calendar.dateInterval(of: .day, for: date) {
            return Scope(interval: interval, label: explicitDate)
        }
        if let month = extractMonth(query), let date = monthStart(month),
           let interval = calendar.dateInterval(of: .month, for: date) {
            return Scope(interval: interval, label: month)
        }
        return nil
    }

    private static func monthStart(_ month: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: month + "-01")
    }

    private static func makeNotes(from entries: [DiaryEntry]) -> [MemoryNote] {
        entries.flatMap { entry -> [MemoryNote] in
            let reading = MoodAnalyzer.reading(for: entry.displayOverview)
            let texts = ([entry.displayOverview] + (entry.thoughts ?? []) + (entry.memos ?? []))
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

            return texts.enumerated().map { index, text in
                MemoryNote(
                    id: entry.id + "-note-\(index)",
                    date: entry.date,
                    text: text,
                    tags: entry.tags ?? [],
                    signal: reading.signals.first?.word,
                    score: entry.overall
                )
            }
        }
    }

    private static func makeManualNotes(
        sessions: [ActivitySession],
        annotations: [String: TimelineAnnotation],
        scope: Scope?,
        topicWords: [String]
    ) -> [MemoryNote] {
        var seen = Set<String>()
        return sessions.compactMap { session in
            let key = TimelineAnnotation.key(for: session)
            guard let annotation = annotations[key]?.normalized else { return nil }
            let text = [annotation.placeName, annotation.activityLabel, annotation.title, annotation.note]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            guard !text.isEmpty else { return nil }
            if let scope, !scope.contains(session.start) { return nil }
            if !topicWords.isEmpty && !topicWords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                return nil
            }
            let id = "timeline-annotation-\(key)"
            guard seen.insert(id).inserted else { return nil }
            return MemoryNote(
                id: id,
                date: session.dayKey,
                text: text,
                tags: ["时间线标注", annotation.placeName].filter { !$0.isEmpty },
                signal: annotation.activityLabel.isEmpty ? nil : annotation.activityLabel,
                score: 0
            )
        }
    }

    private static func makeGoalNotes(
        dailyGoals: [String: DailyGoal],
        scope: Scope?,
        topicWords: [String]
    ) -> [MemoryNote] {
        dailyGoals.compactMap { date, goal in
            guard let day = DiaryEntry.dateFormatter.date(from: date) else { return nil }
            if let scope, !scope.contains(day) { return nil }
            let status = goal.isCompleted ? "已由用户确认完成" : "进行中"
            let text = "每日目标：\(goal.title) · \(status)"
            if !topicWords.isEmpty && !topicWords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                return nil
            }
            return MemoryNote(
                id: "goal-\(date)",
                date: date,
                text: text,
                tags: ["每日目标"],
                signal: "目标",
                score: 0
            )
        }
    }

    private static func extractRecentDays(_ query: String) -> Int? {
        if let range = query.range(of: "最近\\s*(\\d+)\\s*天", options: .regularExpression) {
            let text = String(query[range]).replacingOccurrences(of: "最近", with: "").replacingOccurrences(of: "天", with: "")
            if let value = Int(text.trimmingCharacters(in: .whitespaces)), value > 0 {
                return min(value, 365)
            }
        }
        if query.contains("最近7") || query.contains("最近 7") || query.contains("一周") { return 7 }
        if query.contains("最近30") || query.contains("最近 30") || query.contains("一个月") { return 30 }
        if query.contains("最近90") || query.contains("最近 90") || query.contains("三个月") { return 90 }
        if query.contains("最近") { return 7 }
        return nil
    }

    private static func extractDate(_ query: String) -> String? {
        guard let match = query.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) else { return nil }
        return String(query[match])
    }

    private static func extractDateRange(_ query: String) -> (start: String, end: String)? {
        let pattern = "(\\d{4}-\\d{2}-\\d{2})\\s*(?:到|至|—|~)\\s*(\\d{4}-\\d{2}-\\d{2})"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: query, range: NSRange(query.startIndex..<query.endIndex, in: query)),
              let first = Range(match.range(at: 1), in: query),
              let second = Range(match.range(at: 2), in: query) else { return nil }
        return (String(query[first]), String(query[second]))
    }

    private static func extractMonth(_ query: String) -> String? {
        if let match = query.range(of: "\\d{4}-\\d{2}", options: .regularExpression) {
            return String(query[match])
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if let match = query.range(of: "\\d{1,2}月", options: .regularExpression) {
            let monthText = String(query[match]).replacingOccurrences(of: "月", with: "")
            guard let month = Int(monthText) else { return nil }
            return "\(Calendar.current.component(.year, from: Date()))-\(String(format: "%02d", month))"
        }

        return nil
    }

    private static func extractNumber(_ query: String, words: [String]) -> Int? {
        for word in words {
            if let range = query.range(of: word) {
                let tail = query[range.upperBound...].prefix(4)
                let digits = tail.prefix { $0.isNumber }
                if let number = Int(digits) { return number }
            }
        }
        return nil
    }
}

enum AskQuestionIntent {
    private static let knownPlaces = ["图书馆", "咖啡馆", "办公室", "学校", "公司", "家里", "回家", "在家"]

    static func asksAboutKnownPlace(_ query: String) -> Bool {
        knownPlaces.contains { query.localizedCaseInsensitiveContains($0) }
            || ["地点", "位置", "哪里", "去哪"].contains { query.localizedCaseInsensitiveContains($0) }
    }
}

extension Array where Element == DiaryEntry {
    func inDateRange(_ range: ClosedRange<Date>) -> [DiaryEntry] {
        filter { entry in
            guard let date = entry.entryDate else { return false }
            return range.contains(date)
        }
    }
}
