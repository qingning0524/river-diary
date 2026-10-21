import Foundation

struct KindleReadResult: Equatable {
    var entries: [DailyNoteEntry]
    var issue: String?
}

/// 读取用户选择的 Kindle `My Clippings.txt`。
///
/// 只保留“今天 Added on”的划线/笔记；日期用 `NSDataDetector` 解析，
/// 避免为每个 Kindle 语言手写日期格式。无法解析日期的条目跳过，
/// 不按文件修改时间硬塞到今天。
enum KindleClippingsReader {
    static let maximumEntries = 50
    static let maximumBodyCharacters = 2_000

    static func readToday(fileURL: URL, now: Date = Date()) -> KindleReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return KindleReadResult(entries: [], issue: "Kindle clippings 文件不存在。")
        }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            return KindleReadResult(entries: [], issue: "Kindle clippings 不是可读的文本文件。")
        }

        let blocks = text.components(separatedBy: "==========")
        var entries: [DailyNoteEntry] = []
        var seen = Set<String>()
        var undated = 0

        for block in blocks {
            guard !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let entry = parseEntry(block, now: now) else {
                undated += 1
                continue
            }
            let key = "\(entry.title)|\(entry.body ?? "")|\(entry.modifiedAt.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { continue }
            entries.append(entry)
            if entries.count >= maximumEntries { break }
        }

        entries.sort { $0.modifiedAt > $1.modifiedAt }
        let issue: String?
        if !entries.isEmpty || undated == 0 {
            issue = nil
        } else {
            issue = "没有今天添加的 Kindle 划线（\(undated) 条日期无法解析或不是今天）。"
        }
        return KindleReadResult(entries: entries, issue: issue)
    }

    static func parseEntry(_ block: String, now: Date = Date()) -> DailyNoteEntry? {
        let lines = block
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let titleLine = lines.first else { return nil }
        let metadataIndex = lines.firstIndex { $0.hasPrefix("- Your ") } ?? 1
        guard metadataIndex < lines.count else { return nil }
        let metadata = lines[metadataIndex]
        guard let date = extractDate(from: metadata), Calendar.current.isDate(date, inSameDayAs: now) else {
            return nil
        }

        let body = lines.dropFirst(metadataIndex + 1).joined(separator: "\n")
        guard !body.isEmpty else { return nil }
        let title = bookTitle(from: titleLine)
        let clippedBody = body.count > maximumBodyCharacters
            ? String(body.prefix(maximumBodyCharacters)) + "\n…（正文已截断）"
            : body
        return DailyNoteEntry(
            title: title,
            body: clippedBody,
            source: "Kindle",
            modifiedAt: date
        )
    }

    static func bookTitle(from line: String) -> String {
        // Kindle 常见格式：“书名 (作者)”；只去掉末尾括号里的作者，保留书名中的括号。
        if let range = line.range(of: " (", options: .backwards), line.hasSuffix(")") {
            let title = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return line
    }

    static func extractDate(from metadata: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(metadata.startIndex..<metadata.endIndex, in: metadata)
        return detector.matches(in: metadata, range: range).last?.date
    }
}
