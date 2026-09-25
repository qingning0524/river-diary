import Combine
import Foundation

enum JournalSaveState: Equatable {
    case idle
    case saving
    case saved(Date)
    case failed(String)
}

struct LocalBackupPayload: Codable {
    var version = 5
    var exportedAt: Date
    var sourcePath: String?
    var data: DiaryData?
    var overrides: [String: EntryOverride]
    var quickCaptures: [String: [QuickCapture]]
    var dismissedDrafts: [String: Date]
    var careAcknowledgments: [String: Date]
    var autoDraftPaused: Bool?
    var activitySessions: [ActivitySession]?
    var monthlyLetters: [String: MonthlyLetter]?
    var savedQueries: [SavedQuery]? = nil
    var timelineAnnotations: [String: TimelineAnnotation]? = nil
    var dailyGoals: [String: DailyGoal]? = nil
    var journalDrafts: [String: JournalDraftRecord]? = nil
    var legacyDatabaseSnapshot: Data? = nil
    var v2DatabaseSnapshot: Data? = nil
}

private struct BackupRestoreFileCheckpoint {
    let url: URL?
    let existed: Bool
    let data: Data?
}

private struct DiaryStoreRestoreCheckpoint {
    let data: DiaryData?
    let baseData: DiaryData?
    let overrides: [String: EntryOverride]
    let quickCaptures: [String: [QuickCapture]]
    let dailyGoals: [String: DailyGoal]
    let journalDrafts: [String: JournalDraftRecord]
    let monthlyLetters: [String: MonthlyLetter]
    let savedQueries: [SavedQuery]
    let timelineAnnotations: [String: TimelineAnnotation]
    let dismissedDrafts: Set<String>
    let careAcknowledgments: Set<String>
    let autoDraftPaused: Bool
    let hasLocalChanges: Bool
    let externalSourceURL: URL?
    let externalSourceError: String?
    let externalSourceModifiedAt: Date?
    let localStateReadFailed: Bool
    let isEncrypted: Bool
    let loadError: String?
    let saveState: JournalSaveState
    let stateFile: BackupRestoreFileCheckpoint
    let restoredDataFile: BackupRestoreFileCheckpoint
    let externalSourceDefault: String?
}

@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var data: DiaryData?
    @Published private(set) var loadError: String?
    @Published private(set) var saveState: JournalSaveState = .idle
    @Published private(set) var hasLocalChanges = false
    @Published private(set) var isEncrypted = false
    @Published private(set) var quickCaptures: [String: [QuickCapture]] = [:]
    @Published private(set) var monthlyLetters: [String: MonthlyLetter] = [:]
    @Published private(set) var savedQueries: [SavedQuery] = []
    @Published private(set) var timelineAnnotations: [String: TimelineAnnotation] = [:]
    @Published private(set) var dailyGoals: [String: DailyGoal] = [:]
    @Published private(set) var journalDrafts: [String: JournalDraftRecord] = [:]
    @Published private(set) var dismissedDrafts: Set<String> = []
    @Published private(set) var careAcknowledgments: Set<String> = []
    @Published private(set) var autoDraftPaused = false
    @Published private(set) var draftPausedUntil: Date?
    @Published private(set) var externalSourceURL: URL?
    @Published private(set) var externalSourceError: String?
    @Published private(set) var externalSourceModifiedAt: Date?

    private var baseData: DiaryData?
    private var overrides: [String: EntryOverride] = [:]
    private var localStateReadFailed = false
    private var ingestedHealth: [String: IOSHealthSummary] = [:]
    private var ingestedScores: [String: Int] = [:]
    private let fileManager = FileManager.default
    private let configuredSupportDirectory: URL?

    private var hasPersistentLocalEdits: Bool {
        !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty
            || !savedQueries.isEmpty || !timelineAnnotations.isEmpty || !dailyGoals.isEmpty || !journalDrafts.isEmpty
    }

    private lazy var supportDirectory: URL? = {
        if let configuredSupportDirectory {
            do {
                try LocalStorageProtection.ensurePrivateDirectory(at: configuredSupportDirectory)
                return configuredSupportDirectory
            } catch {
                localStateReadFailed = true
                loadError = "本地状态目录权限设置失败：\(error.localizedDescription)"
                return nil
            }
        }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let target = directory.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        do {
            try LocalStorageProtection.ensurePrivateDirectory(at: target)
            return target
        } catch {
            localStateReadFailed = true
            loadError = "本地状态目录权限设置失败：\(error.localizedDescription)"
            return nil
        }
    }()

    private var stateURL: URL? {
        supportDirectory?.appendingPathComponent("journal.state")
    }

    private var legacyStateURL: URL? {
        supportDirectory?.appendingPathComponent("user-state.json")
    }

    private let externalSourceKey = "externalSnapshotPath"
    private var sourceObserver: DispatchSourceFileSystemObject?
    private var observerFileDescriptor: Int32 = -1

    init(supportDirectory: URL? = nil) {
        configuredSupportDirectory = supportDirectory
        if let path = UserDefaults.standard.string(forKey: externalSourceKey) {
            externalSourceURL = URL(fileURLWithPath: path)
        }
        loadLocalState()
        loadExternalOrBundledSnapshot()
        watchExternalSnapshot()
    }

    var entries: [DiaryEntry] {
        (data?.entries ?? []).sorted { $0.date < $1.date }
    }

    var latestEntry: DiaryEntry? {
        entries.last
    }

    /// Only publish a letter after its encrypted state has reached disk.
    func saveMonthlyLetter(_ letter: MonthlyLetter) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 31, userInfo: [NSLocalizedDescriptionKey: "本地日记尚未成功读取，请重新打开应用并完成解锁后再保存。"])
        }
        var updated = monthlyLetters
        updated[letter.month] = letter
        do {
            try persist(monthlyLetters: updated)
            monthlyLetters = updated
            hasLocalChanges = true
            saveState = .saved(Date())
        } catch {
            saveState = .failed(UserFacingError.message(for: error))
            throw error
        }
    }

    func saveTimelineAnnotation(_ annotation: TimelineAnnotation, for key: String) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 41, userInfo: [NSLocalizedDescriptionKey: "本地日记尚未成功读取，暂时不能整理片段。"])
        }
        let updated = TimelineAnnotation.updating(timelineAnnotations, key: key, with: annotation)
        do {
            try persist(timelineAnnotations: updated)
            timelineAnnotations = updated
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .saved(Date())
        } catch {
            saveState = .failed(UserFacingError.message(for: error))
            throw error
        }
    }

    func saveSavedQuery(_ query: SavedQuery) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 32, userInfo: [NSLocalizedDescriptionKey: "本地状态尚未成功读取，暂时不能保存查询。"])
        }
        var updated = savedQueries
        if let index = updated.firstIndex(where: { $0.id == query.id }) {
            updated[index] = query
        } else {
            updated.append(query)
        }
        updated.sort { ($0.lastUsedAt ?? $0.updatedAt) > ($1.lastUsedAt ?? $1.updatedAt) }
        do {
            try persist(savedQueries: updated)
        } catch {
            saveState = .failed(UserFacingError.message(for: error))
            throw error
        }
        savedQueries = updated
        hasLocalChanges = true
        saveState = .saved(Date())
    }

    func markSavedQueryUsed(_ id: UUID) {
        guard let index = savedQueries.firstIndex(where: { $0.id == id }) else { return }
        let previousUsedAt = savedQueries[index].lastUsedAt
        savedQueries[index].lastUsedAt = Date()
        do {
            try persist(savedQueries: savedQueries)
        } catch {
            savedQueries[index].lastUsedAt = previousUsedAt
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func removeSavedQuery(_ query: SavedQuery) {
        let previousQueries = savedQueries
        savedQueries.removeAll { $0.id == query.id }
        hasLocalChanges = hasPersistentLocalEdits
        do { try persist() } catch {
            savedQueries = previousQueries
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    var poem: String {
        data?.poem ?? "情绪会沉淀，日子会向前。"
    }

    var averageScore: Int {
        let scores = entries.compactMap(\.score)
        guard !scores.isEmpty else { return 0 }
        return Int((scores.reduce(0, +) / Double(scores.count)).rounded())
    }

    var recentTrend: Int {
        let scores = entries.compactMap(\.score)
        guard scores.count >= 8 else { return 0 }
        let previous = scores.suffix(8).prefix(4).reduce(0, +) / 4
        let current = scores.suffix(4).reduce(0, +) / 4
        return Int(current - previous)
    }

    func entry(for date: Date = Date()) -> DiaryEntry {
        let dateString = DiaryEntry.dateFormatter.string(from: date)
        if let existing = entries.first(where: { $0.date == dateString }) {
            return existing
        }

        return DiaryEntry(
            pageID: "local-\(dateString)",
            date: dateString,
            score: nil,
            daily: nil,
            overview: "",
            thoughts: nil,
            memos: nil,
            tags: [],
            category: "随想",
            metrics: nil,
            stage: nil
        )
    }

    func captures(for entry: DiaryEntry) -> [QuickCapture] {
        QuickCapture.sortedForDisplay(quickCaptures[entry.date] ?? [])
    }

    func dailyGoal(for date: Date) -> DailyGoal? {
        dailyGoals[DiaryEntry.dateFormatter.string(from: date)]
    }

    func saveDailyGoal(_ goal: DailyGoal?, for date: Date) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 43, userInfo: [NSLocalizedDescriptionKey: "本地状态尚未成功读取，暂时不能保存目标。"])
        }
        let key = DiaryEntry.dateFormatter.string(from: date)
        var updated = dailyGoals
        if let goal {
            let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            updated[key] = DailyGoal(title: title, isCompleted: goal.isCompleted, updatedAt: Date())
        } else {
            updated.removeValue(forKey: key)
        }

        try persist(dailyGoals: updated)
        dailyGoals = updated
        hasLocalChanges = hasPersistentLocalEdits
        saveState = .saved(Date())
    }

    func saveJournalDraft(_ draft: JournalDraftRecord, for date: String) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 44, userInfo: [NSLocalizedDescriptionKey: "本地日记尚未成功读取，暂时不能保存草稿。"])
        }
        var updated = journalDrafts
        updated[date] = draft
        try persist(journalDrafts: updated)
        journalDrafts = updated
        hasLocalChanges = hasPersistentLocalEdits
        saveState = .saved(Date())
    }

    func removeJournalDraft(for date: String) throws {
        guard journalDrafts[date] != nil else { return }
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 45, userInfo: [NSLocalizedDescriptionKey: "本地日记尚未成功读取，暂时不能删除草稿。"])
        }
        var updated = journalDrafts
        updated[date] = nil
        try persist(journalDrafts: updated)
        journalDrafts = updated
        hasLocalChanges = hasPersistentLocalEdits
        saveState = .saved(Date())
    }

    @discardableResult
    func addQuickCapture(_ text: String, tag: String? = nil, for date: Date = Date()) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard !localStateReadFailed else {
            saveState = .failed("本地日记尚未成功读取，请重新打开应用后再保存。")
            return false
        }
        let dateString = DiaryEntry.dateFormatter.string(from: date)
        let capture = QuickCapture(text: trimmed, createdAt: Date(), tag: tag?.isEmpty == false ? tag : nil)
        let previousCaptures = quickCaptures[dateString]
        let previouslyChanged = hasLocalChanges
        quickCaptures[dateString, default: []].append(capture)
        hasLocalChanges = true
        saveState = .saving
        do {
            try persist()
            saveState = .saved(Date())
            return true
        } catch {
            quickCaptures[dateString] = previousCaptures
            hasLocalChanges = previouslyChanged
            saveState = .failed(UserFacingError.message(for: error))
            return false
        }
    }

    func removeQuickCapture(_ capture: QuickCapture, entry: DiaryEntry) {
        let previousCaptures = quickCaptures[entry.date]
        quickCaptures[entry.date]?.removeAll { $0.id == capture.id }
        if quickCaptures[entry.date]?.isEmpty == true {
            quickCaptures[entry.date] = nil
        }
        hasLocalChanges = hasPersistentLocalEdits
        do { try persist() } catch {
            quickCaptures[entry.date] = previousCaptures
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func setQuickCapturePinned(_ capture: QuickCapture, entry: DiaryEntry, pinned: Bool) {
        guard let index = quickCaptures[entry.date]?.firstIndex(where: { $0.id == capture.id }) else { return }
        let previousPinned = quickCaptures[entry.date]?[index].isPinned
        quickCaptures[entry.date]?[index].isPinned = pinned
        hasLocalChanges = true
        do { try persist() } catch {
            if let previousPinned, let index = quickCaptures[entry.date]?.firstIndex(where: { $0.id == capture.id }) {
                quickCaptures[entry.date]?[index].isPinned = previousPinned
            }
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func draftDismissed(_ entry: DiaryEntry) -> Bool {
        dismissedDrafts.contains(entry.id)
    }

    func dismissDraft(for entry: DiaryEntry) {
        dismissedDrafts.insert(entry.id)
        careAcknowledgments.insert(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(UserFacingError.message(for: error)) }
    }

    func restoreDraft(for entry: DiaryEntry) {
        dismissedDrafts.remove(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(UserFacingError.message(for: error)) }
    }

    func acknowledgeCare(_ entry: DiaryEntry) {
        careAcknowledgments.insert(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(UserFacingError.message(for: error)) }
    }

    func careAcknowledged(_ entry: DiaryEntry) -> Bool {
        careAcknowledgments.contains(entry.id)
    }

    func setAutoDraftPaused(_ paused: Bool) {
        let previousPaused = autoDraftPaused
        let previousPausedUntil = draftPausedUntil
        autoDraftPaused = paused
        if paused { draftPausedUntil = nil }
        hasLocalChanges = true
        do { try persist() } catch {
            autoDraftPaused = previousPaused
            draftPausedUntil = previousPausedUntil
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    var isAutoDraftTemporarilyPaused: Bool {
        guard let until = draftPausedUntil else { return false }
        return until > Date()
    }

    func pauseAutoDraft(days: Int) {
        let dayCount = min(7, max(1, days))
        let previousPausedUntil = draftPausedUntil
        draftPausedUntil = Calendar.current.date(byAdding: .day, value: dayCount, to: Date())
        hasLocalChanges = true
        do { try persist() } catch {
            draftPausedUntil = previousPausedUntil
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func resumeAutoDraftPause() {
        let previousPausedUntil = draftPausedUntil
        draftPausedUntil = nil
        hasLocalChanges = true
        do { try persist() } catch {
            draftPausedUntil = previousPausedUntil
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func overview(for entry: DiaryEntry) -> String {
        if let override = overrides[entry.id], !override.overview.isEmpty {
            return override.overview
        }
        return entry.displayOverview
    }

    func category(for entry: DiaryEntry) -> String {
        overrides[entry.id]?.category ?? entry.category ?? "随想"
    }

    func tags(for entry: DiaryEntry) -> [String] {
        overrides[entry.id]?.tags ?? entry.tags ?? []
    }

    func hasOverride(_ entry: DiaryEntry) -> Bool {
        overrides[entry.id] != nil
    }

    func saveWriting(entry: DiaryEntry, text: String, mood: Int?) throws {
        guard !localStateReadFailed else {
            throw NSError(domain: "RiverDiaryMac", code: 42, userInfo: [NSLocalizedDescriptionKey: "本地日记尚未成功读取，暂时不能保存。"])
        }
        let existingOverride = overrides[entry.id] ?? overrides["local-\(entry.date)"] ?? overrides["ingested-\(entry.date)"]
        var value = EntryOverride(
            overview: text.trimmingCharacters(in: .whitespacesAndNewlines),
            mood: entry.mood, energy: entry.energy, focus: entry.focus, output: entry.output,
            category: entry.category, tags: entry.tags, updatedAt: Date(),
            preservesMetrics: true, writtenMood: mood ?? existingOverride?.writtenMood
        )
        // Preserve legacy saved metrics when converting an older edited entry.
        if let existing = existingOverride, existing.preservesMetrics != true {
            value.mood = mood ?? existing.mood
            value.energy = existing.energy
            value.focus = existing.focus
            value.output = existing.output
            value.preservesMetrics = false
        }
        var updated = overrides
        updated[entry.id] = value
        var updatedDrafts = journalDrafts
        updatedDrafts[entry.date] = nil
        do {
            try persist(overrides: updated, journalDrafts: updatedDrafts)
            overrides = updated
            journalDrafts = updatedDrafts
            apply(entry: entry.id, override: value)
            hasLocalChanges = true
            saveState = .saved(Date())
        } catch {
            saveState = .failed(UserFacingError.message(for: error))
            throw error
        }
    }

    func save(
        entry: DiaryEntry,
        text: String,
        mood: Int,
        energy: Int,
        focus: Int,
        output: Int,
        category: String,
        tags: [String]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTags = Array(Set(tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()

        let override = EntryOverride(
            overview: trimmed,
            mood: mood,
            energy: energy,
            focus: focus,
            output: output,
            category: category,
            tags: normalizedTags,
            updatedAt: Date()
        )

        var updatedOverrides = overrides
        updatedOverrides[entry.id] = override
        var updatedDrafts = journalDrafts
        updatedDrafts[entry.date] = nil

        saveState = .saving
        do {
            try persist(overrides: updatedOverrides, journalDrafts: updatedDrafts)
            overrides = updatedOverrides
            journalDrafts = updatedDrafts
            hasLocalChanges = hasPersistentLocalEdits
            apply(entry: entry.id, override: override)
            saveState = .saved(Date())
        } catch {
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func clearOverride(for entry: DiaryEntry) {
        guard let removedOverride = overrides[entry.id] else { return }
        let previousData = data

        overrides[entry.id] = nil
        hasLocalChanges = hasPersistentLocalEdits
        saveState = .idle

        if entry.id.hasPrefix("local-") {
            data?.entries.removeAll { $0.id == entry.id }
        } else if let baseEntry = baseData?.entries.first(where: { $0.id == entry.id }) {
            if let index = data?.entries.firstIndex(where: { $0.id == entry.id }) {
                data?.entries[index] = baseEntry
            }
        }

        do {
            try persist()
            saveState = .saved(Date())
        } catch {
            // 恢复内存，避免下一次成功的持久化把这次未落盘的删除悄悄固化。
            overrides[entry.id] = removedOverride
            data = previousData
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func clearLocalJournal() {
        let previousOverrides = overrides
        let previousGoals = dailyGoals
        let previousDrafts = journalDrafts
        let previousDismissed = dismissedDrafts
        let previousCare = careAcknowledgments
        let previousQueries = savedQueries
        let previousData = data

        overrides = [:]
        dailyGoals = [:]
        journalDrafts = [:]
        dismissedDrafts = []
        careAcknowledgments = []
        savedQueries = []
        hasLocalChanges = hasPersistentLocalEdits
        saveState = .idle

        if let baseData {
            var restored = baseData
            restored.entries.sort { $0.date < $1.date }
            data = restored
        }

        do {
            if let stateURL, fileManager.fileExists(atPath: stateURL.path) {
                try fileManager.removeItem(at: stateURL)
            }
            if let legacyStateURL, fileManager.fileExists(atPath: legacyStateURL.path) {
                try fileManager.removeItem(at: legacyStateURL)
            }
            // 快记、月信和时间线标注不属于"本地日记"，清空后若仍有残留则重建状态文件。
            if !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !timelineAnnotations.isEmpty {
                try persist()
            } else {
                isEncrypted = false
            }
        } catch {
            // 清空已落盘一半时回滚内存，保持内存与磁盘一致（宁可让数据回来，不能让状态悬空）。
            overrides = previousOverrides
            dailyGoals = previousGoals
            journalDrafts = previousDrafts
            dismissedDrafts = previousDismissed
            careAcknowledgments = previousCare
            savedQueries = previousQueries
            data = previousData
            hasLocalChanges = hasPersistentLocalEdits
            saveState = .failed(UserFacingError.message(for: error))
        }
    }

    func connectExternalSnapshot(to url: URL) {
        let accessible = url.startAccessingSecurityScopedResource()
        defer { if accessible { url.stopAccessingSecurityScopedResource() } }

        do {
            _ = try Data(contentsOf: url)
            UserDefaults.standard.set(url.path, forKey: externalSourceKey)
            externalSourceURL = url
            externalSourceError = nil
            loadExternalOrBundledSnapshot()
            watchExternalSnapshot()
        } catch {
            externalSourceError = UserFacingError.message(for: error)
        }
    }

    func disconnectExternalSnapshot() {
        UserDefaults.standard.removeObject(forKey: externalSourceKey)
        externalSourceURL = nil
        externalSourceError = nil
        loadExternalOrBundledSnapshot()
        watchExternalSnapshot()
    }

    func reloadExternalSnapshot() {
        loadExternalOrBundledSnapshot()
        watchExternalSnapshot()
    }

    func applyIngestedData(_ ingestion: IngestedUserData) {
        ingestedHealth = buildIngestedHealth(ingestion)
        ingestedScores = ingestion.moodScores

        var addedCaptures = false
        for note in ingestion.quickNotes {
            let dateKey = note.date
            let existing = quickCaptures[dateKey] ?? []
            let createdAt = note.createdAt ?? DiaryEntry.dateFormatter.date(from: dateKey)?.addingTimeInterval(12 * 3600) ?? Date()
            let alreadyExists = existing.contains { capture in
                capture.text == note.text && (note.createdAt == nil || abs(capture.createdAt.timeIntervalSince(createdAt)) < 60)
            }
            guard !alreadyExists else { continue }
            quickCaptures[dateKey, default: []].append(
                QuickCapture(text: note.text, createdAt: createdAt, source: note.source)
            )
            addedCaptures = true
        }

        loadExternalOrBundledSnapshot()

        if addedCaptures {
            hasLocalChanges = true
            saveState = .saving
            do {
                try persist()
                saveState = .saved(Date())
            } catch {
                saveState = .failed(UserFacingError.message(for: error))
            }
        }
    }

    func applyDailyCapture(_ record: DailyCaptureRecord) {
        // Populate health from the daily record
        let date = record.date
        var health = ingestedHealth[date] ?? IOSHealthSummary()
        if let sleep = record.sleepHours { health.sleepHours = sleep }
        if let steps = record.exerciseSteps { health.steps = steps }
        if let distance = record.exerciseDistanceKM { health.distanceKM = distance }
        if let energy = record.exerciseEnergyKcal { health.activeEnergyKcal = energy }
        health.updatedAt = ISO8601DateFormatter().string(from: record.capturedAt)
        ingestedHealth[date] = health

        // Apply mood score
        if let mood = record.moodScore {
            ingestedScores[date] = mood
        }

        // Add quick notes from the record
        for note in record.quickNotes {
            let existing = quickCaptures[date] ?? []
            let createdAt = note.createdAt ?? DiaryEntry.dateFormatter.date(from: date)?.addingTimeInterval(12 * 3600) ?? Date()
            let alreadyExists = existing.contains { capture in
                capture.text == note.text && abs(capture.createdAt.timeIntervalSince(createdAt)) < 60
            }
            guard !alreadyExists else { continue }
            quickCaptures[date, default: []].append(
                QuickCapture(text: note.text, createdAt: createdAt, source: note.source)
            )
            hasLocalChanges = true
        }

        // Reload and merge
        loadExternalOrBundledSnapshot()

        if hasLocalChanges {
            do {
                try persist()
            } catch {
                saveState = .failed(UserFacingError.message(for: error))
            }
        }
    }

    private func buildIngestedHealth(_ ingestion: IngestedUserData) -> [String: IOSHealthSummary] {
        var byDate: [String: IOSHealthSummary] = [:]
        let updatedAt = ingestion.sourceUpdatedAt ?? ISO8601DateFormatter().string(from: ingestion.syncedAt)

        for night in ingestion.sleepNights {
            var health = byDate[night.date] ?? IOSHealthSummary()
            health.sleepHours = night.totalHours
            health.updatedAt = updatedAt
            byDate[night.date] = health
        }

        for exercise in ingestion.exerciseDays {
            var health = byDate[exercise.date] ?? IOSHealthSummary()
            health.steps = exercise.steps
            health.distanceKM = exercise.distanceKilometers
            health.activeEnergyKcal = exercise.activeEnergyKilocalories
            health.updatedAt = updatedAt
            byDate[exercise.date] = health
        }

        return byDate
    }

    func checkExternalSnapshotChanged() {
        guard let url = externalSourceURL else { return }

        guard fileManager.fileExists(atPath: url.path) else {
            loadExternalOrBundledSnapshot()
            watchExternalSnapshot()
            return
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return }

        if modified != externalSourceModifiedAt {
            loadExternalOrBundledSnapshot()
            // The pipeline writes with an atomic replace, which swaps the inode.
            // Reattach so future updates continue to be observed.
            watchExternalSnapshot()
        }
    }

    func exportFullBackup(
        to url: URL,
        activitySessions exportedActivity: [ActivitySession] = [],
        legacyDatabaseSnapshot: Data? = nil,
        v2DatabaseSnapshot: Data? = nil
    ) throws {
        guard data != nil || hasPersistentLocalEdits || !exportedActivity.isEmpty
                || legacyDatabaseSnapshot != nil || v2DatabaseSnapshot != nil else {
            throw NSError(domain: "RiverDiaryMac", code: 10, userInfo: [NSLocalizedDescriptionKey: "没有可备份的数据"])
        }

        let payload = LocalBackupPayload(
            exportedAt: Date(),
            sourcePath: externalSourceURL?.path,
            data: data,
            overrides: overrides,
            quickCaptures: quickCaptures,
            dismissedDrafts: dismissedDrafts.reduce(into: [:]) { result, value in result[value] = Date() },
            careAcknowledgments: careAcknowledgments.reduce(into: [:]) { result, value in result[value] = Date() },
            autoDraftPaused: autoDraftPaused,
            activitySessions: exportedActivity,
            monthlyLetters: monthlyLetters,
            savedQueries: savedQueries,
            timelineAnnotations: timelineAnnotations,
            dailyGoals: dailyGoals,
            journalDrafts: journalDrafts,
            legacyDatabaseSnapshot: legacyDatabaseSnapshot,
            v2DatabaseSnapshot: v2DatabaseSnapshot
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encrypted = try StateEncryption.encrypt(try encoder.encode(payload))
        try encrypted.write(to: url, options: .atomic)
    }

    func restoreFullBackup(
        from url: URL,
        restoreActivity: (([ActivitySession]) throws -> Void)? = nil,
        validateDatabaseSnapshots: ((Data?, Data?) throws -> Void)? = nil,
        restoreDatabaseSnapshots: ((Data?, Data?) throws -> Void)? = nil,
        rollbackExternalData: (() throws -> Void)? = nil,
        recoverySnapshot: RestoreRecoverySnapshot? = nil
    ) throws {
        let raw = try Data(contentsOf: url)
        guard let plaintext = try? StateEncryption.decrypt(raw) else {
            throw NSError(domain: "RiverDiaryMac", code: 11, userInfo: [NSLocalizedDescriptionKey: "备份文件无法解密，请确认这是本应用生成的完整备份"])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LocalBackupPayload.self, from: plaintext)
        try validateDatabaseSnapshots?(payload.legacyDatabaseSnapshot, payload.v2DatabaseSnapshot)

        guard (restoreActivity == nil && restoreDatabaseSnapshots == nil) || rollbackExternalData != nil else {
            throw NSError(domain: "RiverDiaryMac", code: 12, userInfo: [NSLocalizedDescriptionKey: "备份恢复缺少外部数据回滚处理，已取消恢复。"])
        }
        if restoreActivity != nil && recoverySnapshot?.activitySessions == nil {
            throw NSError(domain: "RiverDiaryMac", code: 14, userInfo: [NSLocalizedDescriptionKey: "备份恢复缺少实时足迹的持久恢复快照，已取消恢复。"])
        }
        if restoreDatabaseSnapshots != nil,
           (recoverySnapshot?.legacyDatabaseSnapshot == nil || recoverySnapshot?.v2DatabaseSnapshot == nil) {
            throw NSError(domain: "RiverDiaryMac", code: 15, userInfo: [NSLocalizedDescriptionKey: "备份恢复缺少两份数据库的持久恢复快照，已取消恢复。"])
        }

        let checkpoint = try makeRestoreCheckpoint()
        guard let supportDirectory else {
            throw NSError(domain: "RiverDiaryMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用支持目录，已取消恢复。"])
        }
        let previousStores = recoverySnapshot ?? RestoreRecoverySnapshot(
            activitySessions: nil,
            legacyDatabaseSnapshot: nil,
            v2DatabaseSnapshot: nil,
            trackingEnabled: nil
        )
        let recoveryPayload = RestoreRecoveryPayload(
            activitySessions: previousStores.activitySessions,
            legacyDatabaseSnapshot: previousStores.legacyDatabaseSnapshot,
            v2DatabaseSnapshot: previousStores.v2DatabaseSnapshot,
            trackingEnabled: previousStores.trackingEnabled,
            externalSourcePath: checkpoint.externalSourceDefault,
            journalState: RestoreRecoveryFile(existed: checkpoint.stateFile.existed, contents: checkpoint.stateFile.data),
            restoredData: RestoreRecoveryFile(existed: checkpoint.restoredDataFile.existed, contents: checkpoint.restoredDataFile.data)
        )
        try RestoreRecoveryJournal.write(recoveryPayload, in: supportDirectory)

        let restoredDataURL = payload.data == nil ? nil : checkpoint.restoredDataFile.url
        let restoredDataBytes: Data?
        if let restoredData = payload.data, restoredDataURL != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            restoredDataBytes = try encoder.encode(restoredData)
        } else {
            restoredDataBytes = nil
        }

        var attemptedExternalRestore = false
        var startedLocalCommit = false
        do {
            if let restoreActivity {
                attemptedExternalRestore = true
                try restoreActivity(payload.activitySessions ?? [])
            }
            if let restoreDatabaseSnapshots {
                attemptedExternalRestore = true
                try restoreDatabaseSnapshots(payload.legacyDatabaseSnapshot, payload.v2DatabaseSnapshot)
            }

            if let restoredDataBytes, let restoredDataURL {
                startedLocalCommit = true
                try restoredDataBytes.write(to: restoredDataURL, options: .atomic)
                try LocalStorageProtection.protectFile(at: restoredDataURL)
                externalSourceURL = restoredDataURL
                UserDefaults.standard.set(restoredDataURL.path, forKey: externalSourceKey)
            } else if let path = payload.sourcePath, FileManager.default.fileExists(atPath: path) {
                startedLocalCommit = true
                externalSourceURL = URL(fileURLWithPath: path)
                UserDefaults.standard.set(path, forKey: externalSourceKey)
            } else {
                startedLocalCommit = true
                externalSourceURL = nil
                UserDefaults.standard.removeObject(forKey: externalSourceKey)
            }

            overrides = payload.overrides
            quickCaptures = payload.quickCaptures
            dailyGoals = payload.dailyGoals ?? [:]
            journalDrafts = payload.journalDrafts ?? [:]
            monthlyLetters = payload.monthlyLetters ?? [:]
            savedQueries = payload.savedQueries ?? []
            timelineAnnotations = payload.timelineAnnotations ?? [:]
            dismissedDrafts = Set(payload.dismissedDrafts.keys)
            careAcknowledgments = Set(payload.careAcknowledgments.keys)
            autoDraftPaused = payload.autoDraftPaused ?? false
            if let restoredData = payload.data {
                baseData = restoredData
            }
            externalSourceError = nil
            hasLocalChanges = hasPersistentLocalEdits

            let restoredState = UserState(
                entries: payload.overrides,
                quickCaptures: payload.quickCaptures,
                dismissedDrafts: payload.dismissedDrafts,
                careAcknowledgments: payload.careAcknowledgments,
                autoDraftPaused: payload.autoDraftPaused ?? false,
                draftPausedUntil: draftPausedUntil,
                monthlyLetters: payload.monthlyLetters ?? [:],
                savedQueries: payload.savedQueries ?? [],
                timelineAnnotations: payload.timelineAnnotations ?? [:],
                dailyGoals: payload.dailyGoals ?? [:],
                journalDrafts: payload.journalDrafts ?? [:]
            )
            try persist(restoredState)

            loadExternalOrBundledSnapshot()
            watchExternalSnapshot()
            isEncrypted = true
            localStateReadFailed = false
            saveState = .saved(Date())
            try RestoreRecoveryJournal.synchronizeCommittedStores(in: supportDirectory)
            try RestoreRecoveryJournal.clear(in: supportDirectory)
        } catch {
            var rollbackFailures: [String] = []
            if attemptedExternalRestore, let rollbackExternalData {
                do {
                    try rollbackExternalData()
                } catch {
                    rollbackFailures.append("外部事实库：\(UserFacingError.message(for: error))")
                }
            }
            if startedLocalCommit {
                do {
                    try restoreLocalCheckpoint(checkpoint)
                } catch {
                    rollbackFailures.append("本地日记状态：\(UserFacingError.message(for: error))")
                }
            }
            if rollbackFailures.isEmpty {
                do {
                    try RestoreRecoveryJournal.synchronizeCommittedStores(in: supportDirectory)
                    try RestoreRecoveryJournal.clear(in: supportDirectory)
                } catch {
                    rollbackFailures.append("持久恢复记录：\(UserFacingError.message(for: error))")
                }
            }
            guard rollbackFailures.isEmpty else {
                throw NSError(
                    domain: "RiverDiaryMac",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "备份恢复失败：\(UserFacingError.message(for: error))；\(rollbackFailures.joined(separator: "；"))。恢复记录已保留，下次启动会再次尝试回滚。"]
                )
            }
            throw error
        }
    }

    func exportCurrentData(to url: URL) throws {
        guard let data else {
            throw NSError(domain: "RiverDiaryMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "没有可导出的数据"])
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(data).write(to: url, options: .atomic)
    }

    var localChangeCount: Int {
        var dates = Set(dailyGoals.keys)
        let entryDates = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.date) })
        for id in overrides.keys {
            if let date = entryDates[id] { dates.insert(date) }
            else if id.hasPrefix("local-") { dates.insert(String(id.dropFirst("local-".count))) }
            else { dates.insert(id) }
        }
        return dates.count
    }

    var stateFileSummary: String {
        if isEncrypted {
            return "AES-GCM 状态 · SQLCipher 事实库 · 本机密钥"
        }
        return hasLocalChanges ? "本地状态明文（旧版格式）" : "尚未写入修改"
    }

    private func apply(entry id: String, override: EntryOverride) {
        guard let current = data else { return }
        data?.entries = JournalWriting.merging(entries: current.entries, overrides: [id: override])
    }

    private func dateFromLocalID(_ id: String) -> String? {
        guard id.hasPrefix("local-") else { return nil }
        return String(id.dropFirst("local-".count))
    }

    private func loadLocalState() {
        if let stateURL, fileManager.fileExists(atPath: stateURL.path) {
            do {
                let raw = try Data(contentsOf: stateURL)
                let plaintext = try StateEncryption.decrypt(raw)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(UserState.self, from: plaintext)
                overrides = state.entries
                quickCaptures = state.quickCaptures ?? [:]
                monthlyLetters = state.monthlyLetters ?? [:]
                savedQueries = state.savedQueries ?? []
                timelineAnnotations = state.timelineAnnotations ?? [:]
                journalDrafts = state.journalDrafts ?? [:]
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                dailyGoals = state.dailyGoals ?? [:]
                hasLocalChanges = hasPersistentLocalEdits
                isEncrypted = true
            } catch {
                localStateReadFailed = true
                loadError = UserFacingError.message(for: error)
            }
            return
        }

        if let legacyStateURL, fileManager.fileExists(atPath: legacyStateURL.path) {
            do {
                let raw = try Data(contentsOf: legacyStateURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(UserState.self, from: raw)
                overrides = state.entries
                quickCaptures = state.quickCaptures ?? [:]
                monthlyLetters = state.monthlyLetters ?? [:]
                savedQueries = state.savedQueries ?? []
                timelineAnnotations = state.timelineAnnotations ?? [:]
                journalDrafts = state.journalDrafts ?? [:]
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                dailyGoals = state.dailyGoals ?? [:]
                hasLocalChanges = hasPersistentLocalEdits
                try persist()
                try? fileManager.removeItem(at: legacyStateURL)
                isEncrypted = true
            } catch {
                localStateReadFailed = true
                loadError = "旧版本地日记迁移失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadExternalOrBundledSnapshot() {
        var bundledURL = Bundle.module.url(forResource: "data", withExtension: "json")
        if let externalURL = externalSourceURL, FileManager.default.fileExists(atPath: externalURL.path) {
            bundledURL = externalURL
        }

        guard let url = bundledURL else {
            let seeds = quickCaptures.keys.map { DiaryEntry(pageID: "ingested-\($0)", date: $0) }
            let empty = DiaryData(generated: "", today: "", poem: "情绪会沉淀，日子会向前。", entries: JournalWriting.merging(entries: seeds, overrides: overrides))
            baseData = empty
            data = empty
            return
        }

        // Read and parse off the main thread, then merge on MainActor.
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let decoded = await Self.parseSnapshot(from: url) else {
                self.loadError = "无法读取日记数据文件。"
                return
            }
            baseData = decoded
            self.mergeSnapshotData(decoded, from: url)
        }
    }

    private nonisolated static func parseSnapshot(from url: URL) async -> DiaryData? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return try? JSONDecoder().decode(DiaryData.self, from: raw)
        }.value
    }

    private func mergeSnapshotData(_ decoded: DiaryData, from url: URL) {
        var effective = decoded
        let knownDates = Set(effective.entries.map(\.date))
        let ingestedDates = Set(ingestedHealth.keys).union(ingestedScores.keys).union(quickCaptures.keys)
        for date in ingestedDates.subtracting(knownDates).sorted() {
            effective.entries.append(DiaryEntry(pageID: "ingested-\(date)", date: date))
        }
        for index in effective.entries.indices {
            let date = effective.entries[index].date
            if let health = ingestedHealth[date] { effective.entries[index].health = health }
            if let score = ingestedScores[date] {
                effective.entries[index].score = Double(score)
                var metrics = effective.entries[index].metrics ?? DayMetrics()
                metrics.mood = Double(score)
                effective.entries[index].metrics = metrics
            }
        }
        effective.entries = JournalWriting.merging(entries: effective.entries, overrides: overrides)
        data = effective
        loadError = nil
        externalSourceModifiedAt = fileModificationDate(for: url)
    }

    private func watchExternalSnapshot() {
        // DispatchSource 的 cancel handler 是 descriptor 的唯一关闭点，避免重复 close。
        observerFileDescriptor = -1
        sourceObserver?.cancel()
        sourceObserver = nil

        guard let url = externalSourceURL else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        observerFileDescriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkExternalSnapshotChanged()
            }
        }

        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        source.resume()
        sourceObserver = source
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func makeRestoreCheckpoint() throws -> DiaryStoreRestoreCheckpoint {
        guard let stateURL, let supportDirectory else {
            throw NSError(domain: "RiverDiaryMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用支持目录"])
        }
        let restoredDataURL = supportDirectory.appendingPathComponent("RestoredBackup.json", isDirectory: false)
        return DiaryStoreRestoreCheckpoint(
            data: data,
            baseData: baseData,
            overrides: overrides,
            quickCaptures: quickCaptures,
            dailyGoals: dailyGoals,
            journalDrafts: journalDrafts,
            monthlyLetters: monthlyLetters,
            savedQueries: savedQueries,
            timelineAnnotations: timelineAnnotations,
            dismissedDrafts: dismissedDrafts,
            careAcknowledgments: careAcknowledgments,
            autoDraftPaused: autoDraftPaused,
            hasLocalChanges: hasLocalChanges,
            externalSourceURL: externalSourceURL,
            externalSourceError: externalSourceError,
            externalSourceModifiedAt: externalSourceModifiedAt,
            localStateReadFailed: localStateReadFailed,
            isEncrypted: isEncrypted,
            loadError: loadError,
            saveState: saveState,
            stateFile: try captureRestoreFile(at: stateURL),
            restoredDataFile: try captureRestoreFile(at: restoredDataURL),
            externalSourceDefault: UserDefaults.standard.string(forKey: externalSourceKey)
        )
    }

    private func captureRestoreFile(at url: URL?) throws -> BackupRestoreFileCheckpoint {
        guard let url else { return BackupRestoreFileCheckpoint(url: nil, existed: false, data: nil) }
        let existed = fileManager.fileExists(atPath: url.path)
        let bytes = existed ? try Data(contentsOf: url) : nil
        return BackupRestoreFileCheckpoint(url: url, existed: existed, data: bytes)
    }

    private func restoreLocalCheckpoint(_ checkpoint: DiaryStoreRestoreCheckpoint) throws {
        data = checkpoint.data
        baseData = checkpoint.baseData
        overrides = checkpoint.overrides
        quickCaptures = checkpoint.quickCaptures
        dailyGoals = checkpoint.dailyGoals
        journalDrafts = checkpoint.journalDrafts
        monthlyLetters = checkpoint.monthlyLetters
        savedQueries = checkpoint.savedQueries
        timelineAnnotations = checkpoint.timelineAnnotations
        dismissedDrafts = checkpoint.dismissedDrafts
        careAcknowledgments = checkpoint.careAcknowledgments
        autoDraftPaused = checkpoint.autoDraftPaused
        hasLocalChanges = checkpoint.hasLocalChanges
        externalSourceURL = checkpoint.externalSourceURL
        externalSourceError = checkpoint.externalSourceError
        externalSourceModifiedAt = checkpoint.externalSourceModifiedAt
        localStateReadFailed = checkpoint.localStateReadFailed
        isEncrypted = checkpoint.isEncrypted
        loadError = checkpoint.loadError
        saveState = checkpoint.saveState
        if let externalSourceDefault = checkpoint.externalSourceDefault {
            UserDefaults.standard.set(externalSourceDefault, forKey: externalSourceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: externalSourceKey)
        }

        var failures: [String] = []
        for fileCheckpoint in [checkpoint.stateFile, checkpoint.restoredDataFile] {
            do {
                try restoreFileCheckpoint(fileCheckpoint)
            } catch {
                failures.append(UserFacingError.message(for: error))
            }
        }
        guard failures.isEmpty else {
            throw NSError(
                domain: "RiverDiaryMac",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "；")]
            )
        }
    }

    private func restoreFileCheckpoint(_ checkpoint: BackupRestoreFileCheckpoint) throws {
        guard let url = checkpoint.url else { return }
        if checkpoint.existed {
            guard let data = checkpoint.data else {
                throw NSError(domain: "RiverDiaryMac", code: 15, userInfo: [NSLocalizedDescriptionKey: "恢复检查点缺少原文件内容。"])
            }
            try data.write(to: url, options: .atomic)
            try LocalStorageProtection.protectFile(at: url)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func persist(
        overrides replacementOverrides: [String: EntryOverride]? = nil,
        monthlyLetters replacementLetters: [String: MonthlyLetter]? = nil,
        savedQueries replacementQueries: [SavedQuery]? = nil,
        timelineAnnotations replacementAnnotations: [String: TimelineAnnotation]? = nil,
        dailyGoals replacementDailyGoals: [String: DailyGoal]? = nil,
        journalDrafts replacementJournalDrafts: [String: JournalDraftRecord]? = nil
    ) throws {
        guard supportDirectory != nil else {
            throw NSError(domain: "RiverDiaryMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用支持目录"])
        }

        let state = UserState(
            entries: replacementOverrides ?? overrides,
            quickCaptures: quickCaptures,
            dismissedDrafts: dismissedDrafts.reduce(into: [:]) { result, value in result[value] = Date() },
            careAcknowledgments: careAcknowledgments.reduce(into: [:]) { result, value in result[value] = Date() },
            autoDraftPaused: autoDraftPaused,
            draftPausedUntil: draftPausedUntil,
            monthlyLetters: replacementLetters ?? monthlyLetters,
            savedQueries: replacementQueries ?? savedQueries,
            timelineAnnotations: replacementAnnotations ?? timelineAnnotations,
            dailyGoals: replacementDailyGoals ?? dailyGoals,
            journalDrafts: replacementJournalDrafts ?? journalDrafts
        )
        try persist(state)
    }

    private func persist(_ state: UserState) throws {
        guard let stateURL, let supportDirectory else {
            throw NSError(domain: "RiverDiaryMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用支持目录"])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(state)
        let encrypted = try StateEncryption.encrypt(plaintext)
        try encrypted.write(to: stateURL, options: .atomic)
        try LocalStorageProtection.protectFile(at: stateURL)

        if !fileManager.fileExists(atPath: supportDirectory.path) {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }
        isEncrypted = true
    }
}
