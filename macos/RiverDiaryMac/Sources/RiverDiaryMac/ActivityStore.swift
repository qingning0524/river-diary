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

        segments.forEach { persist($0) }
        ActivityV2Projection.rebuildDay(
            sessions.filter { $0.dayKey == original.dayKey },
            into: v2Store
        )
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
            try LocalStorageProtection.protectFile(at: url)
            persistV2Evidence(for: session)
        } catch {
            storageSummary = "实时足迹保存失败：\(error.localizedDescription)"
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
        _ = v2Store.insertRawEvent(event)
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
        for session in sessions {
            persistV2Evidence(for: session)
        }
        let grouped = Dictionary(grouping: sessions, by: \.dayKey)
        for daySessions in grouped.values {
            ActivityV2Projection.rebuildDay(daySessions, into: v2Store)
        }
        storageSummary = sessions.isEmpty
            ? "尚未开始 macOS 实时记录"
            : "已加密保存 \(sessions.count) 段实时活动（最近 365 天）"
    }
}

private struct CachedDayStats {
    var fingerprint: String
    var stats: FusedDayStats
}
