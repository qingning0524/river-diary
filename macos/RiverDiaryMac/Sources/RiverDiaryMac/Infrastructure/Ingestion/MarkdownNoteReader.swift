import Foundation

struct MarkdownReadResult: Equatable {
    var entries: [DailyNoteEntry]
    var issue: String?
}

/// 读取用户选择的 Markdown 文件夹（Obsidian/Logseq/Bear 导出等）。
///
/// 只读今天修改过的 `.md` / `.markdown` / `.txt`，跳过隐藏目录与常见依赖目录；
/// 不监听、不常驻，每次采集时扫一遍。文件权限来自用户主动选择的目录，
/// 不需要完全磁盘访问。
enum MarkdownNoteReader {
    static let maximumFiles = 50
    static let maximumBodyCharacters = 4_000

    private static let skippedDirectories: Set<String> = [
        ".obsidian", ".git", ".trash", "node_modules", ".build", "Library"
    ]

    static func readToday(folder: URL, now: Date = Date()) -> MarkdownReadResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return MarkdownReadResult(entries: [], issue: "已选择的 Markdown 文件夹不存在。")
        }
        guard fileManager.isReadableFile(atPath: folder.path) else {
            return MarkdownReadResult(entries: [], issue: "无法读取 Markdown 文件夹；请重新选择。")
        }

        let startOfToday = Calendar.current.startOfDay(for: now)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return MarkdownReadResult(entries: [], issue: "无法遍历 Markdown 文件夹。")
        }

        var entries: [DailyNoteEntry] = []
        var unreadable = 0
        var scanned = 0
        var truncated = false

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            guard ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) else { continue }
            guard let modifiedAt = values?.contentModificationDate, modifiedAt >= startOfToday else { continue }

            scanned += 1
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable += 1
                continue
            }
            guard let parsed = parse(text: text, fileName: url.lastPathComponent) else { continue }
            entries.append(DailyNoteEntry(
                title: parsed.title,
                body: parsed.body,
                source: "Markdown",
                modifiedAt: modifiedAt
            ))
            if entries.count >= maximumFiles {
                truncated = true
                break
            }
        }

        entries.sort { $0.modifiedAt > $1.modifiedAt }
        var issue: String?
        if unreadable > 0 {
            issue = "\(unreadable) 个 Markdown 文件不是 UTF-8 或无法读取。"
        } else if truncated {
            issue = "今天修改的 Markdown 超过 \(maximumFiles) 个，只读取最近的 \(maximumFiles) 个。"
        }
        return MarkdownReadResult(entries: entries, issue: issue)
    }

    /// 解析单个文件：优先 frontmatter 的 `title:`，其次第一个一级标题，
    /// 最后用文件名。正文去掉 frontmatter 后截断，并保留原文的换行。
    static func parse(text: String, fileName: String) -> (title: String, body: String)? {
        var content = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        content = content.replacingOccurrences(of: "\u{feff}", with: "")

        var frontMatterTitle: String?
        if content.hasPrefix("---\n"),
           let endRange = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            let frontMatter = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
            frontMatterTitle = frontMatter
                .components(separatedBy: "\n")
                .first { $0.lowercased().hasPrefix("title:") }
                .map { String($0.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            content = String(content[endRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lines = content.components(separatedBy: "\n")
        let heading = lines.first { $0.hasPrefix("# ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let fallback = (fileName as NSString).deletingPathExtension
        let title = frontMatterTitle ?? heading ?? (fallback.isEmpty ? "未命名" : fallback)

        var body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("# ") {
            body = body.components(separatedBy: "\n")
                .dropFirst()
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty || !title.isEmpty else { return nil }
        if body.count > maximumBodyCharacters {
            body = String(body.prefix(maximumBodyCharacters)) + "\n…（正文已截断）"
        }
        return (title, body)
    }
}
