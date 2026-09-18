import Combine
import Foundation

enum JournalSaveState: Equatable {
    case idle
    case saving
    case saved(Date)
    case failed(String)
}

struct LocalBackupPayload: Codable {
    var version = 3
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

    private lazy var supportDirectory: URL? = {
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let target = directory.appendingPathComponent("RiverDiaryMac", isDirectory: true)
        try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        return target
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

    init() {
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
            saveState = .failed(error.localizedDescription)
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
            hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !updated.isEmpty
            saveState = .saved(Date())
        } catch {
            saveState = .failed(error.localizedDescription)
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
        try persist(savedQueries: updated)
        savedQueries = updated
        hasLocalChanges = true
        saveState = .saved(Date())
    }

    func markSavedQueryUsed(_ id: UUID) {
        guard let index = savedQueries.firstIndex(where: { $0.id == id }) else { return }
        savedQueries[index].lastUsedAt = Date()
        do {
            try persist(savedQueries: savedQueries)
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func removeSavedQuery(_ query: SavedQuery) {
        savedQueries.removeAll { $0.id == query.id }
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !timelineAnnotations.isEmpty
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
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

    func addQuickCapture(_ text: String, tag: String? = nil, for date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard !localStateReadFailed else {
            saveState = .failed("本地日记尚未成功读取，请重新打开应用后再保存。")
            return
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
        } catch {
            quickCaptures[dateString] = previousCaptures
            hasLocalChanges = previouslyChanged
            saveState = .failed(error.localizedDescription)
        }
    }

    func removeQuickCapture(_ capture: QuickCapture, entry: DiaryEntry) {
        quickCaptures[entry.date]?.removeAll { $0.id == capture.id }
        if quickCaptures[entry.date]?.isEmpty == true {
            quickCaptures[entry.date] = nil
        }
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !timelineAnnotations.isEmpty
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func setQuickCapturePinned(_ capture: QuickCapture, entry: DiaryEntry, pinned: Bool) {
        guard let index = quickCaptures[entry.date]?.firstIndex(where: { $0.id == capture.id }) else { return }
        quickCaptures[entry.date]?[index].isPinned = pinned
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func draftDismissed(_ entry: DiaryEntry) -> Bool {
        dismissedDrafts.contains(entry.id)
    }

    func dismissDraft(for entry: DiaryEntry) {
        dismissedDrafts.insert(entry.id)
        careAcknowledgments.insert(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func restoreDraft(for entry: DiaryEntry) {
        dismissedDrafts.remove(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func acknowledgeCare(_ entry: DiaryEntry) {
        careAcknowledgments.insert(entry.id)
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func careAcknowledged(_ entry: DiaryEntry) -> Bool {
        careAcknowledgments.contains(entry.id)
    }

    func setAutoDraftPaused(_ paused: Bool) {
        autoDraftPaused = paused
        if paused { draftPausedUntil = nil }
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    var isAutoDraftTemporarilyPaused: Bool {
        guard let until = draftPausedUntil else { return false }
        return until > Date()
    }

    func pauseAutoDraft(days: Int) {
        let dayCount = min(7, max(1, days))
        draftPausedUntil = Calendar.current.date(byAdding: .day, value: dayCount, to: Date())
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
    }

    func resumeAutoDraftPause() {
        draftPausedUntil = nil
        hasLocalChanges = true
        do { try persist() } catch { saveState = .failed(error.localizedDescription) }
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
        do {
            try persist(overrides: updated)
            overrides = updated
            apply(entry: entry.id, override: value)
            hasLocalChanges = true
            saveState = .saved(Date())
        } catch {
            saveState = .failed(error.localizedDescription)
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

        overrides[entry.id] = override
        hasLocalChanges = true
        apply(entry: entry.id, override: override)

        saveState = .saving
        do {
            try persist()
            saveState = .saved(Date())
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func clearOverride(for entry: DiaryEntry) {
        guard overrides[entry.id] != nil else { return }

        overrides[entry.id] = nil
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !timelineAnnotations.isEmpty
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
            saveState = .failed(error.localizedDescription)
        }
    }

    func clearLocalJournal() {
        overrides = [:]
        dismissedDrafts = []
        careAcknowledgments = []
        savedQueries = []
        hasLocalChanges = !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !timelineAnnotations.isEmpty
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
            if !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !timelineAnnotations.isEmpty {
                try persist()
            } else {
                isEncrypted = false
            }
        } catch {
            saveState = .failed(error.localizedDescription)
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
            externalSourceError = "无法读取素材文件：\(error.localizedDescription)"
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
                saveState = .failed(error.localizedDescription)
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
                saveState = .failed(error.localizedDescription)
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

    func exportFullBackup(to url: URL, activitySessions exportedActivity: [ActivitySession] = []) throws {
        guard let data else {
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
            timelineAnnotations: timelineAnnotations
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encrypted = try StateEncryption.encrypt(try encoder.encode(payload))
        try encrypted.write(to: url, options: .atomic)
    }

    func restoreFullBackup(from url: URL, restoreActivity: (([ActivitySession]) throws -> Void)? = nil) throws {
        let raw = try Data(contentsOf: url)
        guard let plaintext = try? StateEncryption.decrypt(raw) else {
            throw NSError(domain: "RiverDiaryMac", code: 11, userInfo: [NSLocalizedDescriptionKey: "备份文件无法解密，请确认这是本应用生成的完整备份"])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(LocalBackupPayload.self, from: plaintext)

        overrides = payload.overrides
        quickCaptures = payload.quickCaptures
        monthlyLetters = payload.monthlyLetters ?? [:]
        savedQueries = payload.savedQueries ?? []
        timelineAnnotations = payload.timelineAnnotations ?? [:]
        dismissedDrafts = Set(payload.dismissedDrafts.keys)
        careAcknowledgments = Set(payload.careAcknowledgments.keys)
        autoDraftPaused = payload.autoDraftPaused ?? false
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !timelineAnnotations.isEmpty

        if let restoredData = payload.data, let directory = supportDirectory {
            let restoredURL = directory.appendingPathComponent("RestoredBackup.json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(restoredData).write(to: restoredURL, options: .atomic)
            externalSourceURL = restoredURL
            UserDefaults.standard.set(restoredURL.path, forKey: externalSourceKey)
        } else if let path = payload.sourcePath, FileManager.default.fileExists(atPath: path) {
            externalSourceURL = URL(fileURLWithPath: path)
            UserDefaults.standard.set(path, forKey: externalSourceKey)
        } else {
            externalSourceURL = nil
            UserDefaults.standard.removeObject(forKey: externalSourceKey)
        }

        if let restoredData = payload.data {
            baseData = restoredData
        }

        externalSourceError = nil
        loadExternalOrBundledSnapshot()
        try persist()
        isEncrypted = true
        try restoreActivity?(payload.activitySessions ?? [])
        localStateReadFailed = false
        saveState = .saved(Date())
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
        overrides.count
    }

    var stateFileSummary: String {
        if isEncrypted {
            return "AES-GCM 加密 · 本机用户权限保护密钥"
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
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !timelineAnnotations.isEmpty
                isEncrypted = true
            } catch {
                localStateReadFailed = true
                loadError = "本地日记无法读取：\(error.localizedDescription)"
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
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty || !monthlyLetters.isEmpty || !savedQueries.isEmpty || !timelineAnnotations.isEmpty
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

    private func persist(
        overrides replacementOverrides: [String: EntryOverride]? = nil,
        monthlyLetters replacementLetters: [String: MonthlyLetter]? = nil,
        savedQueries replacementQueries: [SavedQuery]? = nil,
        timelineAnnotations replacementAnnotations: [String: TimelineAnnotation]? = nil
    ) throws {
        guard let stateURL, let supportDirectory else {
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
            timelineAnnotations: replacementAnnotations ?? timelineAnnotations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(state)
        let encrypted = try StateEncryption.encrypt(plaintext)
        try encrypted.write(to: stateURL, options: .atomic)

        if !fileManager.fileExists(atPath: supportDirectory.path) {
            try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        }
        isEncrypted = true
    }
}
