import Foundation

struct MemoryArchiveDay: Identifiable, Hashable {
    var id: String { entry.date }
    var entry: DiaryEntry
    var captures: [QuickCapture]
    var hasWriting: Bool { !entry.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// 预览是给人扫一眼的：把 Markdown 源标记剥掉（链接、加粗、标题等），
    /// 否则 `[文字](url)` 会原样出现在列表里。
    var preview: String {
        let raw = hasWriting ? entry.displayOverview : captures.first?.text ?? "这一天，留下一些生活线索。"
        return Self.flattenMarkdown(raw)
    }

    static func flattenMarkdown(_ text: String) -> String {
        var result = text
        // 图片整段去掉：![alt](url) → ""
        result = result.replacingOccurrences(
            of: "!\\[([^\\]]*)\\]\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )
        // 链接只留文字：[text](url) → text
        result = result.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)",
            with: "$1",
            options: .regularExpression
        )
        // 行内标记：加粗/代码/删除线。单字符的斜体标记（*、_）不动——
        // 正文里的 "a_b"、"3*4" 会被误伤，宁可偶尔留下斜体星号。
        for marker in ["**", "__", "`", "~~"] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        // 标题与引用行首符
        result = result.replacingOccurrences(
            of: "^#{1,6}\\s*|^>\\s*",
            with: "",
            options: .regularExpression
        )
        // 压缩被剥出来的多余空白
        result = result.replacingOccurrences(
            of: "\\s{2,}",
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var mood: Double? { entry.metrics?.mood ?? entry.score }
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let text = ([entry.date, entry.displayOverview, entry.category ?? ""] + (entry.tags ?? []) + (entry.thoughts ?? []) + (entry.memos ?? []) + captures.map(\.text)).joined(separator: " ")
        return text.localizedStandardContains(needle)
    }
}

enum MemoryArchive {
    static func days(entries: [DiaryEntry], captures: [String: [QuickCapture]]) -> [MemoryArchiveDay] {
        var byDate = entries.reduce(into: [String: DiaryEntry]()) { $0[$1.date] = $1 }
        for (date, values) in captures where !values.isEmpty && byDate[date] == nil {
            guard DiaryEntry.dateFormatter.date(from: date) != nil else { continue }
            byDate[date] = DiaryEntry(pageID: "local-\(date)", date: date)
        }
        return byDate.values.map {
            MemoryArchiveDay(entry: $0, captures: QuickCapture.sortedForDisplay(captures[$0.date] ?? []))
        }.sorted { $0.id > $1.id }
    }
}
