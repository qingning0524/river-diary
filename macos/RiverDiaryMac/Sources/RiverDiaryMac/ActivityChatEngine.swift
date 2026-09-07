import Foundation

// MARK: - Local question answering

enum ActivityChatEngine {
    static func answer(_ question: String, range: FusedRangeStats, scopeLabel: String? = nil) -> ActivityAnswer {
        let lower = question.lowercased()
        let label = scopeLabel ?? "当前范围"

        if lower.contains("睡眠") || lower.contains("入睡") || lower.contains("失眠") || lower.contains("熬夜") {
            return ActivityAnswer(
                summary: "睡眠属于身体状态卡片的结构化/文字线索，足迹统计暂不把睡眠折算成应用使用时长。",
                filters: [label, "睡眠"],
                sessions: []
            )
        }

        if lower.contains("步数") || lower.contains("运动") || lower.contains("走路") || lower.contains("距离") || lower.contains("热量") {
            return ActivityAnswer(
                summary: "累计 \(range.healthSteps) 步，距离 \(String(format: "%.2f", range.healthDistance)) km，活动热量 \(String(format: "%.1f", range.healthEnergy)) kcal。",
                filters: [label, "运动", "项目管道"],
                sessions: []
            )
        }

        if lower.contains("屏幕时间") || lower.contains("总时长") || lower.contains("屏幕") {
            return ActivityAnswer(
                summary: range.pipelineTotal > 0
                    ? "\(label)的屏幕总时长约 \(ActivityFormatter.time(range.pipelineTotal))。该数值来自项目管道，不和实时片段重复相加。"
                    : "\(label)还没有项目管道屏幕总时长。",
                filters: [label, "屏幕时间", "项目管道"],
                sessions: []
            )
        }

        if lower.contains("浏览") || lower.contains("网站") {
            if range.browseUsage.isEmpty {
                return ActivityAnswer(summary: "\(label)没有浏览足迹。", filters: [label, "浏览"], sessions: [])
            }
            let top = range.browseUsage.prefix(3).map { "\($0.site) \($0.visits) 次" }.joined(separator: "、")
            return ActivityAnswer(
                summary: "\(label)浏览最频繁的是：\(top)。数据来自项目管道。",
                filters: [label, "浏览", "项目管道"],
                sessions: []
            )
        }

        if lower.contains("碎片") || lower.contains("切换") {
            return ActivityAnswer(
                summary: range.liveSessions.isEmpty
                    ? "\(label)没有实时片段，无法评估碎片度。"
                    : "\(label)的碎片度约为 \(range.fragmentation)%（0% 表示连续，100% 表示频繁切换）。实时片段共 \(range.liveSessions.count) 段。",
                filters: [label, "切换节奏", "macOS 实时"],
                sessions: Array(range.liveSessions.suffix(12))
            )
        }

        if lower.contains("最长") || lower.contains("连续") {
            if let longest = range.liveSessions.max(by: { $0.duration < $1.duration }) {
                let title = longest.windowTitle ?? longest.category
                return ActivityAnswer(
                    summary: "\(label)最长的一段实时活动是 \(longest.appName)，约 \(ActivityFormatter.time(longest.duration))。内容线索：\(title)。",
                    filters: [label, "最长片段", "macOS 实时"],
                    sessions: [longest]
                )
            }
            return ActivityAnswer(
                summary: "\(label)还没有已结束的实时片段。",
                filters: [label, "最长片段"],
                sessions: []
            )
        }

        if lower.contains("最活跃") || lower.contains("最专注") || lower.contains("几点") {
            if let peak = range.timeline.max(by: { $0.duration < $1.duration }), peak.duration > 0 {
                return ActivityAnswer(
                    summary: "\(label)最活跃的小时是 \(peak.hour) 点，累计约 \(ActivityFormatter.time(peak.duration))。主要类别：\(peak.primaryCategory.isEmpty ? "未知" : peak.primaryCategory)。",
                    filters: [label, "24 小时分布", "macOS 实时"],
                    sessions: range.liveSessions.filter { $0.hour == peak.hour }
                )
            }
            return ActivityAnswer(
                summary: "\(label)还没有可分析的小时分布。",
                filters: [label, "24 小时分布"],
                sessions: []
            )
        }

        if lower.contains("专注") {
            if range.focusSessions.isEmpty {
                return ActivityAnswer(
                    summary: "\(label)没有已结束的专注类实时片段。专注类包括工作、学习和创作。",
                    filters: [label, "专注", "macOS 实时"],
                    sessions: []
                )
            }
            let grouped = Dictionary(grouping: range.focusSessions, by: \.appName)
            let ranked = grouped
                .map { app, values in
                    UsageItem(
                        name: app,
                        duration: values.reduce(0) { $0 + $1.duration },
                        count: values.count,
                        category: values.first?.category ?? "工作",
                        source: .live
                    )
                }
                .sorted { $0.duration > $1.duration }
            let top = ranked.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }.joined(separator: "、")
            return ActivityAnswer(
                summary: "\(label)实时专注约 \(ActivityFormatter.time(range.focusTotal))。主要分布：\(top)。",
                filters: [label, "专注", "macOS 实时"],
                sessions: Array(range.focusSessions.suffix(12))
            )
        }

        if let category = categoryMention(in: lower), let item = range.categoryUsage.first(where: { $0.name == category }) {
            return ActivityAnswer(
                summary: "\(label)的「\(category)」类活动约 \(ActivityFormatter.time(item.duration))。数据来源：\(item.source.label)。",
                filters: [label, category],
                sessions: range.liveSessions.filter { $0.category == category }
            )
        }

        if lower.contains("做了什么") || lower.contains("干什么") || lower.contains("活动") {
            if range.appUsage.isEmpty {
                return ActivityAnswer(
                    summary: "\(label)还没有可回答的应用活动数据。",
                    filters: [label],
                    sessions: []
                )
            }
            let top = range.appUsage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }.joined(separator: "、")
            let browse = range.browseUsage.first.map { "浏览上最频繁的是 \($0.site)，共 \($0.visits) 次。" } ?? ""
            return ActivityAnswer(
                summary: "\(label)主要活动是：\(top)。\(browse)",
                filters: [label, "应用排行"],
                sessions: Array(range.liveSessions.suffix(12))
            )
        }

        if let app = mentionedApp(in: lower, range: range) {
            let related = range.liveSessions.filter {
                ActivityClassifier.identity(appName: $0.appName, bundleID: $0.bundleID) == ActivityClassifier.identity(appName: app.name)
            }
            let latest = related.last
            let latestText = latest.map { "最近一段从 \($0.start.formatted(date: .omitted, time: .shortened)) 开始，约 \(ActivityFormatter.time($0.duration))。" } ?? "没有已结束的实时片段，或片段需要等应用切换后保存。"
            return ActivityAnswer(
                summary: "\(label)使用 \(app.name) 约 \(ActivityFormatter.time(app.duration))，出现在 \(app.count) 天。数据来源：\(app.source.label)。\(latestText)",
                filters: [label, app.name, app.source.label],
                sessions: Array(related.suffix(12))
            )
        }

        return ActivityAnswer(
            summary: range.narrative,
            filters: [label],
            sessions: Array(range.liveSessions.suffix(12))
        )
    }

    private static func mentionedApp(in lower: String, range: FusedRangeStats) -> UsageItem? {
        let direct = range.appUsage.filter { lower.contains($0.name.lowercased()) }
            .max { $0.duration < $1.duration }
        if direct != nil { return direct }

        let aliases: [String: String] = [
            "chrome": "chrome", "谷歌浏览器": "chrome", "googlechrome": "chrome",
            "微信": "wechat", "wechat": "wechat",
            "xcode": "xcode", "codex": "codex", "terminal": "terminal", "iterm": "iterm",
            "b站": "bilibili", "哔哩哔哩": "bilibili", "bilibili": "bilibili",
            "网易云": "netease", "网易云音乐": "netease", "spotify": "spotify",
            "notion": "notion", "word": "word", "美图": "mtxx", "mtxx": "mtxx"
        ]

        for (needle, key) in aliases where lower.contains(needle) {
            if let item = range.appUsage.first(where: {
                ActivityClassifier.identity(appName: $0.name) == key
            }) {
                return item
            }
        }

        return nil
    }

    private static func categoryMention(in lower: String) -> String? {
        if lower.contains("工作") { return "工作" }
        if lower.contains("学习") { return "学习" }
        if lower.contains("创作") { return "创作" }
        if lower.contains("娱乐") { return "娱乐" }
        if lower.contains("沟通") || lower.contains("社交") { return "沟通" }
        if lower.contains("浏览") { return "浏览" }
        if lower.contains("系统") { return "系统" }
        return nil
    }
}
