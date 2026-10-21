import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import RiverDiaryCore

// MARK: - Store

@MainActor
final class ActivityStore: ObservableObject {
    static let schemaVersion = 4

    /// 应用 → 类别 的人工映射（小写 bundleID → 类别），存在 UserDefaults。
    /// 关键词分类器认不出的应用（本机 17 天里专注类前台合计只有 4 分钟）由
    /// 用户指认一次，**读时推导**让全部历史即时生效：原始日文件与 V2 证据
    /// 都不回写，删掉映射会干净地回到自动分类。
    private static let categoryOverridesKey = "activity.categoryOverrides"

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
    /// 键盘/鼠标空闲超过阈值。空闲时关闭当前片段，恢复输入后开新片段；
    /// 这样“屏幕时间”不会把挂着不用的窗口算成使用。
    @Published private(set) var isIdle = false

    private var dayStatsCache: [String: CachedDayStats] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pauseTimer: Timer?
    private var idleTimer: Timer?
    private static let idleThreshold: TimeInterval = 5 * 60
    /// 窗口标题的周期重采样。只在"开着标题采集 + 已授权"时才存在。
    private var titleTimer: Timer?
    /// 疑似换掉的标题。要连续两次采样都读到它才认账，见 `WindowTitleSampling`。
    private var titleSamplePending: WindowTitleSampling.Pending?
    /// 应用 → 类别 的人工映射（小写 bundleID → 类别）。
    private var categoryOverrides: [String: String] = [:]
    private let preferences: UserDefaults
    private let configuredActivityDirectory: URL?
    private let providedV2Store: V2Store?
    private lazy var v2Store: V2Store = providedV2Store ?? V2Store()
    lazy var syncSettingsStore: SyncSettingsStore = SyncSettingsStore(database: v2Store, sessionActive: accountServicesActive)
    private var syncTimer: Timer?
    private var accountServicesActive: Bool

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
        v2Store: V2Store? = nil,
        startsAutomatically: Bool = true
    ) {
        accountServicesActive = startsAutomatically
        configuredActivityDirectory = activityDirectory
        preferences = userDefaults
        providedV2Store = v2Store
        pauseScheduleEnabled = userDefaults.bool(forKey: "activity.pauseScheduleEnabled")
        pauseStartMinutes = userDefaults.object(forKey: "activity.pauseStart") as? Int ?? 22 * 60
        pauseEndMinutes = userDefaults.object(forKey: "activity.pauseEnd") as? Int ?? 7 * 60
        capturesTitles = userDefaults.bool(forKey: "activity.capturesTitles")
        accessibilityGranted = AXIsProcessTrusted()
        loadCategoryOverrides()
        loadStoredSessions()
        if startsAutomatically && userDefaults.bool(forKey: "activity.enabled") {
            startTracking(showPermissionPrompt: false)
        }
        refreshPauseState()
    }

    #if DEBUG
    func installSoftVisualSession() {
        guard MacSoftVisualSession.isActive else { return }
        sessions = MacSoftVisualSession.sessions
        dayStatsCache.removeAll()
    }
    #endif

    func startAutomaticSync() {
        guard accountServicesActive, syncTimer == nil else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, syncSettingsStore.folderName != nil else { return }
                syncSettingsStore.synchronize()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, accountServicesActive, syncSettingsStore.folderName != nil else { return }
            syncSettingsStore.synchronize()
        }
    }

    func setAccountServicesActive(_ active: Bool) {
        accountServicesActive = active
        syncSettingsStore.setSessionActive(active)
        if active {
            if preferences.bool(forKey: "activity.enabled") { startTracking(showPermissionPrompt: false) }
            startAutomaticSync()
        } else {
            syncTimer?.invalidate()
            syncTimer = nil
            stopTracking(persistPreference: false)
        }
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

    func replicationDatabase() -> V2Store { v2Store }

    @discardableResult
    func replicateQuickCapture(_ capture: QuickCapture) -> Bool {
        if matchingQuickCaptureEvent(for: capture) != nil { return true }
        let payload = RawEventPayload(text: capture.text)
        let sourceKey = "quick-capture|\(capture.id.uuidString)|\(capture.createdAt.timeIntervalSince1970.bitPattern)|\(capture.text)"
        return v2Store.insertRawEvent(RawEvent(
            id: capture.id,
            timestamp: capture.createdAt,
            source: .manual,
            kind: .quickCapture,
            payload: payload,
            sourceHash: SHA256Hex.hash(Data(sourceKey.utf8))
        ))
    }

    @discardableResult
    func tombstoneQuickCapture(_ capture: QuickCapture) -> Bool {
        guard let event = matchingQuickCaptureEvent(for: capture) else { return false }
        let id = event.id
        let targetID = "event:\(id.uuidString)"
        let operations = v2Store.allStateOperations()
        if !StateOperationResolver.tombstonedObjectIDs(operations).contains(targetID) {
            guard v2Store.rawEvents(ids: [id]).first != nil,
                  let deviceID = v2Store.localDeviceIdentifier(),
                  let payload = try? JSONEncoder().encode(true) else { return false }
            let operationID = RiverStableIdentifier.uuid(
                namespace: "quick-capture.tombstone.\(deviceID.rawValue)",
                key: id.uuidString.lowercased()
            )
            guard v2Store.appendStateOperation(
                id: operationID,
                targetID: targetID,
                fieldKey: "deleted",
                operationType: "object.tombstone",
                payload: payload
            ) != nil else { return false }
        }
        if let existing = v2Store.sharedUserRecords().first(where: {
            $0.kind == .quickCaptureMetadata && $0.logicalKey == id.uuidString.lowercased() && $0.status == "current"
        }), let metadata = existing.quickCaptureMetadata,
           let deletedMetadata = RiverSharedStateRecord.quickCaptureMetadata(
            RiverQuickCaptureMetadata(eventID: id, tag: metadata.tag, isPinned: metadata.isPinned, updatedAt: Date()),
            status: "deleted"
           ) {
            _ = v2Store.saveSharedUserRecord(deletedMetadata)
        }
        return true
    }

    private func matchingQuickCaptureEvent(for capture: QuickCapture) -> RawEvent? {
        if let exact = v2Store.rawEvents(ids: [capture.id]).first {
            let isQuickCapture = ["quickCapture", "manual.quickCapture", "manual.note"].contains(exact.persistedKind)
            return isQuickCapture && exact.payload.text == capture.text && exact.timestamp == capture.createdAt
                ? exact : nil
        }
        return v2Store.allRawEvents()
            .filter {
                ["quickCapture", "manual.quickCapture", "manual.note"].contains($0.persistedKind)
                    && $0.payload.text == capture.text
                    && abs($0.timestamp.timeIntervalSince(capture.createdAt)) < 60
            }
            .min {
                let leftDistance = abs($0.timestamp.timeIntervalSince(capture.createdAt))
                let rightDistance = abs($1.timestamp.timeIntervalSince(capture.createdAt))
                if leftDistance != rightDistance { return leftDistance < rightDistance }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    @discardableResult
    func generateDiagnosticTestEvent() -> Bool {
        v2Store.insertRawEvent(RawEvent(
            source: .manual,
            kind: .quickCapture,
            payload: RawEventPayload(text: "Developer Diagnostics test event")
        ))
    }

    func rebuildDiagnosticProjections() throws -> Int {
        try v2Store.rebuildDerivedState()
        let sessionCount = SessionBuilder.build(v2Store.effectiveRawEvents().compactMap { $0.replica() }).count
        NotificationCenter.default.post(name: .riverCanonicalSyncDidChange, object: nil)
        return sessionCount
    }

    func startTracking(showPermissionPrompt: Bool = true) {
        guard accountServicesActive, !isTracking else { return }

        isTracking = true
        preferences.set(true, forKey: "activity.enabled")

        if showPermissionPrompt && capturesTitles && !accessibilityGranted {
            requestAccessibility()
        }

        registerObservers()

        if let app = NSWorkspace.shared.frontmostApplication {
            activeSession = newSession(for: app)
        }

        storageSummary = "事件驱动记录已开启；片段会在应用切换、空闲或退出后保存。"
        startPauseTimer()
        startIdleTimer()
        startTitleSampling()
        refreshPauseState()
    }

    func stopTracking(persistPreference: Bool = true) {
        guard isTracking else { return }
        closeActiveSession()
        removeObservers()
        isTracking = false
        activeSession = nil
        if persistPreference { preferences.set(false, forKey: "activity.enabled") }
        pauseTimer?.invalidate()
        pauseTimer = nil
        stopIdleTimer()
        isIdle = false
        stopTitleSampling()
        isCurrentlyPaused = false
        storageSummary = "已停止 macOS 实时记录。"
    }

    /// 记录状态的一句话。开关一开一关都能读到"标题到底有没有在采"，
    /// 而不是只能去设置里翻权限。
    var trackingSummary: String {
        guard isTracking else { return "实时记录已暂停" }
        if isIdle { return "当前空闲，片段已暂停；有输入后恢复" }
        if !capturesTitles { return "正在保存应用切换片段（未记录窗口标题）" }
        return accessibilityGranted
            ? "正在保存应用切换片段，标题每 25 秒刷新一次"
            : "正在保存应用切换片段（辅助功能未授权，读不到标题）"
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
        let now = Date()
        let minute = Calendar.current.component(.minute, from: now) + Calendar.current.component(.hour, from: now) * 60
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

    private func startIdleTimer() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// 用系统 HID 空闲时间判断“人还在不在”。不需要辅助功能或输入监控权限：
    /// 只读“距上一次输入多少秒”，不读按了什么键。
    private func checkIdle() {
        guard isTracking else { return }
        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .null)
        guard idleSeconds.isFinite, idleSeconds >= 0 else { return }

        let nowIdle = idleSeconds >= Self.idleThreshold
        if nowIdle, !isIdle {
            isIdle = true
            // 片段结束在最后一次输入，而不是发现空闲的这一刻。
            closeActiveSession(at: Date().addingTimeInterval(-idleSeconds))
        } else if !nowIdle, isIdle {
            isIdle = false
            guard !isCurrentlyPaused, activeSession == nil,
                  let app = NSWorkspace.shared.frontmostApplication else { return }
            activeSession = newSession(for: app)
        }
    }

    func refreshPauseState() {
        let wasPaused = isCurrentlyPaused
        let paused = isTracking && pauseScheduleEnabled && isWithinPauseWindow
        isCurrentlyPaused = paused
        if paused, activeSession != nil {
            closeActiveSession()
        }
        // 暂停窗口结束时立即恢复记录：依赖下一次应用切换会让
        // "暂停期间一直停留在同一个应用"的用户静默丢失整段时间。
        if wasPaused, !paused, isTracking, activeSession == nil {
            startSessionAfterWake()
        }
    }

    func setCapturesTitles(_ enabled: Bool) {
        capturesTitles = enabled
        preferences.set(enabled, forKey: "activity.capturesTitles")
        if enabled {
            startTitleSampling()
        } else {
            activeSession?.windowTitle = nil
            titleSamplePending = nil
            stopTitleSampling()
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        startTitleSampling()
    }

    func refreshAccessibility() {
        let wasGranted = accessibilityGranted
        accessibilityGranted = AXIsProcessTrusted()
        startTitleSampling()
        // 刚拿到权限：这一段还在前台，立刻补上标题，不用等下一次采样。
        if accessibilityGranted, !wasGranted { sampleActiveWindowTitle() }
    }

    // MARK: 应用 → 类别 映射

    private func loadCategoryOverrides() {
        guard let raw = preferences.dictionary(forKey: Self.categoryOverridesKey) as? [String: String] else { return }
        categoryOverrides = raw
    }

    /// 当前某应用的人工类别（nil = 跟随自动分类）。
    func categoryOverride(forBundleID bundleID: String) -> String? {
        categoryOverrides[bundleID.lowercased()]
    }

    /// 指认一个应用的类别；传 nil 表示撤销、回到自动。
    /// 映射是**读时推导**：原始文件与 V2 证据不回写，这里只重算内存里的会话，
    /// 全部历史（时间线、统计、复盘、导出）立即生效。
    func setCategoryOverride(_ category: String?, forBundleID bundleID: String) {
        let key = bundleID.lowercased()
        if let category, !category.isEmpty {
            categoryOverrides[key] = category
        } else {
            categoryOverrides.removeValue(forKey: key)
        }
        preferences.set(categoryOverrides, forKey: Self.categoryOverridesKey)
        dayStatsCache = [:]
        sessions = sessions.map(effectiveSession)
        if let activeSession { self.activeSession = effectiveSession(activeSession) }
    }

    /// 生效类别：人工映射优先；没有映射就按 应用名+标题 重新推导。重推导而不是
    /// 沿用文件里存的类别，是为了让两件事都成立——删掉映射能回到自动分类，
    /// 分类器词表改进也对历史生效（类别本来就是可以从已存的字段里重算出来的）。
    private func effectiveSession(_ session: ActivitySession) -> ActivitySession {
        var session = session
        if let override = categoryOverrides[session.bundleID.lowercased()] {
            session.category = override
        } else {
            session.category = ActivityClassifier.category(appName: session.appName, title: session.windowTitle)
        }
        return session
    }

    /// 设置页的应用清单：按已记录时长排序、按 bundleID 去重（同一应用换过名字
    /// 显示最常用的一次）。只列真实用过的应用——让用户从自己的使用里指认，
    /// 而不是对着一张空表。
    func categoryAppOptions(limit: Int = 12) -> [(bundleID: String, appName: String, duration: TimeInterval)] {
        var durations: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        for session in sessions {
            let key = session.bundleID.lowercased()
            durations[key, default: 0] += session.duration
            names[key, default: session.appName] = session.appName
        }
        return durations
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { (bundleID: $0.key, appName: names[$0.key] ?? $0.key, duration: $0.value) }
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

        for (dayKey, daySessions) in Dictionary(grouping: orderedSessions, by: \.dayKey).sorted(by: { $0.key < $1.key }) {
            try writeDayFile(daySessions.sorted { $0.start < $1.start }, to: stagingDirectory.appendingPathComponent("\(dayKey).activity"))
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
        for session in orderedSessions { persistV2Evidence(for: session) }
        sessions = sessions.map(effectiveSession)
        dayStatsCache = [:]
        storageSummary = "已恢复并加密保存 \(sessions.count) 段实时活动"
    }

    /// 恢复备份后把 V2 的活动证据与恢复后的实时层对齐：清掉实时活动证据，
    /// 再按当前会话重建投影。带 V2 快照的备份会整体换文件（此调用等价于
    /// 幂等重建）；不带 V2 快照的 legacy 备份此前会把恢复前的旧证据
    /// 留在 V2 里，与实时层悄悄分叉。
    func rebuildV2EvidenceAfterRestore() {
        guard v2Store.clearActivityEvidence() else {
            storageSummary = "V2 证据重建失败：\(v2Store.lastError ?? "未知错误")"
            return
        }
        var byDay: [String: [ActivitySession]] = [:]
        for session in sessions { byDay[session.dayKey, default: []].append(session) }
        for dayKey in byDay.keys.sorted() {
            if !ActivityV2Projection.rebuildDay(byDay[dayKey] ?? [], into: v2Store) {
                storageSummary = "V2 证据重建失败：\(v2Store.lastError ?? "未知错误")"
                return
            }
        }
    }

    func clearActivity() {
        stopTracking()
        sessions = []
        dayStatsCache = [:]
        if let directory = activityDirectory {
            try? fileManager.removeItem(at: directory)
        }
        // 事实层里同一内容的副本必须一起清掉，否则用户以为足迹已删除，
        // V2 数据库里却留有完整副本（隐私承诺与行为一致）。
        if v2Store.clearActivityEvidence() {
            storageSummary = "已清除 macOS 实时足迹。"
        } else {
            storageSummary = "本地足迹已清除；V2 事实库清理失败：\(v2Store.lastError ?? "未知错误")"
        }
    }

    func liveSessions(for date: Date) -> [ActivitySession] {
        ActivitySessionSnapshot.day(date, sessions: sessions, active: activeSession)
    }

    func sessions(from start: Date, to end: Date) -> [ActivitySession] {
        guard end > start else { return [] }

        var result = sessions.compactMap { session -> ActivitySession? in
            // 边界会话必须裁剪到窗口内：习惯候选、周期复盘都直接累加这里的
            // 时长，不裁剪会让窗口左缘的会话整段多算。
            guard session.start < end, session.end > start else { return nil }
            var clipped = session
            clipped.start = max(session.start, start)
            clipped.end = min(session.end, end)
            return clipped.end > clipped.start ? clipped : nil
        }
        if let activeSession, activeSession.start < end {
            var snapshot = activeSession
            snapshot.end = max(snapshot.end, Date())
            snapshot.start = max(snapshot.start, start)
            if snapshot.end > snapshot.start {
                result.append(snapshot)
            }
        }
        result.append(contentsOf: synchronizedPhoneSessions(from: start, to: end))
        return result.filter { ActivityClassifier.isRecordable(appName: $0.appName, bundleID: $0.bundleID) }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
    }

    func locationMarkers(for date: Date) -> [ActivityTimelinePlaceMarker] {
        #if DEBUG
        if MacSoftVisualSession.isActive && Calendar.current.isDate(date, inSameDayAs: MacSoftVisualSession.date) {
            return MacSoftVisualSession.placeMarkers
        }
        #endif
        guard let day = Calendar.current.dateInterval(of: .day, for: date) else { return [] }
        let places = v2Store.places()
        let meaningfulKinds: Set<String> = [
            "location.visit.arrival", "location.visit.departure", "location.significant"
        ]
        return v2Store.rawEvents(between: day.start, end: day.end).compactMap { event in
            guard event.timestamp < day.end else { return nil }
            guard meaningfulKinds.contains(event.persistedKind),
                  let replica = event.replica(),
                  let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: replica.payload) else { return nil }
            let place = nearestPlace(to: payload, in: places)
            let resolvedName = place?.userDefinedName ?? place?.mapName ?? payload.locationName
            let name = resolvedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kindLabel: String
            switch event.persistedKind {
            case "location.visit.arrival": kindLabel = "到达"
            case "location.visit.departure": kindLabel = "离开"
            default: kindLabel = "移动到"
            }
            let title = name.map { "\(kindLabel) \($0)" } ?? "\(kindLabel)一个地点"
            let detail = [
                place?.semanticType,
                place?.mapAddress ?? payload.mapAddress,
                event.originDeviceID.map { "来自 \($0.rawValue)" }
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            return ActivityTimelinePlaceMarker(
                id: event.id,
                time: event.timestamp,
                title: title,
                detail: detail.isEmpty ? "位置事件 · \(event.persistedKind)" : detail,
                originDeviceID: event.originDeviceID?.rawValue ?? "未知设备",
                latitude: payload.latitude,
                longitude: payload.longitude
            )
        }
    }

    private func nearestPlace(to payload: RiverEventPayload, in places: [RiverPlace]) -> RiverPlace? {
        guard let latitude = payload.latitude, let longitude = payload.longitude else { return nil }
        return places.compactMap { place -> (RiverPlace, Double)? in
            let distance = Self.distanceMeters(latitude, longitude, place.latitude, place.longitude)
            return distance <= max(250, place.radiusMeters + 50) ? (place, distance) : nil
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 < rhs.1
        }.first?.0
    }

    private static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let earth = 6_371_000.0
        let latitude1 = lat1 * .pi / 180
        let latitude2 = lat2 * .pi / 180
        let deltaLatitude = (lat2 - lat1) * .pi / 180
        let deltaLongitude = (lon2 - lon1) * .pi / 180
        let a = sin(deltaLatitude / 2) * sin(deltaLatitude / 2)
            + cos(latitude1) * cos(latitude2) * sin(deltaLongitude / 2) * sin(deltaLongitude / 2)
        return earth * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    private func synchronizedPhoneSessions(from start: Date, to end: Date) -> [ActivitySession] {
        guard let localDevice = v2Store.localDeviceIdentifier() else { return [] }
        let repairWindowStart = start.addingTimeInterval(-2 * 60 * 60)
        let events = v2Store.rawEvents(between: repairWindowStart, end: end).compactMap { $0.replica() }
        return SessionBuilder.build(events)
            .filter { $0.originDeviceID != localDevice && $0.end != nil && $0.start < end && ($0.end ?? $0.start) > start }
            .compactMap { session in
                guard let sessionEnd = session.end else { return nil }
                let id = UUID(uuidString: session.id.replacingOccurrences(of: "session:", with: "")) ?? UUID()
                return ActivitySession(
                    id: id,
                    appName: session.displayName,
                    bundleID: session.applicationIdentifier,
                    windowTitle: nil,
                    category: ActivityClassifier.category(appName: session.displayName, title: nil),
                    start: max(session.start, start),
                    end: min(sessionEnd, end),
                    originDeviceID: session.originDeviceID.rawValue,
                    evidenceQuality: String(session.quality.rawValue),
                    endReason: session.endReason.rawValue
                )
            }
    }

    /// 审计回归测试专用：直接替换内存会话（不经持久化、不写 V2）。
    func injectSessionsForAudit(_ newSessions: [ActivitySession]) {
        sessions = newSessions
        dayStatsCache = [:]
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
        let focusBlocks = FocusCalculator.blocks(from: todaySessions)

        return ScreenTimeSnapshot(
            totalMinutes: Int(totalSeconds / 60),
            topApps: Array(topApps),
            focusMinutes: focusBlocks.reduce(0) { $0 + $1.minutes },
            focusBlocks: focusBlocks.count
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

        // 用户很可能刚从"系统设置 > 隐私与安全性 > 辅助功能"里回来：一回到前台就
        // 重新查一遍权限。让用户按"刷新"才知道自己已经授权过了，是没必要的作业。
        observers.append(appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAccessibility() }
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
        guard isTracking, !isCurrentlyPaused, !isIdle, activeSession == nil,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        activeSession = newSession(for: app)
    }

    private func switchTo(_ app: NSRunningApplication) {
        guard !isCurrentlyPaused else { return }
        if isIdle { isIdle = false }
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
        return effectiveSession(ActivitySession(
            appName: appName,
            bundleID: app.bundleIdentifier ?? appName,
            windowTitle: capturesTitles ? title : nil,
            category: ActivityClassifier.category(appName: appName, title: title),
            start: Date(),
            end: Date()
        ))
    }

    private func currentTitle(for app: NSRunningApplication) -> String? {
        guard capturesTitles, accessibilityGranted else { return nil }
        return Self.readWindowTitleSync(processIdentifier: app.processIdentifier)
    }

    // MARK: 窗口标题重采样

    /// 采样定时器。只在"记录中 + 开着标题采集 + 已授权"时存在：没有权限时每
    /// 25 秒问一次辅助功能，除了耗电什么都得不到。
    private func startTitleSampling() {
        titleTimer?.invalidate()
        titleTimer = nil
        guard isTracking, capturesTitles, accessibilityGranted else { return }
        titleTimer = Timer.scheduledTimer(withTimeInterval: WindowTitleSampling.interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleActiveWindowTitle() }
        }
    }

    private func stopTitleSampling() {
        titleTimer?.invalidate()
        titleTimer = nil
    }

    /// 每 25 秒再看一眼当前窗口标题。
    ///
    /// 读辅助功能放在主线程之外：那是一次带 0.25 秒超时的同步调用，目标应用卡住时
    /// 会把主线程按住——一个每 25 秒卡半秒的采样器比不采样更糟。决策本身是纯的，
    /// 在 `applySampledTitle` 里回到主线程做。
    func sampleActiveWindowTitle() {
        guard isTracking, !isCurrentlyPaused, capturesTitles, accessibilityGranted,
              let session = activeSession,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == session.bundleID else { return }
        let pid = app.processIdentifier
        Task { @MainActor [weak self] in
            let title = await Self.readWindowTitle(processIdentifier: pid)
            self?.applySampledTitle(title, now: Date())
        }
    }

    private func applySampledTitle(_ title: String?, now: Date) {
        guard let session = activeSession else { return }
        // 采样跨越了 ~0.5s 的 AX 调用，期间用户可能已经切走应用。
        // 不再校验 frontmost 就会把上一个应用的标题 adopt 到当前会话，
        // 并随会话持久化、永久带偏类别与"需要确认"判据。
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != session.bundleID {
            return
        }
        let decision = WindowTitleSampling.decide(
            currentTitle: session.windowTitle,
            pending: titleSamplePending,
            sampled: title,
            now: now
        )
        titleSamplePending = decision.pending
        switch decision.action {
        case .ignore:
            break
        case .adopt(let adopted):
            activeSession?.windowTitle = adopted
        case .split(let moment, let title):
            splitActiveSession(at: moment, windowTitle: title)
        }
    }

    /// 同一个应用里换了标题：从第一次看到新标题的那一刻切开，而不是把标题盖掉。
    /// 40 分钟的 Chrome 前半截是文档、后半截是视频，合并成一段时行上的标题
    /// 对其中一半时间就是假的。
    private func splitActiveSession(at moment: Date, windowTitle: String) {
        guard let session = activeSession else { return }
        let now = Date()
        let (closed, next) = session.split(at: moment, now: now, windowTitle: windowTitle)
        activeSession = nil
        if closed.duration >= 1 { appendSegments(splitAtDayBoundary(closed)) }
        activeSession = effectiveSession(next)
        titleSamplePending = nil
    }

    /// 同步读标题，供应用切换的那一刻使用（那里拿不到 async）。
    nonisolated private static func readWindowTitleSync(processIdentifier: pid_t) -> String? {
        let application = AXUIElementCreateApplication(processIdentifier)
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

    /// 读到主线程之外执行的那一份。`nonisolated async` 不继承调用方的 actor，
    /// 所以这里的 AX 调用不会占住主线程。
    nonisolated private static func readWindowTitle(processIdentifier: pid_t) async -> String? {
        readWindowTitleSync(processIdentifier: processIdentifier)
    }

    private func closeActiveSession() {
        closeActiveSession(at: Date())
    }

    private func closeActiveSession(at moment: Date) {
        guard var session = activeSession else { return }
        session.end = max(moment, session.start)
        activeSession = nil
        titleSamplePending = nil

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
        // 跨午夜切分会产出两个本地日的段：每个受影响的日子都要重建投影，
        // 否则后一天的 V2 行要等到下次启动 loadStoredSessions 才补齐。
        var rebuildFailed = false
        for dayKey in Set(segments.map(\.dayKey)).sorted() {
            if !ActivityV2Projection.rebuildDay(
                sessions.filter { $0.dayKey == dayKey },
                into: v2Store
            ) {
                rebuildFailed = true
            }
        }
        if rebuildFailed {
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
                windowTitle: capturesTitles ? session.windowTitle : nil,
                sessionEnd: session.end
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
        // V2 投影走**原始**类别（证据不掺解释）；人工映射只作用在内存里的
        // 这一份，供时间线、统计、复盘、导出读取。
        sessions = sessions.map(effectiveSession)
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
