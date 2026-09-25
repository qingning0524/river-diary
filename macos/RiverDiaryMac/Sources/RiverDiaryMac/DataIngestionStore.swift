import AppKit
import CryptoKit
import Foundation

enum RetentionPolicy {
    static func requiresConfirmation(currentDays: Int, requestedDays: Int) -> Bool {
        let current = max(0, min(3650, currentDays))
        let requested = max(0, min(3650, requestedDays))
        return requested > 0 && (current == 0 || requested < current)
    }
}

// MARK: - Store

@MainActor
final class DataIngestionStore: ObservableObject {
    // MARK: Published state

    @Published private(set) var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "ingestion.enabled") }
    }

    @Published private(set) var captureHour: Int {
        didSet { UserDefaults.standard.set(captureHour, forKey: "ingestion.captureHour") }
    }

    @Published private(set) var captureMinute: Int {
        didSet { UserDefaults.standard.set(captureMinute, forKey: "ingestion.captureMinute") }
    }

    @Published private(set) var sourceURL: URL? {
        didSet {
            if let path = sourceURL?.path {
                UserDefaults.standard.set(path, forKey: "ingestion.sourcePath")
            } else {
                UserDefaults.standard.removeObject(forKey: "ingestion.sourcePath")
            }
        }
    }

    @Published private(set) var exportURL: URL? {
        didSet {
            if let path = exportURL?.path {
                UserDefaults.standard.set(path, forKey: "ingestion.exportPath")
                UserDefaults.standard.set(true, forKey: "ingestion.exportExplicitlyEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "ingestion.exportPath")
                UserDefaults.standard.set(false, forKey: "ingestion.exportExplicitlyEnabled")
            }
        }
    }

    @Published private(set) var collectsHealth: Bool {
        didSet { UserDefaults.standard.set(collectsHealth, forKey: "ingestion.collectsHealth") }
    }

    @Published private(set) var collectsChrome: Bool {
        didSet { UserDefaults.standard.set(collectsChrome, forKey: "ingestion.collectsChrome") }
    }

    @Published private(set) var collectsNotes: Bool {
        didSet { UserDefaults.standard.set(collectsNotes, forKey: "ingestion.collectsNotes") }
    }

    @Published private(set) var collectsScreenTime: Bool {
        didSet { UserDefaults.standard.set(collectsScreenTime, forKey: "ingestion.collectsScreenTime") }
    }

    @Published private(set) var retentionDays: Int {
        didSet { UserDefaults.standard.set(retentionDays, forKey: "ingestion.retentionDays") }
    }

    @Published private(set) var lastCaptureDate: String?
    @Published private(set) var dailyRecord: DailyCaptureRecord?
    @Published private(set) var lastIngestedAt: Date?
    @Published private(set) var lastSourceModifiedAt: Date?
    @Published private(set) var sourceHash: String
    @Published private(set) var lastStatus: String = "尚未采集"
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning = false
    @Published private(set) var exportMessage: String?

    // MARK: Internal

    weak var targetStore: DiaryStore?
    weak var targetActivity: ActivityStore?
    weak var targetAI: AIAssistantStore?

    private var checkTimer: Timer?
    private var ingestTask: Task<Void, Never>?
    private lazy var v2Store = V2Store()
    private let fileManager = FileManager.default

    private static let defaultSource = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/河流日记/river-diary-user-data.json")

    private static var projectExportURL: URL? {
        let projectRoot = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataDirectory = projectRoot.appendingPathComponent("data", isDirectory: true)
        guard fileManager.fileExists(atPath: dataDirectory.path) else { return nil }
        return dataDirectory.appendingPathComponent("ios-user-data.json")
    }

    private static let fileManager = FileManager.default

    private var dataURL: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Ingestion", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { return nil }
        return directory.appendingPathComponent("daily-capture.bin")
    }

    private var legacyDataURL: URL? {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("RiverDiaryMac", isDirectory: true)
            .appendingPathComponent("Ingestion", isDirectory: true)
            .appendingPathComponent("health-snapshot.bin")
    }

    // MARK: Init

    init() {
        enabled = UserDefaults.standard.object(forKey: "ingestion.enabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "ingestion.enabled")

        captureHour = UserDefaults.standard.object(forKey: "ingestion.captureHour") as? Int ?? 22
        captureMinute = UserDefaults.standard.object(forKey: "ingestion.captureMinute") as? Int ?? 30

        collectsHealth = UserDefaults.standard.object(forKey: "ingestion.collectsHealth") as? Bool ?? true
        collectsChrome = UserDefaults.standard.object(forKey: "ingestion.collectsChrome") as? Bool ?? true
        collectsNotes = UserDefaults.standard.object(forKey: "ingestion.collectsNotes") as? Bool ?? true
        collectsScreenTime = UserDefaults.standard.object(forKey: "ingestion.collectsScreenTime") as? Bool ?? true
        retentionDays = UserDefaults.standard.object(forKey: "ingestion.retentionDays") as? Int ?? 0

        if let saved = UserDefaults.standard.string(forKey: "ingestion.sourcePath"),
           FileManager.default.fileExists(atPath: saved) {
            sourceURL = URL(fileURLWithPath: saved)
        } else if fileManager.fileExists(atPath: Self.defaultSource.path) {
            sourceURL = Self.defaultSource
        } else {
            sourceURL = Self.defaultSource
        }

        sourceHash = UserDefaults.standard.string(forKey: "ingestion.sourceHash") ?? ""
        lastCaptureDate = UserDefaults.standard.string(forKey: "ingestion.lastCaptureDate")

        if let savedExport = UserDefaults.standard.string(forKey: "ingestion.exportPath"),
           !savedExport.isEmpty {
            exportURL = URL(fileURLWithPath: savedExport)
        } else if UserDefaults.standard.object(forKey: "ingestion.exportExplicitlyEnabled") == nil,
                  let projectExport = Self.projectExportURL {
            exportURL = projectExport
        }

        loadPersistedRecord()
        pruneRetention()
        refreshSourceMetadata()
    }

    // MARK: Public interface

    func attach(to store: DiaryStore, activity: ActivityStore, ai: AIAssistantStore) {
        targetStore = store
        targetActivity = activity
        targetAI = ai
        if let record = dailyRecord {
            saveToDatabase(record)
        }
        applyToStore()
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        restartSchedule()
    }

    func setCaptureTime(hour: Int, minute: Int) {
        captureHour = min(23, max(0, hour))
        captureMinute = min(59, max(0, minute))
        restartSchedule()
    }

    func captureTimeLabel() -> String {
        String(format: "%02d:%02d", captureHour, captureMinute)
    }

    func setSourceOptions(health: Bool, chrome: Bool, notes: Bool, screenTime: Bool) {
        collectsHealth = health
        collectsChrome = chrome
        collectsNotes = notes
        collectsScreenTime = screenTime
        lastStatus = "数据源设置已更新。"
    }

    func setRetention(days: Int) {
        retentionDays = max(0, min(3650, days))
        pruneRetention()
    }

    @discardableResult
    func pruneRetention() -> Bool {
        guard retentionDays > 0 else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? Date()
        let cutoffKey = DiaryEntry.dateFormatter.string(from: cutoff)
        let success = AppDatabase.shared.purgeData(before: cutoffKey)
        if success {
            lastStatus = "已保留最近 \(retentionDays) 天数据。"
        }
        return success
    }

    func connectSource(to url: URL) {
        guard fileManager.fileExists(atPath: url.path) else {
            lastError = "数据源文件不存在。"
            return
        }
        sourceURL = url
        sourceHash = ""
        UserDefaults.standard.set("", forKey: "ingestion.sourceHash")
        lastError = nil
        refreshSourceMetadata()
        restartSchedule()
        captureNow()
    }

    func setExportPath(to url: URL) {
        exportURL = url
        exportMessage = "已开启采集快照导出。"
        exportDailyRecord()
    }

    func clearExportPath() {
        exportURL = nil
        exportMessage = "已停止导出。"
    }

    func exportDailyRecord() {
        guard let url = exportURL else {
            exportMessage = "请先选择导出位置。"
            return
        }
        guard let record = dailyRecord else {
            exportMessage = "还没有可导出的每日记录。"
            return
        }
        do {
            if url.pathExtension.lowercased() != "json" {
                throw NSError(domain: "RiverDiaryMac.ingestion", code: 20,
                              userInfo: [NSLocalizedDescriptionKey: "导出文件需要使用 JSON 格式。"])
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: url, options: .atomic)
            exportMessage = "已导出 · \(url.lastPathComponent)"
        } catch {
            exportMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    func start() {
        restartSchedule()
        let today = DiaryEntry.dateFormatter.string(from: Date())
        let shouldRunMissedAnalysis = enabled
            && isPastCaptureTime(Date())
            && targetAI?.needsAutomaticAnalysis(for: today) == true
        captureNow(runsAIAnalysis: shouldRunMissedAnalysis)
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        ingestTask?.cancel()
        ingestTask = nil
        lastStatus = "定时采集已停止"
    }

    func captureNow(runsAIAnalysis: Bool = false) {
        guard !isRunning else { return }
        ingestTask?.cancel()
        ingestTask = Task { await captureDaily(runsAIAnalysis: runsAIAnalysis) }
    }

    // MARK: Scheduling (daily at specific time)

    private func restartSchedule() {
        checkTimer?.invalidate()
        checkTimer = nil

        guard enabled else {
            lastStatus = "定时采集与 AI 分析已关闭"
            return
        }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureTime()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
        lastStatus = "每日 \(captureTimeLabel()) 自动采集与 AI 分析已开启"
    }

    private func checkCaptureTime() {
        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)
        let currentMinute = calendar.component(.minute, from: now)

        guard currentHour == captureHour, currentMinute == captureMinute else { return }

        let todayKey = DiaryEntry.dateFormatter.string(from: now)
        if lastCaptureDate != todayKey {
            captureNow(runsAIAnalysis: true)
        } else if let record = dailyRecord {
            Task { await runAutomaticDailyAnalysis(for: record) }
        }
    }

    private func isPastCaptureTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        var scheduled = components
        scheduled.hour = captureHour
        scheduled.minute = captureMinute
        guard let captureDate = calendar.date(from: scheduled) else { return false }
        return date >= captureDate
    }

    // MARK: Daily capture

    private func captureDaily(runsAIAnalysis: Bool) async {
        guard !isRunning else { return }
        guard let url = sourceURL else {
            lastError = "未设置数据源。"
            return
        }
        guard fileManager.fileExists(atPath: url.path) else {
            lastError = "未找到数据源：\(url.lastPathComponent)"
            refreshSourceMetadata()
            return
        }

        isRunning = true
        defer { isRunning = false }

        do {
            // 1. Read iOS data
            let raw = try Data(contentsOf: url, options: .mappedIfSafe)
            let currentHash = SHA256Hex.hash(raw)

            // Parse iOS JSON in background
            let iosPayload = try await Task.detached(priority: .utility) { () -> [String: Any]? in
                let object = try JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
                return object as? [String: Any]
            }.value

            guard let payload = iosPayload else {
                throw NSError(domain: "RiverDiaryMac.ingestion", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "iOS 数据源必须是 JSON 对象。"])
            }

            // 2. Check if today's iOS data exists
            let today = DiaryEntry.dateFormatter.string(from: Date())
            guard Self.hasTodayData(payload, today: today) else {
                lastError = nil
                lastStatus = "今日 iOS 数据未同步（\(today)），跳过采集。"
                return
            }

            // 3. Clean iOS data and keep earlier iOS days in the database
            let iosData = Self.cleanIOSPayload(payload, syncedAt: Date())
            await Task.detached(priority: .utility) {
                AppDatabase.shared.saveIOSHistory(iosData, excluding: today)
            }.value
            try Task.checkCancellation()

            // 4. Read Chrome history (background)
            let chromeVisits = collectsChrome
                ? await Task.detached(priority: .utility) {
                    ChromeHistoryReader.readTodaysVisits()
                }.value
                : []
            try Task.checkCancellation()

            // 5. Read Apple Notes (background)
            let notes = collectsNotes
                ? await Task.detached(priority: .utility) {
                    AppleNotesReader.readTodaysNotes()
                }.value
                : []
            try Task.checkCancellation()

            // 6. Screen time from ActivityStore
            let screenSnapshot = collectsScreenTime ? targetActivity?.screenTimeSnapshot() : nil

            // 7. Build daily record
            var record = Self.buildDailyRecord(
                date: today,
                ios: iosData,
                chrome: chromeVisits,
                notes: notes,
                screen: screenSnapshot
            )

            if !collectsHealth {
                record.moodScore = nil
                record.sleepHours = nil
                record.sleepDeepMinutes = nil
                record.sleepREMMinutes = nil
                record.exerciseSteps = nil
                record.exerciseDistanceKM = nil
                record.exerciseEnergyKcal = nil
                record.quickNotes = []
                record.iosDataAvailable = false
            }

            // 8. Persist encrypted and save the raw records into the database
            try persist(record)
            persistV2Snapshot(record, sourceHash: currentHash)
            if !saveToDatabase(record) {
                throw NSError(domain: "RiverDiaryMac.ingestion", code: 21,
                              userInfo: [NSLocalizedDescriptionKey: "今日数据未能写入数据库，请稍后重试。原始记录已保留在本机。".trimmingCharacters(in: .whitespaces)])
            }
            pruneRetention()

            // 9. Update state
            dailyRecord = record
            sourceHash = currentHash
            lastIngestedAt = Date()
            refreshSourceMetadata()
            lastCaptureDate = today
            UserDefaults.standard.set(today, forKey: "ingestion.lastCaptureDate")
            UserDefaults.standard.set(currentHash, forKey: "ingestion.sourceHash")
            lastError = nil
            lastStatus = "采集完成 · \(record.summary)"

            // 10. Export if configured
            if exportURL != nil {
                exportDailyRecord()
            }

            // 11. Apply to store
            applyToStore()

            // 12. Run the scheduled daily AI analysis after the day is captured.
            if runsAIAnalysis {
                await runAutomaticDailyAnalysis(for: record)
            }

        } catch is CancellationError {
            lastError = nil
            lastStatus = "采集已取消。"
        } catch {
            lastError = UserFacingError.message(for: error)
            lastStatus = "采集失败"
        }
    }

    private func persist(_ record: DailyCaptureRecord) throws {
        guard let url = dataURL else {
            throw NSError(domain: "RiverDiaryMac.ingestion", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建本地存储目录。"])
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(record)
        try StateEncryption.encrypt(plaintext).write(to: url, options: .atomic)
    }

    private func persistV2Snapshot(_ record: DailyCaptureRecord, sourceHash: String) {
        let event = RawEvent(
            timestamp: record.capturedAt,
            source: .ingestion,
            kind: .ingestionSnapshot,
            payload: RawEventPayload(
                metrics: RawEventMetrics(
                    steps: record.exerciseSteps,
                    distanceKm: record.exerciseDistanceKM,
                    activeEnergyKcal: record.exerciseEnergyKcal,
                    sleepHours: record.sleepHours,
                    screenMinutes: record.screenTimeMinutes
                )
            ),
            sourceHash: sourceHash
        )
        _ = v2Store.insertRawEvent(event)
    }

    private func loadPersistedRecord() {
        // Try new format first
        if let url = dataURL, fileManager.fileExists(atPath: url.path) {
            do {
                let encrypted = try Data(contentsOf: url)
                let plaintext = try StateEncryption.decrypt(encrypted)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let record = try decoder.decode(DailyCaptureRecord.self, from: plaintext)
                dailyRecord = record
                lastIngestedAt = record.capturedAt
                lastCaptureDate = record.date
                lastStatus = "已加载上次采集结果 · \(record.summary)"
                saveToDatabase(record)
                return
            } catch {
                // Fall through to legacy
            }
        }

        // Legacy format
        if let legacyURL = legacyDataURL, fileManager.fileExists(atPath: legacyURL.path) {
            do {
                let encrypted = try Data(contentsOf: legacyURL)
                let plaintext = try StateEncryption.decrypt(encrypted)
                let decoded = try JSONDecoder().decode(IngestedUserData.self, from: plaintext)
                lastIngestedAt = decoded.syncedAt
                lastStatus = "已加载旧版采集结果 · \(decoded.summary)"
            } catch {
                lastError = "旧版采集数据无法读取。"
            }
        }
    }

    @discardableResult
    private func saveToDatabase(_ record: DailyCaptureRecord) -> Bool {
        let sessions = targetActivity?.liveSessions(for: Date()) ?? []
        return AppDatabase.shared.saveDailyCapture(
            record,
            sessions: sessions,
            collectedChrome: collectsChrome,
            collectedNotes: collectsNotes,
            collectedHealth: collectsHealth,
            collectedScreenTime: collectsScreenTime
        )
    }

    private func applyToStore() {
        guard let record = dailyRecord else { return }
        targetStore?.applyDailyCapture(record)
    }

    private func runAutomaticDailyAnalysis(for record: DailyCaptureRecord) async {
        guard let ai = targetAI,
              let store = targetStore,
              ai.hasVerifiedConnection,
              ai.needsAutomaticAnalysis(for: record.date) else { return }

        guard let date = DiaryEntry.dateFormatter.date(from: record.date) else { return }
        let sessions = targetActivity?.liveSessions(for: date) ?? []
        let captures = store.quickCaptures[record.date] ?? []
        let entries = store.entries
            .filter { $0.date == record.date }
            .sorted { $0.date < $1.date }
        let sourceSummary = "自动采集 · \(record.summary)"

        let success = await ai.runAnalysisDaily(
            entries: Array(entries.suffix(1)),
            sessions: sessions,
            captures: captures,
            archiveStartDate: record.date,
            archiveEndDate: record.date,
            sourceSummary: sourceSummary
        )

        if success {
            ai.markAutomaticAnalysisCompleted(for: record.date)
            lastStatus = "采集完成 · \(record.summary) · 定时 AI 分析完成"
        } else {
            lastStatus = "采集完成 · \(record.summary) · 定时 AI 分析失败，将在下次到达定时或启动时重试"
        }
    }

    private func refreshSourceMetadata() {
        guard let url = sourceURL else { return }
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let date = attributes[.modificationDate] as? Date {
            lastSourceModifiedAt = date
        }
    }

    // MARK: - Static helpers

    private nonisolated static func hasTodayData(_ payload: [String: Any], today: String) -> Bool {
        if let scores = payload["moodScores"] as? [String: Any], scores[today] != nil {
            return true
        }
        if let nights = payload["sleepNights"] as? [[String: Any]],
           nights.contains(where: { ($0["date"] as? String) == today }) {
            return true
        }
        if let days = payload["exerciseDays"] as? [[String: Any]],
           days.contains(where: { ($0["date"] as? String) == today }) {
            return true
        }
        return false
    }

    private nonisolated static func cleanIOSPayload(_ payload: [String: Any], syncedAt: Date) -> IngestedUserData {
        var moodScores: [String: Int] = [:]
        if let rawScores = payload["moodScores"] as? [String: Any] {
            for (date, value) in rawScores where isValidDate(date) {
                if let score = doubleValue(value), (0...100).contains(score) {
                    moodScores[date] = Int(score.rounded())
                }
            }
        }

        var sleepNights: [IngestedSleepNight] = []
        if let rawNights = payload["sleepNights"] as? [[String: Any]] {
            for raw in rawNights {
                guard let date = raw["date"] as? String, isValidDate(date),
                      let totalHours = doubleValue(raw["totalHours"]),
                      totalHours > 0, totalHours <= 24 else { continue }
                let deep = minutesValue(raw["deepMinutes"])
                let rem = minutesValue(raw["remMinutes"])
                let awake = minutesValue(raw["awakeMinutes"])
                guard deep + rem + awake <= totalHours * 60 * 1.1 else { continue }
                sleepNights.append(IngestedSleepNight(
                    date: date,
                    totalHours: (totalHours * 100).rounded() / 100,
                    deepMinutes: deep,
                    remMinutes: rem,
                    awakeMinutes: awake
                ))
            }
        }

        var exerciseDays: [IngestedExerciseDay] = []
        if let rawDays = payload["exerciseDays"] as? [[String: Any]] {
            for raw in rawDays {
                guard let date = raw["date"] as? String, isValidDate(date) else { continue }
                let steps = Int(doubleValue(raw["steps"], default: 0) ?? 0)
                let distance = doubleValue(raw["distanceKilometers"], default: 0) ?? 0
                let energy = doubleValue(raw["activeEnergyKilocalories"], default: 0) ?? 0
                guard steps >= 0, distance >= 0, energy >= 0,
                      steps > 0 || distance > 0 || energy > 0 else { continue }
                exerciseDays.append(IngestedExerciseDay(
                    date: date,
                    steps: steps,
                    distanceKilometers: (distance * 100).rounded() / 100,
                    activeEnergyKilocalories: (energy * 10).rounded() / 10
                ))
            }
        }

        var quickNotes: [IngestedQuickNote] = []
        if let rawNotes = payload["quickNotes"] as? [[String: Any]] {
            for raw in rawNotes {
                guard let date = raw["date"] as? String, isValidDate(date) else { continue }
                let text = (raw["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                quickNotes.append(IngestedQuickNote(
                    id: (raw["id"] as? String) ?? stableNoteID(date: date, text: text),
                    date: date,
                    text: text,
                    createdAt: parseDate(raw["createdAt"]),
                    source: "iOS 快记"
                ))
            }
        }

        return IngestedUserData(
            syncedAt: syncedAt,
            sourceUpdatedAt: payload["updatedAt"] as? String,
            moodScores: moodScores,
            sleepNights: sleepNights,
            exerciseDays: exerciseDays,
            quickNotes: quickNotes
        )
    }

    private nonisolated static func buildDailyRecord(
        date: String,
        ios: IngestedUserData,
        chrome: [ChromeVisit],
        notes: [DailyNoteEntry],
        screen: ScreenTimeSnapshot?
    ) -> DailyCaptureRecord {
        let today = DiaryEntry.dateFormatter.string(from: Date())
        let todayMood = ios.moodScores[today]
        let todaySleep = ios.sleepNights.first { $0.date == today }
        let todayExercise = ios.exerciseDays.first { $0.date == today }
        let todayQuickNotes = ios.quickNotes.filter { $0.date == today }

        let overview = generateMixedOverview(
            mood: todayMood,
            sleep: todaySleep?.totalHours,
            steps: todayExercise?.steps,
            chromeVisits: chrome,
            notes: notes,
            screen: screen
        )

        return DailyCaptureRecord(
            date: date,
            capturedAt: Date(),
            iosDataAvailable: true,
            moodScore: todayMood,
            sleepHours: todaySleep?.totalHours,
            sleepDeepMinutes: todaySleep?.deepMinutes,
            sleepREMMinutes: todaySleep?.remMinutes,
            exerciseSteps: todayExercise?.steps,
            exerciseDistanceKM: todayExercise?.distanceKilometers,
            exerciseEnergyKcal: todayExercise?.activeEnergyKilocalories,
            quickNotes: todayQuickNotes,
            chromeVisits: chrome,
            chromeTotalVisits: chrome.reduce(0) { $0 + $1.visitCount },
            chromeTopDomains: ChromeHistoryReader.topDomains(from: chrome),
            notesModified: notes,
            screenTimeMinutes: screen?.totalMinutes,
            screenTopApps: screen?.topApps ?? [],
            mixedOverview: overview
        )
    }

    private nonisolated static func generateMixedOverview(
        mood: Int?,
        sleep: Double?,
        steps: Int?,
        chromeVisits: [ChromeVisit],
        notes: [DailyNoteEntry],
        screen: ScreenTimeSnapshot?
    ) -> String {
        var parts: [String] = []

        if let mood { parts.append("心情评分 \(mood)") }
        if let sleep { parts.append("睡眠 \(String(format: "%.1f", sleep)) 小时") }
        if let steps, steps > 0 { parts.append("步数 \(steps)") }

        if !chromeVisits.isEmpty {
            let totalVisits = chromeVisits.reduce(0) { $0 + $1.visitCount }
            let domains = ChromeHistoryReader.topDomains(from: chromeVisits, limit: 3).joined(separator: "、")
            parts.append("浏览 \(totalVisits) 个页面（\(domains)）")
        }

        if !notes.isEmpty {
            let titles = notes.prefix(3).map(\.title).joined(separator: "、")
            parts.append("备忘录更新 \(notes.count) 条（\(titles)）")
        }

        if let screen, screen.totalMinutes > 0 {
            let apps = screen.topApps.prefix(3).joined(separator: "、")
            parts.append("屏幕使用 \(String(format: "%.1f", Double(screen.totalMinutes) / 60)) 小时（\(apps)）")
        }

        return parts.isEmpty ? "今天没有记录到有效数据。" : parts.joined(separator: " · ")
    }

    // MARK: - Utility

    private nonisolated static func doubleValue(_ value: Any?, default defaultValue: Double? = nil) -> Double? {
        guard let number = value as? NSNumber else { return defaultValue }
        return number.doubleValue.isFinite ? number.doubleValue : defaultValue
    }

    private nonisolated static func minutesValue(_ value: Any?) -> Double {
        max(0, doubleValue(value, default: 0) ?? 0)
    }

    private nonisolated static func stableNoteID(date: String, text: String) -> String {
        let digest = SHA256Hex.hash(Data("\(date)|\(text)".utf8))
        return "\(date)-\(digest.prefix(16))"
    }

    private nonisolated static func isValidDate(_ value: String) -> Bool {
        value.count == 10 && DiaryEntry.dateFormatter.date(from: value) != nil
    }

    private nonisolated static func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        local.timeZone = TimeZone.current
        if let date = local.date(from: text) { return date }
        if let day = DiaryEntry.dateFormatter.date(from: text) {
            return Calendar.current.date(byAdding: .hour, value: 12, to: day)
        }
        return nil
    }
}
