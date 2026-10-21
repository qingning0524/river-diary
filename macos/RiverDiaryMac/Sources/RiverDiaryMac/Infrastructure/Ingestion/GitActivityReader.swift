import Foundation

struct GitRepoSummary: Equatable, Identifiable {
    var name: String
    var path: String
    var commits: Int

    var id: String { path }
}

struct GitActivityReadResult: Equatable {
    var repos: [GitRepoSummary]
    var issue: String?

    var totalCommits: Int { repos.reduce(0) { $0 + $1.commits } }
}

/// 读取用户选择的开发目录下本地 Git 仓库今天的提交数。
///
/// 只读仓库名和提交数量，不读 commit message、作者邮箱或改动内容；
/// 通过本机 `/usr/bin/git` 执行 `git log`，不联网、不调用托管平台 API。
enum GitActivityReader {
    static let maximumRepositories = 30
    private static let skippedDirectories: Set<String> = [
        "node_modules", "Library", ".build", "DerivedData", "Pods", "vendor"
    ]

    static func readToday(root: URL, now: Date = Date()) -> GitActivityReadResult {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return GitActivityReadResult(repos: [], issue: "已选择的代码目录不存在。")
        }
        let repositories = discoverRepositories(root: root)
        guard !repositories.isEmpty else {
            return GitActivityReadResult(repos: [], issue: "没有找到 Git 仓库。")
        }

        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? now
        var repos: [GitRepoSummary] = []
        var failed = 0

        for repository in repositories {
            guard let count = commitCount(repository: repository, since: start, until: end) else {
                failed += 1
                continue
            }
            guard count > 0 else { continue }
            repos.append(GitRepoSummary(
                name: repository.lastPathComponent,
                path: repository.path,
                commits: count
            ))
        }

        repos.sort { $0.commits > $1.commits }
        var issue: String?
        if failed > 0 {
            issue = "\(failed) 个 Git 仓库无法读取。"
        }
        return GitActivityReadResult(repos: repos, issue: issue)
    }

    static func discoverRepositories(root: URL, maximumDepth: Int = 3) -> [URL] {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.appendingPathComponent(".git").path) {
            return [root]
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let rootDepth = root.pathComponents.count
        var repositories: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if skippedDirectories.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let depth = url.pathComponents.count - rootDepth
            if depth > maximumDepth {
                enumerator.skipDescendants()
                continue
            }
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                repositories.append(url)
                enumerator.skipDescendants()
            }
            if repositories.count >= maximumRepositories { break }
        }
        return repositories
    }

    static func commitCount(repository: URL, since: Date, until: Date) -> Int? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "-C", repository.path,
            "log",
            "--since=\(formatter.string(from: since))",
            "--until=\(formatter.string(from: until))",
            "--pretty=format:%ct"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return 0 }
        return data.split(separator: 0x0a).filter { !$0.isEmpty }.count
    }
}
