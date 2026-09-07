import AppKit
import ApplicationServices
import Combine
import Foundation

// MARK: - Models

struct ActivitySession: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var category: String
    var start: Date
    var end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var hour: Int { Calendar.current.component(.hour, from: start) }
    var dayKey: String { Self.dayKey(for: start) }

    static func dayKey(for date: Date) -> String {
        DiaryEntry.dateFormatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, appName = "app", bundleID = "bundle", windowTitle = "title", category, start, end
    }
}

enum ActivitySourceKind: String, Hashable {
    case pipeline
    case live
    case fused

    var label: String {
        switch self {
        case .pipeline: "项目管道"
        case .live: "macOS 实时"
        case .fused: "双源一致"
        }
    }
}

struct UsageItem: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var duration: TimeInterval
    var count: Int
    var category: String
    var source: ActivitySourceKind = .pipeline

    var timeText: String { ActivityFormatter.time(duration) }
}

struct BrowseUsageItem: Identifiable, Hashable {
    var id: String { site }
    var site: String
    var visits: Int
    var days: Int
}

struct ActivityHour: Identifiable {
    var id: Int { hour }
    var hour: Int
    var duration: TimeInterval
    var primaryCategory: String
}

struct FusedDayStats: Identifiable {
    var id: String { dateKey }
    var dateKey: String
    var pipelineAvailable: Bool
    var pipelineTotal: TimeInterval
    var liveTotal: TimeInterval
    var focusTotal: TimeInterval
    var appUsage: [UsageItem]
    var categoryUsage: [UsageItem]
    var browseUsage: [BrowseUsageItem]
    var timeline: [ActivityHour]
    var liveSessions: [ActivitySession]
    var focusSessions: [ActivitySession]
    var longestSession: ActivitySession?
    var health: IOSHealthSummary?
    var conflicts: [String]
    var fragmentation: Int
    var confidence: Int
    var confidenceFactors: [ActivityConfidenceFactor]
    var headline: String
    var narrative: String
}

struct FusedRangeStats {
    var days: Int
    var dateKeys: [String]
    var pipelineTotal: TimeInterval
    var liveTotal: TimeInterval
    var focusTotal: TimeInterval
    var appUsage: [UsageItem]
    var categoryUsage: [UsageItem]
    var browseUsage: [BrowseUsageItem]
    var timeline: [ActivityHour]
    var liveSessions: [ActivitySession]
    var focusSessions: [ActivitySession]
    var healthSteps: Int
    var healthDistance: Double
    var healthEnergy: Double
    var conflicts: [String]
    var fragmentation: Int
    var confidence: Int
    var confidenceFactors: [ActivityConfidenceFactor]
    var headline: String
    var narrative: String
    var dayStats: [FusedDayStats]
}

struct ActivityAnswer {
    var summary: String
    var filters: [String]
    var sessions: [ActivitySession]
}

// MARK: - Classifier / formatter

enum ActivityClassifier {
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
        if ["notion", "obsidian", " bear", "word", "pages", "books", "图书", "记忆", "学习", "anki", "zotero", "course", " lecture", "docs"].contains(where: text.contains) {
            return "学习"
        }
        if ["music", "netease", "spotify", "bilibili", "youtube", "netflix", "iqiyi", "爱奇艺", "抖音", "tiktok", "game", "steam"].contains(where: text.contains) {
            return "娱乐"
        }
        if ["finder", "settings", "设置", "activity monitor", "活动监视器", "console", "preview", "calculator", "访达", "systempreferences"].contains(where: text.contains) {
            return "系统"
        }
        if ["safari", "chrome", "arc", "edge", "firefox", "浏览器"].contains(where: text.contains) {
            return "浏览"
        }
        return "其他"
    }

    static func isFocus(_ category: String) -> Bool {
        ["工作", "学习", "创作"].contains(category)
    }

    static func color(for category: String) -> String {
        switch category {
        case "工作": "#7787FF"
        case "学习": "#4FB6A9"
        case "创作": "#F0A75C"
        case "沟通": "#67A7F0"
        case "娱乐": "#F2788D"
        case "休息": "#59BF8A"
        case "浏览": "#8F8CE8"
        case "系统": "#A5AFC2"
        default: "#B7AFC9"
        }
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
    static func time(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
        }
        return minutes < 1 ? "不到 1 分钟" : "\(minutes) 分钟"
    }
}

// MARK: - Store

@MainActor
final class ActivityStore: ObservableObject {
    static let schemaVersion = 4

    @Published private(set) var sessions: [ActivitySession] = []
    @Published private(set) var isTracking = false
    @Published private(set) var activeSession: ActivitySession?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var lastSavedApp: String?
    @Published private(set) var capturesTitles = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var storageSummary = "尚未开始 macOS 实时记录"
    @Published private(set) var pauseScheduleEnabled = false
    @Published private(set) var pauseStartMinutes = 22 * 60
    @Published private(set) var pauseEndMinutes = 7 * 60
    @Published private(set) var isCurrentlyPaused = false

    private var dayStatsCache: [String: CachedDayStats] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pauseTimer: Timer?

    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let appCenter = NotificationCenter.default
    private let fileManager = FileManager.default

    private lazy var activityDirectory: URL? = {
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let target = directory
            .appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Activity", isDirectory: true)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }()

    init() {
        pauseScheduleEnabled = UserDefaults.standard.bool(forKey: "activity.pauseScheduleEnabled")
        pauseStartMinutes = UserDefaults.standard.object(forKey: "activity.pauseStart") as? Int ?? 22 * 60
        pauseEndMinutes = UserDefaults.standard.object(forKey: "activity.pauseEnd") as? Int ?? 7 * 60
        capturesTitles = UserDefaults.standard.bool(forKey: "activity.capturesTitles")
        accessibilityGranted = AXIsProcessTrusted()
        loadStoredSessions()
        if UserDefaults.standard.bool(forKey: "activity.enabled") {
            startTracking(showPermissionPrompt: false)
        }
        refreshPauseState()
    }

    func startTracking(showPermissionPrompt: Bool = true) {
        guard !isTracking else { return }

        isTracking = true
        UserDefaults.standard.set(true, forKey: "activity.enabled")

        if showPermissionPrompt && capturesTitles && !accessibilityGranted {
            requestAccessibility()
        }

        registerObservers()

        if let app = NSWorkspace.shared.frontmostApplication {
            activeSession = newSession(for: app)
        }

        storageSummary = "事件驱动记录已开启；片段会在应用切换或退出后保存。"
        startPauseTimer()
        refreshPauseState()
    }

    func stopTracking() {
        guard isTracking else { return }
        closeActiveSession()
        removeObservers()
        isTracking = false
        activeSession = nil
        UserDefaults.standard.set(false, forKey: "activity.enabled")
        pauseTimer?.invalidate()
        pauseTimer = nil
        isCurrentlyPaused = false
        storageSummary = "已停止 macOS 实时记录。"
    }


    func setPauseSchedule(enabled: Bool, startMinutes: Int? = nil, endMinutes: Int? = nil) {
        pauseScheduleEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "activity.pauseScheduleEnabled")

        if let startMinutes {
            pauseStartMinutes = max(0, min(24 * 60 - 1, startMinutes))
        }
        if let endMinutes {
            pauseEndMinutes = max(0, min(24 * 60 - 1, endMinutes))
        }

        UserDefaults.standard.set(pauseStartMinutes, forKey: "activity.pauseStart")
        UserDefaults.standard.set(pauseEndMinutes, forKey: "activity.pauseEnd")
        refreshPauseState()
    }

    var pauseWindowLabel: String {
        String(format: "%02d:%02d–%02d:%02d", pauseStartMinutes / 60, pauseStartMinutes % 60, pauseEndMinutes / 60, pauseEndMinutes % 60)
    }

    private var isWithinPauseWindow: Bool {
        let minute = Calendar.current.component(.minute, from: Date()) + Calendar.current.component(.hour, from: Date()) * 60
        if pauseStartMinutes == pauseEndMinutes { return false }
        if pauseStartMinutes < pauseEndMinutes {
            return minute >= pauseStartMinutes && minute < pauseEndMinutes
        }
        return minute >= pauseStartMinutes || minute < pauseEndMinutes
    }

    private func startPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPauseState() }
        }
    }

    func refreshPauseState() {
        let paused = isTracking && pauseScheduleEnabled && isWithinPauseWindow
        isCurrentlyPaused = paused
        if paused, activeSession != nil {
            closeActiveSession()
        }
    }

    func setCapturesTitles(_ enabled: Bool) {
        capturesTitles = enabled
        UserDefaults.standard.set(enabled, forKey: "activity.capturesTitles")
        if !enabled {
            activeSession?.windowTitle = nil
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func closeForTermination() {
        closeActiveSession()
        removeObservers()
    }

    func restoreBackup(_ restored: [ActivitySession]) throws {
        stopTracking()
        sessions = []
        dayStatsCache = [:]
        if let directory = activityDirectory {
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "activity" {
                try fileManager.removeItem(at: file)
            }
        }
        sessions = restored.sorted { $0.start < $1.start }
        for session in sessions { persist(session) }
        storageSummary = "已恢复并加密保存 \(sessions.count) 段实时活动"
    }

    func clearActivity() {
        stopTracking()
        sessions = []
        dayStatsCache = [:]
        if let directory = activityDirectory {
            try? fileManager.removeItem(at: directory)
        }
        storageSummary = "已清除 macOS 实时足迹。"
    }

    func liveSessions(for date: Date) -> [ActivitySession] {
        let key = DiaryEntry.dateFormatter.string(from: date)
        return sessions.filter { $0.dayKey == key }.sorted { $0.start < $1.start }
    }

    func screenTimeSnapshot() -> ScreenTimeSnapshot? {
        let today = Date()
        let todaySessions = liveSessions(for: today)
        guard !todaySessions.isEmpty else { return nil }

        let totalSeconds = todaySessions.reduce(0) { $0 + $1.duration }
        var appDuration: [String: TimeInterval] = [:]
        for session in todaySessions {
            appDuration[session.appName, default: 0] += session.duration
        }
        let topApps = appDuration
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)

        return ScreenTimeSnapshot(
            totalMinutes: Int(totalSeconds / 60),
            topApps: Array(topApps)
        )
    }

    // MARK: Cached fusion

    func dayStats(entries: [DiaryEntry], date: Date) -> FusedDayStats {
        let dateKey = DiaryEntry.dateFormatter.string(from: date)
        let pipeline = entries.first { $0.date == dateKey }
        let live = liveSessions(for: date)
        let liveSignature = live
            .map { "\($0.id.uuidString):\(Int($0.start.timeIntervalSince1970)):\(Int($0.end.timeIntervalSince1970)):\($0.windowTitle ?? "")" }
            .joined(separator: ",")
        let fingerprint = Self.pipelineFingerprint(pipeline) + "|live:\(liveSignature):\(Self.schemaVersion)"

        if let cached = dayStatsCache[dateKey], cached.fingerprint == fingerprint {
            return cached.stats
        }

        let stats = ActivityFusionEngine.dayStats(dateKey: dateKey, entry: pipeline, liveSessions: live)
        dayStatsCache[dateKey] = CachedDayStats(fingerprint: fingerprint, stats: stats)
        return stats
    }

    func summary(entries: [DiaryEntry], days: Int, around date: Date = Date()) -> FusedRangeStats {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: date)) ?? date
        let dateKeys = (0..<days).compactMap { offset -> String? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: start)) else { return nil }
            return DiaryEntry.dateFormatter.string(from: day)
        }

        let stats = dateKeys.map { key in
            dayStats(
                entries: entries,
                date: DiaryEntry.dateFormatter.date(from: key) ?? date
            )
        }

        return ActivityFusionEngine.rangeStats(dayStats: stats, days: days)
    }

    static func pipelineFingerprint(_ entry: DiaryEntry?) -> String {
        guard let entry else { return "none" }

        let apps = (entry.screenApps ?? []).map { "\($0.app):\(String(describing: $0.minutes))" }.joined(separator: ",")
        let sites = (entry.browseSites ?? []).map { "\($0.site):\(String(describing: $0.visits))" }.joined(separator: ",")
        let health = entry.health.flatMap {
            "\($0.steps ?? 0):\($0.distanceKM ?? 0):\($0.activeEnergyKcal ?? 0):\($0.updatedAt ?? "")"
        }

        return [
            entry.id,
            String(describing: entry.screenMinutes ?? -1),
            apps,
            sites,
            entry.screenNote ?? "",
            entry.browseNote ?? "",
            health ?? "",
            String(Self.schemaVersion)
        ].joined(separator: "|")
    }

    // MARK: Event handling

    private func registerObservers() {
        removeObservers()

        addWorkspaceObserver(NSWorkspace.didActivateApplicationNotification) { store, note in
            store.handleActivation(note)
        }
        addWorkspaceObserver(NSWorkspace.didDeactivateApplicationNotification) { store, note in
            store.handleDeactivation(note)
        }
        addWorkspaceObserver(NSWorkspace.didTerminateApplicationNotification) { store, note in
            store.handleTermination(note)
        }
        addWorkspaceObserver(NSWorkspace.willSleepNotification) { store, _ in
            store.closeActiveSession()
        }
        addWorkspaceObserver(NSWorkspace.screensDidSleepNotification) { store, _ in
            store.closeActiveSession()
        }
        addWorkspaceObserver(NSWorkspace.didWakeNotification) { store, _ in
            store.startSessionAfterWake()
        }
        addWorkspaceObserver(NSWorkspace.screensDidWakeNotification) { store, _ in
            store.startSessionAfterWake()
        }
        addWorkspaceObserver(NSWorkspace.sessionDidBecomeActiveNotification) { store, _ in
            store.startSessionAfterWake()
        }

        appCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.closeForTermination() }
        }
    }

    private func removeObservers() {
        observers.forEach {
            workspaceCenter.removeObserver($0)
            appCenter.removeObserver($0)
        }
        observers.removeAll()
    }

    private func addWorkspaceObserver(
        _ name: NSNotification.Name,
        handler: @escaping (ActivityStore, Notification) -> Void
    ) {
        let token = workspaceCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handler(self, note)
            }
        }
        observers.append(token)
    }

    private func handleActivation(_ note: Notification) {
        guard isTracking, !isCurrentlyPaused,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        switchTo(app)
    }

    private func handleDeactivation(_ note: Notification) {
        guard isTracking,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let active = activeSession,
              active.bundleID == app.bundleIdentifier else { return }
        closeActiveSession()
        refreshPauseState()
    }

    private func handleTermination(_ note: Notification) {
        guard isTracking,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let active = activeSession,
              active.bundleID == app.bundleIdentifier else { return }
        closeActiveSession()
    }

    func startSessionAfterWake() {
        // 唤醒或解锁后，即使前台应用没有变化，也要开新片段，避免把睡眠时间并入同一段。
        guard isTracking, !isCurrentlyPaused, activeSession == nil, let app = NSWorkspace.shared.frontmostApplication else { return }
        activeSession = newSession(for: app)
    }

    private func switchTo(_ app: NSRunningApplication) {
        guard !isCurrentlyPaused else { return }
        if let active = activeSession {
            if active.bundleID == app.bundleIdentifier {
                return
            }
            closeActiveSession()
        }

        activeSession = newSession(for: app)
    }

    private func newSession(for app: NSRunningApplication) -> ActivitySession {
        let appName = app.localizedName ?? "未知应用"
        let title = currentTitle(for: app)
        return ActivitySession(
            appName: appName,
            bundleID: app.bundleIdentifier ?? appName,
            windowTitle: capturesTitles ? title : nil,
            category: ActivityClassifier.category(appName: appName, title: title),
            start: Date(),
            end: Date()
        )
    }

    private func currentTitle(for app: NSRunningApplication) -> String? {
        guard capturesTitles, accessibilityGranted else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        guard result == .success, let title = value as? String else { return nil }

        let lower = title.lowercased()
        if lower.contains("incognito") || title.contains("无痕") { return "受保护窗口" }
        return title
    }

    private func closeActiveSession() {
        guard var session = activeSession else { return }
        session.end = Date()
        activeSession = nil

        // 过短的切换视为系统噪音，不进入统计。
        if session.duration >= 1 {
            appendSegments(splitAtDayBoundary(session))
        }
    }

    private func splitAtDayBoundary(_ session: ActivitySession) -> [ActivitySession] {
        guard session.end > session.start else { return [] }

        let calendar = Calendar.current
        var segments: [ActivitySession] = []
        var remaining = session

        while remaining.end > remaining.start {
            let nextDayStart = calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: 1, to: remaining.start) ?? remaining.end
            )
            if remaining.end <= nextDayStart {
                segments.append(remaining)
                break
            }

            var first = remaining
            first.end = nextDayStart
            segments.append(first)

            remaining.start = nextDayStart
            remaining.id = UUID()
        }

        return segments
    }

    private func appendSegments(_ segments: [ActivitySession]) {
        guard let original = segments.first else { return }
        sessions.removeAll { $0.id == original.id }
        sessions.append(contentsOf: segments)
        sessions.sort { $0.start < $1.start }

        segments.forEach { persist($0) }
        lastSavedAt = Date()
        lastSavedApp = original.appName
        Set(segments.map(\.dayKey)).forEach { dayStatsCache.removeValue(forKey: $0) }
        storageSummary = "已加密保存 \(sessions.count) 段实时活动（最近 365 天）"
    }

    private func persist(_ session: ActivitySession) {
        guard let directory = activityDirectory else { return }
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let url = directory.appendingPathComponent("\(session.dayKey).activity")
            var daySessions = readSessions(from: url).filter { $0.id != session.id }
            daySessions.append(session)
            daySessions.sort { $0.start < $1.start }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let encrypted = try StateEncryption.encrypt(try encoder.encode(daySessions))
            try encrypted.write(to: url, options: .atomic)
        } catch {
            storageSummary = "实时足迹保存失败：\(error.localizedDescription)"
        }
    }

    private func readSessions(from url: URL) -> [ActivitySession] {
        guard let raw = try? Data(contentsOf: url),
              let decrypted = try? StateEncryption.decrypt(raw) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ActivitySession].self, from: decrypted)) ?? []
    }

    private func loadStoredSessions() {
        guard let directory = activityDirectory,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date()
        var loaded: [ActivitySession] = []

        for file in files where file.pathExtension == "activity" {
            let daySessions = readSessions(from: file)
            let kept = daySessions.filter { $0.end >= cutoff }
            loaded.append(contentsOf: kept)

            // 超过保留期的文件不再继续留在磁盘上，避免旧数据越积越多。
            if kept.count != daySessions.count {
                if kept.isEmpty {
                    try? fileManager.removeItem(at: file)
                } else {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.sortedKeys]
                    if let encrypted = try? StateEncryption.encrypt(try encoder.encode(kept)) {
                        try? encrypted.write(to: file, options: .atomic)
                    }
                }
            }
        }

        sessions = loaded.sorted { $0.start < $1.start }
        storageSummary = sessions.isEmpty
            ? "尚未开始 macOS 实时记录"
            : "已加密保存 \(sessions.count) 段实时活动（最近 365 天）"
    }
}

private struct CachedDayStats {
    var fingerprint: String
    var stats: FusedDayStats
}

// MARK: - Fusion engine

enum ActivityFusionEngine {
    static func dayStats(
        dateKey: String,
        entry: DiaryEntry?,
        liveSessions: [ActivitySession]
    ) -> FusedDayStats {
        let live = liveSessions.sorted { $0.start < $1.start }
        let pipelineTotal = Double(entry?.screenMinutes ?? 0) * 60
        let liveTotal = live.reduce(0) { $0 + $1.duration }
        let appItems = fusedAppUsage(entry: entry, live: live, pipelineTotal: pipelineTotal)

        var categories: [String: UsageItem] = [:]
        for app in appItems {
            var item = categories[app.category] ?? UsageItem(
                name: app.category,
                duration: 0,
                count: 0,
                category: app.category,
                source: .pipeline
            )
            item.duration += app.duration
            item.count += 1
            item.source = strongestSource(item.source, app.source)
            categories[app.category] = item
        }

        let categoryUsage = categories.values.sorted { $0.duration > $1.duration }
        let timeline = hourlyTimeline(live)
        let focusSessions = live.filter { ActivityClassifier.isFocus($0.category) }
        let focusTotal = focusSessions.reduce(0) { $0 + $1.duration }
        let conflicts = dataConflicts(entry: entry, pipelineTotal: pipelineTotal, liveTotal: liveTotal)
        let confidence = ActivityConfidenceEngine.day(entry: entry, liveSessions: live)
        let fragmentation = fragmentationScore(live)

        return FusedDayStats(
            dateKey: dateKey,
            pipelineAvailable: entry?.hasProjectSignals == true,
            pipelineTotal: pipelineTotal,
            liveTotal: liveTotal,
            focusTotal: focusTotal,
            appUsage: appItems,
            categoryUsage: categoryUsage,
            browseUsage: browseUsage(entry),
            timeline: timeline,
            liveSessions: live,
            focusSessions: focusSessions,
            longestSession: live.max { $0.duration < $1.duration },
            health: entry?.health,
            conflicts: conflicts,
            fragmentation: fragmentation,
            confidence: confidence.score,
            confidenceFactors: confidence.factors,
            headline: dayHeadline(pipelineTotal: pipelineTotal, appUsage: appItems, live: live),
            narrative: dayNarrative(entry: entry, pipelineTotal: pipelineTotal, appUsage: appItems, live: live)
        )
    }

    private static func fusedAppUsage(
        entry: DiaryEntry?,
        live: [ActivitySession],
        pipelineTotal: TimeInterval
    ) -> [UsageItem] {
        var appItems: [UsageItem] = []
        var matchedLiveIDs = Set<UUID>()
        let pipelineApps = entry?.screenApps ?? []

        for app in pipelineApps {
            let identity = ActivityClassifier.identity(appName: app.app)
            let matchedLive = live.filter {
                ActivityClassifier.identity(appName: $0.appName, bundleID: $0.bundleID) == identity
            }
            matchedLiveIDs.formUnion(matchedLive.map(\.id))
            let duration = Double(app.minutes ?? 0) * 60
            if duration > 0 {
                appItems.append(
                    UsageItem(
                        name: app.app,
                        duration: duration,
                        count: 1,
                        category: ActivityClassifier.category(appName: app.app, title: nil),
                        source: matchedLive.isEmpty ? .pipeline : .fused
                    )
                )
            }
        }

        let unmatched = live.filter { !matchedLiveIDs.contains($0.id) }
        let unmatchedTotal = unmatched.reduce(0) { $0 + $1.duration }
        let pipelineAppTotal = Double(pipelineApps.reduce(0) { $0 + ($1.minutes ?? 0) }) * 60
        let unattributedPipelineTotal = max(0, pipelineTotal - pipelineAppTotal)

        // 管道是每日总量的权威来源。实时片段只填补管道未归属的时间；
        // 如果管道明细已完整，就绝不把实时时长再叠加到应用列表上。
        if unmatchedTotal > 0 && unattributedPipelineTotal > 0 {
            let scale = min(1, unattributedPipelineTotal / unmatchedTotal)
            for session in unmatched {
                let duration = session.duration * scale
                guard duration >= 1 else { continue }
                if let index = appItems.firstIndex(where: {
                    ActivityClassifier.identity(appName: $0.name, bundleID: session.bundleID)
                        == ActivityClassifier.identity(appName: session.appName, bundleID: session.bundleID)
                }) {
                    appItems[index].duration += duration
                    appItems[index].source = .fused
                } else {
                    appItems.append(
                        UsageItem(
                            name: session.appName,
                            duration: duration,
                            count: 1,
                            category: session.category,
                            source: pipelineTotal > 0 ? .fused : .live
                        )
                    )
                }
            }
        } else if unmatchedTotal > 0 && pipelineApps.isEmpty {
            // 管道只有屏幕总量、没有应用明细时，用实时片段分配总量，而不是额外相加。
            let scale = pipelineTotal > 0 && unmatchedTotal > 0 ? min(1, pipelineTotal / unmatchedTotal) : 1
            for session in unmatched {
                let duration = session.duration * scale
                guard duration >= 1 else { continue }
                appItems.append(
                    UsageItem(
                        name: session.appName,
                        duration: duration,
                        count: 1,
                        category: session.category,
                        source: pipelineTotal > 0 ? .fused : .live
                    )
                )
            }
        }

        return appItems.sorted { $0.duration > $1.duration }
    }

    private static func strongestSource(_ current: ActivitySourceKind, _ candidate: ActivitySourceKind) -> ActivitySourceKind {
        if current == .fused || candidate == .fused { return .fused }
        if current == .live { return .live }
        return candidate
    }

    private static func dataConflicts(
        entry: DiaryEntry?,
        pipelineTotal: TimeInterval,
        liveTotal: TimeInterval
    ) -> [String] {
        var conflicts: [String] = []

        if pipelineTotal > 0 && liveTotal > 0 {
            let difference = abs(pipelineTotal - liveTotal)
            let threshold = max(600, max(pipelineTotal, liveTotal) * 0.2)
            if difference > threshold {
                conflicts.append("双源总时长差异较大：项目管道 \(ActivityFormatter.time(pipelineTotal))，macOS 实时 \(ActivityFormatter.time(liveTotal))。")
            }
        }

        if let entry,
           let apps = entry.screenApps,
           let screenMinutes = entry.screenMinutes {
            let appSum = apps.reduce(0) { $0 + ($1.minutes ?? 0) }
            if appSum > 0 && abs(appSum - screenMinutes) > 15 {
                conflicts.append("项目内部汇总与应用明细相差约 \(abs(appSum - screenMinutes)) 分钟，已按汇总值显示。")
            }
        }

        return conflicts
    }

    static func rangeStats(dayStats: [FusedDayStats], days: Int) -> FusedRangeStats {
        var appGroups: [String: (item: UsageItem, days: Int)] = [:]
        var categoryGroups: [String: UsageItem] = [:]
        var browseGroups: [String: (visits: Int, days: Int)] = [:]
        var hourGroups: [Int: (duration: TimeInterval, categories: [String: TimeInterval])] = [:]
        var sessions: [ActivitySession] = []
        var focusSessions: [ActivitySession] = []
        var conflicts: [String] = []
        var fragmentationSum = 0
        var fragmentationDays = 0

        for day in dayStats {
            for app in day.appUsage {
                let key = ActivityClassifier.identity(appName: app.name)
                var group = appGroups[key] ?? (
                    UsageItem(
                        name: app.name,
                        duration: 0,
                        count: 0,
                        category: app.category,
                        source: app.source
                    ),
                    0
                )
                group.item.duration += app.duration
                group.item.count += 1
                if app.source == .fused { group.item.source = .fused }
                else if group.item.source != .fused { group.item.source = app.source }
                group.days += 1
                appGroups[key] = group
            }

            for category in day.categoryUsage {
                var item = categoryGroups[category.name] ?? UsageItem(name: category.name, duration: 0, count: 0, category: category.name, source: category.source)
                item.duration += category.duration
                item.count += 1
                if category.source == .fused { item.source = .fused }
                categoryGroups[category.name] = item
            }

            for site in day.browseUsage {
                var group = browseGroups[site.site] ?? (0, 0)
                group.visits += site.visits
                group.days += 1
                browseGroups[site.site] = group
            }

            for hour in day.timeline {
                var group = hourGroups[hour.hour] ?? (0, [:])
                group.duration += hour.duration
                if !hour.primaryCategory.isEmpty {
                    group.categories[hour.primaryCategory, default: 0] += hour.duration
                }
                hourGroups[hour.hour] = group
            }

            sessions.append(contentsOf: day.liveSessions)
            focusSessions.append(contentsOf: day.focusSessions)
            conflicts.append(contentsOf: day.conflicts.map { "\(day.dateKey)：\($0)" })

            if day.liveTotal > 0 {
                fragmentationSum += day.fragmentation
                fragmentationDays += 1
            }
        }

        let appUsage = appGroups.values
            .map { $0.item }
            .sorted { $0.duration > $1.duration }
        let categoryUsage = categoryGroups.values
            .sorted { $0.duration > $1.duration }
        let browseUsage = browseGroups
            .map { BrowseUsageItem(site: $0.key, visits: $0.value.visits, days: $0.value.days) }
            .sorted { $0.visits > $1.visits }
        let timeline = (0...23).map { hour -> ActivityHour in
            let group = hourGroups[hour] ?? (0, [:])
            return ActivityHour(
                hour: hour,
                duration: group.duration,
                primaryCategory: group.categories.max { $0.value < $1.value }?.key ?? ""
            )
        }

        let pipelineTotal = dayStats.reduce(0) { $0 + $1.pipelineTotal }
        let liveTotal = dayStats.reduce(0) { $0 + $1.liveTotal }
        let focusTotal = dayStats.reduce(0) { $0 + $1.focusTotal }
        let steps = dayStats.reduce(0) { $0 + ($1.health?.steps ?? 0) }
        let distance = dayStats.reduce(0) { $0 + ($1.health?.distanceKM ?? 0) }
        let energy = dayStats.reduce(0) { $0 + ($1.health?.activeEnergyKcal ?? 0) }
        let rangeConfidence = ActivityConfidenceEngine.range(dayStats: dayStats)

        return FusedRangeStats(
            days: days,
            dateKeys: dayStats.map(\.dateKey),
            pipelineTotal: pipelineTotal,
            liveTotal: liveTotal,
            focusTotal: focusTotal,
            appUsage: appUsage,
            categoryUsage: categoryUsage,
            browseUsage: browseUsage,
            timeline: timeline,
            liveSessions: sessions.sorted { $0.start < $1.start },
            focusSessions: focusSessions,
            healthSteps: steps,
            healthDistance: distance,
            healthEnergy: energy,
            conflicts: conflicts,
            fragmentation: fragmentationDays == 0 ? 0 : Int((Double(fragmentationSum) / Double(fragmentationDays)).rounded()),
            confidence: rangeConfidence.score,
            confidenceFactors: rangeConfidence.factors,
            headline: rangeHeadline(appUsage: appUsage, pipelineTotal: pipelineTotal, days: days),
            narrative: rangeNarrative(dayStats: dayStats, appUsage: appUsage, browseUsage: browseUsage, focusTotal: focusTotal, steps: steps, days: days),
            dayStats: dayStats
        )
    }

    private static func hourlyTimeline(_ sessions: [ActivitySession]) -> [ActivityHour] {
        var groups: [Int: (duration: TimeInterval, categories: [String: TimeInterval])] = [:]

        for session in sessions {
            let calendar = Calendar.current
            var cursor = session.start
            let end = session.end

            while cursor < end {
                let nextHour = calendar.nextDate(
                    after: cursor,
                    matching: DateComponents(minute: 0),
                    matchingPolicy: .nextTimePreservingSmallerComponents
                ) ?? end
                let chunkEnd = min(nextHour, end)
                let duration = chunkEnd.timeIntervalSince(cursor)
                let hour = calendar.component(.hour, from: cursor)

                var group = groups[hour] ?? (0, [:])
                group.duration += duration
                group.categories[session.category, default: 0] += duration
                groups[hour] = group
                cursor = chunkEnd
            }
        }

        return (0...23).map { hour in
            let group = groups[hour] ?? (0, [:])
            return ActivityHour(
                hour: hour,
                duration: group.duration,
                primaryCategory: group.categories.max { $0.value < $1.value }?.key ?? ""
            )
        }
    }

    private static func browseUsage(_ entry: DiaryEntry?) -> [BrowseUsageItem] {
        (entry?.browseSites ?? []).map {
            BrowseUsageItem(site: $0.site, visits: $0.visits ?? 0, days: 1)
        }
        .sorted { $0.visits > $1.visits }
    }

    private static func fragmentationScore(_ sessions: [ActivitySession]) -> Int {
        let total = sessions.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        let switchesPerHour = Double(sessions.count) / max(0.5, total / 3600)
        return min(100, max(0, Int((switchesPerHour - 4) * 9)))
    }

    private static func dayHeadline(
        pipelineTotal: TimeInterval,
        appUsage: [UsageItem],
        live: [ActivitySession]
    ) -> String {
        if let top = appUsage.first {
            return "主要停在 \(top.name)，共 \(ActivityFormatter.time(top.duration))"
        }
        if pipelineTotal > 0 {
            return "屏幕时间约 \(ActivityFormatter.time(pipelineTotal))"
        }
        if let longest = live.max(by: { $0.duration < $1.duration }) {
            return "实时记录到 \(longest.appName) 的连续片段"
        }
        return "这一天缺少活动信号"
    }

    private static func dayNarrative(
        entry: DiaryEntry?,
        pipelineTotal: TimeInterval,
        appUsage: [UsageItem],
        live: [ActivitySession]
    ) -> String {
        var lines: [String] = []

        if let entry, let minutes = entry.screenMinutes, !appUsage.isEmpty {
            let apps = appUsage.prefix(3).map { "\($0.name) \(ActivityFormatter.time($0.duration))" }.joined(separator: "、")
            lines.append("项目管道显示当天屏幕时间约 \(ActivityFormatter.time(Double(minutes) * 60))，主要分布是 \(apps)。")
        } else if pipelineTotal > 0 {
            lines.append("项目管道显示当天屏幕时间约 \(ActivityFormatter.time(pipelineTotal))，暂无应用明细。")
        } else if let top = appUsage.first {
            lines.append("实时足迹显示主要使用 \(top.name)，约 \(ActivityFormatter.time(top.duration))。")
        }

        if let longest = live.max(by: { $0.duration < $1.duration }), longest.duration >= 600 {
            lines.append("macOS 实时记录到最长一段是 \(longest.appName)，约 \(ActivityFormatter.time(longest.duration))。")
        }

        if let site = (entry?.browseSites ?? []).first, let visits = site.visits, visits > 0 {
            lines.append("浏览主题以 \(site.site) 最频繁，共 \(visits) 次。")
        }

        if let health = entry?.health, let steps = health.steps {
            lines.append(steps >= 6000 ? "步数 \(steps)，身体活动较充足。" : "步数 \(steps)，活动量偏轻。")
        }

        if lines.isEmpty {
            lines.append("这一天还没有足够的屏幕或运动信号。")
        }

        return lines.joined()
    }

    private static func rangeHeadline(appUsage: [UsageItem], pipelineTotal: TimeInterval, days: Int) -> String {
        if let top = appUsage.first {
            return "最近 \(days) 天主要停在 \(top.name)，共 \(ActivityFormatter.time(top.duration))"
        }
        return pipelineTotal > 0 ? "累计屏幕时间 \(ActivityFormatter.time(pipelineTotal))" : "当前范围缺少活动信号"
    }

    private static func rangeNarrative(
        dayStats: [FusedDayStats],
        appUsage: [UsageItem],
        browseUsage: [BrowseUsageItem],
        focusTotal: TimeInterval,
        steps: Int,
        days: Int
    ) -> String {
        var lines: [String] = []

        if let top = appUsage.first {
            lines.append("项目管道与实时足迹共同显示，\(top.name) 是这段时间的主线，共 \(ActivityFormatter.time(top.duration))。")
        }

        if focusTotal > 0 {
            lines.append("实时记录到 \(ActivityFormatter.time(focusTotal)) 的专注类活动。")
        }

        if let site = browseUsage.first {
            lines.append("浏览足迹中 \(site.site) 最频繁，共 \(site.visits) 次。")
        }

        if steps > 0 {
            lines.append("累计 \(steps) 步，平均每天 \(Int(Double(steps) / Double(max(1, days)))) 步。")
        }

        let conflictCount = dayStats.filter { !$0.conflicts.isEmpty }.count
        if conflictCount > 0 {
            lines.append("有 \(conflictCount) 天的双源数据差异较大，已标记为低置信度。")
        }

        if lines.isEmpty {
            lines.append("这段时间还没有足够的活动数据。")
        }

        return lines.joined()
    }
}

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
