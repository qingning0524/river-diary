import AppKit
import ApplicationServices
import Combine
import Foundation

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
    private let preferences: UserDefaults
    private let configuredActivityDirectory: URL?
    private let providedV2Store: V2Store?
    private lazy var v2Store: V2Store = providedV2Store ?? V2Store()

    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private let appCenter = NotificationCenter.default
    private let fileManager = FileManager.default

    private lazy var activityDirectory: URL? = {
        let target: URL
        if let configuredActivityDirectory {
            target = configuredActivityDirectory
        } else {
            guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
            target = directory
                .appendingPathComponent("RiverDiaryMac", isDirectory: true)
                .appendingPathComponent("Activity", isDirectory: true)
        }
        do {
            let parent = target.deletingLastPathComponent()
            try LocalStorageProtection.ensurePrivateDirectory(at: parent)
            if !fileManager.fileExists(atPath: target.path) {
                let interruptedRestores = try fileManager.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
                ).filter { candidate in
                    guard candidate.lastPathComponent.hasPrefix("Activity-previous-"),
                          let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
                    return values.isDirectory == true
                }
                if let previous = interruptedRestores.max(by: { lhs, rhs in
                    let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return leftDate < rightDate
                }) {
                    try fileManager.moveItem(at: previous, to: target)
                }
            }
            try LocalStorageProtection.ensurePrivateDirectory(at: target)
        } catch {
            storageSummary = "实时足迹目录权限设置失败：\(error.localizedDescription)"
            return nil
        }
        return target
    }()

    init(
        activityDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard,
        v2Store: V2Store? = nil
    ) {
        configuredActivityDirectory = activityDirectory
        preferences = userDefaults
        providedV2Store = v2Store
        pauseScheduleEnabled = userDefaults.bool(forKey: "activity.pauseScheduleEnabled")
        pauseStartMinutes = userDefaults.object(forKey: "activity.pauseStart") as? Int ?? 22 * 60
        pauseEndMinutes = userDefaults.object(forKey: "activity.pauseEnd") as? Int ?? 7 * 60
        capturesTitles = userDefaults.bool(forKey: "activity.capturesTitles")
        accessibilityGranted = AXIsProcessTrusted()
        loadStoredSessions()
        if userDefaults.bool(forKey: "activity.enabled") {
            startTracking(showPermissionPrompt: false)
        }
        refreshPauseState()
    }

    func encryptedV2Snapshot() throws -> Data {
        try v2Store.encryptedSnapshot()
    }

    func validateV2Snapshot(_ snapshot: Data) throws {
        try v2Store.validateEncryptedSnapshot(snapshot)
    }

    func restoreV2Snapshot(_ snapshot: Data) throws {
        try v2Store.restoreEncryptedSnapshot(snapshot)
    }

    func startTracking(showPermissionPrompt: Bool = true) {
        guard !isTracking else { return }

        isTracking = true
        preferences.set(true, forKey: "activity.enabled")

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
        preferences.set(false, forKey: "activity.enabled")
        pauseTimer?.invalidate()
        pauseTimer = nil
        isCurrentlyPaused = false
        storageSummary = "已停止 macOS 实时记录。"
    }


    func setPauseSchedule(enabled: Bool, startMinutes: Int? = nil, endMinutes: Int? = nil) {
        pauseScheduleEnabled = enabled
        preferences.set(enabled, forKey: "activity.pauseScheduleEnabled")

        if let startMinutes {
            pauseStartMinutes = max(0, min(24 * 60 - 1, startMinutes))
        }
        if let endMinutes {
            pauseEndMinutes = max(0, min(24 * 60 - 1, endMinutes))
        }

        preferences.set(pauseStartMinutes, forKey: "activity.pauseStart")
        preferences.set(pauseEndMinutes, forKey: "activity.pauseEnd")
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
        preferences.set(enabled, forKey: "activity.capturesTitles")
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
        guard let directory = activityDirectory else {
            throw NSError(domain: "RiverDiaryMac", code: 21, userInfo: [NSLocalizedDescriptionKey: "实时足迹目录不可用，无法恢复备份。"])
        }

        let orderedSessions = restored.sorted { $0.start < $1.start }
        let parent = directory.deletingLastPathComponent()
        let stagingDirectory = parent.appendingPathComponent("Activity-restore-\(UUID().uuidString)", isDirectory: true)
        let previousDirectory = parent.appendingPathComponent("Activity-previous-\(UUID().uuidString)", isDirectory: true)
        try LocalStorageProtection.ensurePrivateDirectory(at: stagingDirectory)
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sessionsByDay = Dictionary(grouping: orderedSessions, by: \.dayKey)
        for (dayKey, daySessions) in sessionsByDay.sorted(by: { $0.key < $1.key }) {
            let file = stagingDirectory.appendingPathComponent("\(dayKey).activity")
            let encrypted = try StateEncryption.encrypt(try encoder.encode(daySessions.sorted { $0.start < $1.start }))
            try encrypted.write(to: file, options: .atomic)
            try LocalStorageProtection.protectFile(at: file)
        }

        let shouldResumeTracking = isTracking
        if shouldResumeTracking { stopTracking() }
        defer {
            if shouldResumeTracking && !isTracking {
                startTracking(showPermissionPrompt: false)
            }
        }

        let hasPreviousDirectory = fileManager.fileExists(atPath: directory.path)
        if hasPreviousDirectory {
            try fileManager.moveItem(at: directory, to: previousDirectory)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: directory)
        } catch {
            if hasPreviousDirectory {
                try? fileManager.moveItem(at: previousDirectory, to: directory)
            }
            throw error
        }
        if hasPreviousDirectory {
            try? fileManager.removeItem(at: previousDirectory)
        }

        sessions = orderedSessions
        dayStatsCache = [:]
        for session in orderedSessions { persistV2Evidence(for: session) }
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
        ActivitySessionSnapshot.day(date, sessions: sessions, active: activeSession)
    }

    func sessions(from start: Date, to end: Date) -> [ActivitySession] {
        guard end > start else { return [] }

        var result = sessions.filter { $0.start < end && $0.end > start }
        if let activeSession, activeSession.start < end {
            var snapshot = activeSession
            snapshot.end = max(snapshot.end, Date())
            if snapshot.end > start {
                result.append(snapshot)
            }
        }
        return result.filter { ActivityClassifier.isRecordable(appName: $0.appName, bundleID: $0.bundleID) }.sorted { $0.start < $1.start }
    }

    func allSessionsIncludingActive() -> [ActivitySession] {
        var result = sessions
        if let activeSession {
            var snapshot = activeSession
            snapshot.end = max(snapshot.end, Date())
            result.append(snapshot)
        }
        return result.filter { ActivityClassifier.isRecordable(appName: $0.appName, bundleID: $0.bundleID) }.sorted { $0.start < $1.start }
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
        addWorkspaceObserver(NSWorkspace.sessionDidResignActiveNotification) { store, _ in
            store.closeActiveSession()
        }

        observers.append(ActivityLifecycle.observeTermination(center: appCenter) { [weak self] in
            self?.closeForTermination()
        })
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

    private func newSession(for app: NSRunningApplication) -> ActivitySession? {
        let appName = app.localizedName ?? "未知应用"
        guard ActivityClassifier.isRecordable(appName: appName, bundleID: app.bundleIdentifier ?? "") else { return nil }
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
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        guard windowResult == .success, let window = focusedWindow else { return nil }

        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(window, to: AXUIElement.self)
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

        var failureSummary: String?
        for segment in segments {
            if !persist(segment), failureSummary == nil {
                failureSummary = storageSummary
            }
        }
        if !ActivityV2Projection.rebuildDay(
            sessions.filter { $0.dayKey == original.dayKey },
            into: v2Store
        ) {
            failureSummary = "V2 事实库投影写入失败：\(v2Store.lastError ?? "未知错误")"
        }
        lastSavedAt = Date()
        lastSavedApp = original.appName
        Set(segments.map(\.dayKey)).forEach { dayStatsCache.removeValue(forKey: $0) }
        storageSummary = failureSummary ?? "已加密保存 \(sessions.count) 段实时活动（最近 365 天）"
    }

    /// Returns false when the segment did not reach disk (or was refused to
    /// protect an unreadable day file); `storageSummary` then carries the reason.
    private func persist(_ session: ActivitySession) -> Bool {
        guard let directory = activityDirectory else { return false }
        do {
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let url = directory.appendingPathComponent("\(session.dayKey).activity")
            switch readDayFile(from: url) {
            case .sessions(let existing):
                var daySessions = existing.filter { $0.id != session.id }
                daySessions.append(session)
                daySessions.sort { $0.start < $1.start }
                try writeDayFile(daySessions, to: url)
            case .unreadable:
                // 我们无法解密这份既有日文件时，绝不能用"仅含新片段"的文件覆盖它——
                // 那会静默抹掉当天全部记录。改为隔离原文件并放弃本次写盘。
                let quarantined = quarantineCorruptFile(at: url)
                storageSummary = "实时足迹文件无法解密，已隔离为 \(quarantined)；本段仅保留在内存中。"
                return false
            }
            persistV2Evidence(for: session)
            return true
        } catch {
            storageSummary = "实时足迹保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Mirror collector evidence into the append-only V2 fact layer. The
    /// encrypted activity files remain the current read path while the
    /// Episode/Memory projections are introduced incrementally.
    private func persistV2Evidence(for session: ActivitySession) {
        let event = RawEvent(
            id: session.id,
            timestamp: session.start,
            source: .systemApp,
            kind: .appForeground,
            payload: RawEventPayload(
                appName: session.appName,
                bundleID: session.bundleID,
                windowTitle: capturesTitles ? session.windowTitle : nil
            ),
            sourceHash: "\(session.bundleID)|\(session.start.timeIntervalSince1970)|\(session.end.timeIntervalSince1970)"
        )
        if !v2Store.insertRawEvent(event) {
            storageSummary = "V2 事实库写入失败：\(v2Store.lastError ?? "未知错误")"
        }
    }

    private enum DayFileReadResult {
        case sessions([ActivitySession])
        /// 文件存在但无法解密或解码。这与"空白天"完全不同：绝不能当作空数据处理，
        /// 否则保留期清理会删除它、persist 会覆盖它，导致当天全部记录丢失。
        case unreadable
    }

    private func readDayFile(from url: URL) -> DayFileReadResult {
        guard fileManager.fileExists(atPath: url.path) else { return .sessions([]) }
        guard let raw = try? Data(contentsOf: url),
              let decrypted = try? StateEncryption.decrypt(raw) else { return .unreadable }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([ActivitySession].self, from: decrypted) else { return .unreadable }
        return .sessions(decoded)
    }

    private func writeDayFile(_ daySessions: [ActivitySession], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encrypted = try StateEncryption.encrypt(try encoder.encode(daySessions))
        try encrypted.write(to: url, options: .atomic)
        try LocalStorageProtection.protectFile(at: url)
    }

    /// 把无法解密的日文件改名隔离而不是删除：字节仍在磁盘上，
    /// 密钥找回后仍可手工恢复。隔离名冲突时追加序号，绝不覆盖。
    private func quarantineCorruptFile(at url: URL) -> String {
        var target = url.appendingPathExtension("corrupt")
        var counter = 1
        while fileManager.fileExists(atPath: target.path) {
            target = URL(fileURLWithPath: url.path + ".corrupt-\(counter)")
            counter += 1
        }
        do {
            try fileManager.moveItem(at: url, to: target)
            try? LocalStorageProtection.protectFile(at: target)
        } catch {
            // 连改名都失败时，原地保留原文件——删除是更坏的选择。
            return url.lastPathComponent
        }
        return target.lastPathComponent
    }

    private func loadStoredSessions() {
        guard let directory = activityDirectory,
              let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -365, to: Date()) ?? Date()
        var loaded: [ActivitySession] = []
        var quarantinedCount = 0

        for file in files where file.pathExtension == "activity" {
            switch readDayFile(from: file) {
            case .sessions(let daySessions):
                let kept = daySessions.filter { $0.end >= cutoff }
                loaded.append(contentsOf: kept)

                // 超过保留期的文件不再继续留在磁盘上，避免旧数据越积越多。
                if kept.count != daySessions.count {
                    if kept.isEmpty {
                        try? fileManager.removeItem(at: file)
                    } else {
                        try? writeDayFile(kept, to: file)
                    }
                }
            case .unreadable:
                // 解密失败通常意味着密钥丢失或被重建：隔离文件保留密文，
                // 等待人工恢复，而不是把用户数据静默清空。
                _ = quarantineCorruptFile(at: file)
                quarantinedCount += 1
            }
        }

        sessions = loaded.sorted { $0.start < $1.start }
        for session in sessions {
            persistV2Evidence(for: session)
        }
        let grouped = Dictionary(grouping: sessions, by: \.dayKey)
        var projectionFailedDays = 0
        for daySessions in grouped.values {
            if !ActivityV2Projection.rebuildDay(daySessions, into: v2Store) {
                projectionFailedDays += 1
            }
        }
        var summary: String
        if quarantinedCount > 0 {
            summary = "有 \(quarantinedCount) 个实时足迹文件无法解密，已隔离保留在磁盘上；其余 \(sessions.count) 段记录已加载。"
        } else {
            summary = sessions.isEmpty
                ? "尚未开始 macOS 实时记录"
                : "已加密保存 \(sessions.count) 段实时活动（最近 365 天）"
        }
        if projectionFailedDays > 0 {
            summary += "；\(projectionFailedDays) 天的 V2 投影写入失败。"
        }
        storageSummary = summary
    }
}

private struct CachedDayStats {
    var fingerprint: String
    var stats: FusedDayStats
}
