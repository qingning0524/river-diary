import Foundation

// MARK: - Classifier / formatter

enum ActivityClassifier {
    /// macOS can report these system surfaces as frontmost while no user app is active.
    static func isRecordable(appName: String, bundleID: String) -> Bool {
        let name = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = bundleID.lowercased()
        let systemNames: Set<String> = ["loginwindow", "screensaverengine", "screensaver", "windowserver"]
        let systemBundles: Set<String> = ["com.apple.loginwindow", "com.apple.screensaver.engine", "com.apple.screensaver"]
        // 证据工具不记录自己：使用 River Diary 的时长属于"看仪表"，不是被观察的生活。
        //
        // 用**前缀 + 包含**匹配，而不是精确名单。原先只列了 bundle
        // `studio.riverdiary.mac` 与 "riverdiary"/"river diary"/"河流日记" 三个精确名字，
        // 于是本机数据里仍然留下了 18 条 "Legacy River Diary"
        // （`studio.riverdiary.legacy`）与 4 条 "River Timeline Preview"
        // （`studio.riverdiary.timeline-preview`）——改名或换构建配置就会漏进来。
        // 只比对 `Bundle.main` 也不够：打包运行与测试环境的宿主不同。
        let selfBundlePrefix = "studio.riverdiary"
        let selfNameFragments = ["riverdiary", "river diary", "河流日记"]
        return !systemNames.contains(name) && !systemBundles.contains(bundle)
            && !bundle.hasPrefix(selfBundlePrefix)
            && !selfNameFragments.contains(where: name.contains)
            && bundle != (Bundle.main.bundleIdentifier?.lowercased() ?? "")
    }

    static func identity(appName: String, bundleID: String? = nil) -> String {
        let bundle = (bundleID ?? "").lowercased()
        let name = appName.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let alias: [String: String] = [
            "chrome": "chrome", "googlechrome": "chrome",
            "微信": "wechat", "wechat": "wechat", "xinwechat": "wechat",
            "xcode": "xcode", "codex": "codex", "terminal": "terminal", "iterm": "iterm",
            "b站": "bilibili", "bilibili": "bilibili",
            "网易云": "netease", "netease": "netease", "网易云音乐": "netease",
            "notion": "notion", "obsidian": "obsidian", "word": "word",
            "备忘录": "notes", "notes": "notes",
            "美图秀秀": "mtxx", "mtxx": "mtxx", "mtxxpro": "mtxx",
            "系统设置": "systemsettings", "systempreferences": "systemsettings"
        ]

        for (needle, key) in alias where bundle.contains(needle) || name.contains(needle) {
            return key
        }

        if bundle.contains("chrome") { return "chrome" }
        if bundle.contains("wechat") { return "wechat" }
        if bundle.contains("bilibili") { return "bilibili" }
        if bundle.contains("netease") { return "netease" }

        let bundleTail = bundle.split(separator: ".").last.map(String.init) ?? ""
        if !bundleTail.isEmpty { return bundleTail }
        return name
    }

    static func category(appName: String, title: String?) -> String {
        let text = (appName + " " + (title ?? "")).lowercased()

        if ["微信", "wechat", "企业微信", "wecom", "mail", "邮件", "slack", "discord", "飞书", "feishu", "dingtalk", "钉钉", "messages", "telegram", "tavern"].contains(where: text.contains) {
            return "沟通"
        }
        if ["keynote", "figma", "pixelmator", "davinci", "final cut", "photoshop", "illustrator", "lightroom", "sketch", "affinity", "garageband", "logic", "美图", "mtxx"].contains(where: text.contains) {
            return "创作"
        }
        if ["xcode", "vs code", "visual studio", "terminal", "iterm", "warp", "github", "gitlab", "swift", "python", "docker", "postman", "proxyman", "codex", "developer"].contains(where: text.contains) {
            return "工作"
        }
        // "bear" 用词级匹配：裸子串会把 "beard" 之类误判，前导空格版又
        // 永远匹配不到应用名本身（text 以应用名开头时没有前导空格）。
        let hasBear = text.split(separator: " ").contains { $0 == "bear" }
        if hasBear || ["notion", "obsidian", "word", "pages", "books", "图书", "记忆", "学习", "anki", "zotero", "course", "lecture", "docs"].contains(where: text.contains) {
            return "学习"
        }
        if ["music", "netease", "spotify", "bilibili", "youtube", "netflix", "iqiyi", "爱奇艺", "抖音", "tiktok", "game", "steam"].contains(where: text.contains) {
            return "娱乐"
        }
        if ["finder", "settings", "设置", "activity monitor", "活动监视器", "console", "preview", "calculator", "访达", "systempreferences"].contains(where: text.contains) {
            return "系统"
        }
        // "arc" 作为裸子串会误吃 search/March/research；要求它独立成词。
        let hasArc = text.split(separator: " ").contains { $0 == "arc" }
        if hasArc || ["safari", "chrome", "edge", "firefox", "浏览器"].contains(where: text.contains) {
            return "浏览"
        }
        return "其他"
    }

    static func isFocus(_ category: String) -> Bool {
        ["工作", "学习", "创作"].contains(category)
    }

    /// 全部可指认的类别，映射设置用。"未记录"不在其中：那是"没有证据"的陈述，
    /// 不是用户可以指认的判断。
    static let categoryOptions = ["工作", "学习", "创作", "沟通", "浏览", "娱乐", "系统", "其他"]

    /// Hex form of the category colour, kept for callers that need a string.
    /// It must track `AppTheme.accent`; views should prefer `AppTheme.categoryTint`.
    static func color(for category: String) -> String {
        ["系统", "未记录"].contains(category) ? "#94A0B0" : "#3E74DC"
    }

    static func symbol(for app: String) -> String {
        let text = app.lowercased()
        if text.contains("chrome") || text.contains("safari") || text.contains("arc") || text.contains("edge") { return "globe" }
        if text.contains("xcode") || text.contains("codex") || text.contains("terminal") || text.contains("iterm") { return "hammer.fill" }
        if text.contains("微信") || text.contains("wechat") || text.contains("discord") || text.contains("slack") || text.contains("tavern") { return "bubble.left.and.bubble.right.fill" }
        if text.contains("网易云") || text.contains("music") || text.contains("spotify") { return "music.note" }
        if text.contains("bilibili") || text.contains("b站") || text.contains("youtube") || text.contains("抖音") { return "play.tv.fill" }
        if text.contains("notion") || text.contains("word") || text.contains("obsidian") || text.contains("docs") { return "doc.text.fill" }
        if text.contains("备忘录") || text.contains("notes") { return "note.text" }
        if text.contains("figma") || text.contains("keynote") || text.contains("sketch") { return "paintbrush.fill" }
        if text.contains("美图") || text.contains("mtxx") || text.contains("photoshop") { return "photo.fill" }
        if text.contains("系统设置") || text.contains("systempreferences") || text.contains("settings") { return "gearshape.fill" }
        if text.contains("访达") || text.contains("finder") || text.contains("预览") || text.contains("preview") { return "folder.fill" }
        return "app.fill"
    }
}

enum ActivityFormatter {
    static func timeRange(_ start: Date, _ end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, equalTo: end, toGranularity: .minute) {
            return "\(start.formatted(.dateTime.hour().minute().second()))–\(end.formatted(.dateTime.hour().minute().second()))"
        }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    static func time(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "0 分钟" }
        let minutes = Int(interval / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
        }
        return minutes < 1 ? "不到 1 分钟" : "\(minutes) 分钟"
    }
}
