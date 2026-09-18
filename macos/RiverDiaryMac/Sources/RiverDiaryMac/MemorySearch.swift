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
    let usedFilters: [String]
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
    static func search(
        _ rawQuery: String,
        entries: [DiaryEntry],
        quickCaptures: [QuickCapture] = []
    ) -> MemoryAnswer {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()
        var filtered = entries
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

        if lower.contains("今天") {
            let day = DiaryEntry.dateFormatter.string(from: Date())
            filtered = entries.filter { $0.date == day }
            captureNotes = captureNotes.filter { $0.date == day }
            filters.append("今天")
        } else if lower.contains("昨天") {
            let day = DiaryEntry.dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date())
            filtered = entries.filter { $0.date == day }
            captureNotes = captureNotes.filter { $0.date == day }
            filters.append("昨天")
        } else if lower.contains("前天") {
            let day = DiaryEntry.dateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date())
            filtered = entries.filter { $0.date == day }
            captureNotes = captureNotes.filter { $0.date == day }
            filters.append("前天")
        } else if lower.contains("上周") {
            let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date().addingTimeInterval(-7 * 86400))
            if let start = week?.start, let end = week?.end {
                // 上周是半开区间：包含 start，不包含本周 start，避免周日 00:00 被同时算进上周和今天。
                filtered = entries.filter { entry in
                    guard let date = entry.entryDate else { return false }
                    return date >= start && date < end
                }
                captureNotes = captureNotes.filter { note in
                    guard let date = DiaryEntry.dateFormatter.date(from: note.date) else { return false }
                    return date >= start && date < end
                }
                filters.append("上周")
            }
        } else if lower.contains("本月") || lower.contains("这个月") {
            let month = Calendar.current.dateInterval(of: .month, for: Date())
            if let start = month?.start, let end = month?.end {
                // 上周是半开区间：包含 start，不包含本周 start，避免周日 00:00 被同时算进上周和今天。
                filtered = entries.filter { entry in
                    guard let date = entry.entryDate else { return false }
                    return date >= start && date < end
                }
                captureNotes = captureNotes.filter { note in
                    guard let date = DiaryEntry.dateFormatter.date(from: note.date) else { return false }
                    return date >= start && date < end
                }
                filters.append("本月")
            }
        } else if let days = extractRecentDays(lower) {
            filtered = Array(entries.suffix(days))
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            captureNotes = captureNotes.filter { note in
                guard let date = DiaryEntry.dateFormatter.date(from: note.date) else { return false }
                return date >= cutoff
            }
            filters.append("最近 \(days) 天")
        } else if let explicitDate = extractDate(lower) {
            filtered = entries.filter { $0.date == explicitDate }
            captureNotes = captureNotes.filter { $0.date == explicitDate }
            filters.append(explicitDate)
        } else if let month = extractMonth(lower) {
            filtered = entries.filter { $0.date.hasPrefix(month) }
            captureNotes = captureNotes.filter { $0.date.hasPrefix(month) }
            filters.append(month)
        }

        if let number = extractNumber(lower, words: ["低于", "小于", "低过"]) {
            filtered = filtered.filter { $0.overall < number }
            filters.append("综合低于 \(number)")
        } else if let number = extractNumber(lower, words: ["高于", "大于", "超过"]) {
            filtered = filtered.filter { $0.overall > number }
            filters.append("综合高于 \(number)")
        }

        let topicWords = normalizedTopicWords(from: query)

        if !topicWords.isEmpty {
            filtered = filtered.filter { entry in
                let haystack = searchableText(entry)
                return topicWords.contains { haystack.localizedCaseInsensitiveContains($0) }
            }
            captureNotes = captureNotes.filter { note in
                topicWords.contains { note.text.localizedCaseInsensitiveContains($0) }
            }
            filters.append("主题：\(topicWords.prefix(3).joined(separator: " / "))")
        }

        if filtered.isEmpty && captureNotes.isEmpty {
            return MemoryAnswer(
                summary: "没有找到完全匹配的记录。换个关键词，或看看最近 90 天。",
                entries: [],
                notes: [],
                usedFilters: filters
            )
        }

        let notes = makeNotes(from: filtered) + captureNotes.sorted { $0.date > $1.date }
        let average = filtered.map(\.overall).reduce(0, +) / max(filtered.count, 1)
        let signals = MoodAnalyzer.frequentSignals(entries: filtered, limit: 2).map(\.word)
        let signalText = signals.isEmpty ? "没有稳定重复的情绪词" : "常出现「\(signals.joined(separator: "、"))」"
        let summary = filtered.isEmpty
            ? "找到 \(captureNotes.count) 条快记，没有匹配的日记。"
            : "找到 \(filtered.count) 天记录，平均 \(average) 分，\(signalText)。"

        return MemoryAnswer(
            summary: summary,
            entries: filtered,
            notes: Array(notes.prefix(12)),
            usedFilters: filters
        )
    }

    private static func normalizedTopicWords(from query: String) -> [String] {
        // Remove range/threshold phrases first, then strip common question
        // scaffolding so “本月提到工作了吗？” becomes “工作”.
        var text = query.replacingOccurrences(
            of: "(今天|昨天|前天|本周|上周|本月|这个月|最近\\s*\\d+\\s*天|最近|低于\\s*\\d+|小于\\s*\\d+|低过\\s*\\d+|高于\\s*\\d+|大于\\s*\\d+|超过\\s*\\d+)",
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(有哪几天|哪几天|哪些天|哪天|提到|有没有|是否|了吗|吗|的|记录|看看|找出|什么)",
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

    private static func extractRecentDays(_ query: String) -> Int? {
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

extension Array where Element == DiaryEntry {
    func inDateRange(_ range: ClosedRange<Date>) -> [DiaryEntry] {
        filter { entry in
            guard let date = entry.entryDate else { return false }
            return range.contains(date)
        }
    }
}
