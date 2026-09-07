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
}

@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var data: DiaryData?
    @Published private(set) var loadError: String?
    @Published private(set) var saveState: JournalSaveState = .idle
    @Published private(set) var hasLocalChanges = false
    @Published private(set) var isEncrypted = false
    @Published private(set) var quickCaptures: [String: [QuickCapture]] = [:]
    @Published private(set) var dismissedDrafts: Set<String> = []
    @Published private(set) var careAcknowledgments: Set<String> = []
    @Published private(set) var autoDraftPaused = false
    @Published private(set) var draftPausedUntil: Date?
    @Published private(set) var externalSourceURL: URL?
    @Published private(set) var externalSourceError: String?
    @Published private(set) var externalSourceModifiedAt: Date?

    private var baseData: DiaryData?
    private var overrides: [String: EntryOverride] = [:]
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
            metrics: DayMetrics(mood: 70, energy: 65, focus: 70, output: 65, overall: 68),
            stage: Stage(label: "平稳", color: "#D4A017")
        )
    }

    func captures(for entry: DiaryEntry) -> [QuickCapture] {
        QuickCapture.sortedForDisplay(quickCaptures[entry.date] ?? [])
    }

    func addQuickCapture(_ text: String, tag: String? = nil, for date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let dateString = DiaryEntry.dateFormatter.string(from: date)
        let capture = QuickCapture(text: trimmed, createdAt: Date(), tag: tag?.isEmpty == false ? tag : nil)
        quickCaptures[dateString, default: []].append(capture)
        hasLocalChanges = true
        saveState = .saving
        do {
            try persist()
            saveState = .saved(Date())
        } catch {
            saveState = .failed(error.localizedDescription)
        }
    }

    func removeQuickCapture(_ capture: QuickCapture, entry: DiaryEntry) {
        quickCaptures[entry.date]?.removeAll { $0.id == capture.id }
        if quickCaptures[entry.date]?.isEmpty == true {
            quickCaptures[entry.date] = nil
        }
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty
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
        hasLocalChanges = !overrides.isEmpty
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
        hasLocalChanges = !quickCaptures.isEmpty
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
            if !quickCaptures.isEmpty {
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
            return
        }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date else { return }

        if modified != externalSourceModifiedAt {
            loadExternalOrBundledSnapshot()
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
            activitySessions: exportedActivity
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
        dismissedDrafts = Set(payload.dismissedDrafts.keys)
        careAcknowledgments = Set(payload.careAcknowledgments.keys)
        autoDraftPaused = payload.autoDraftPaused ?? false
        hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty

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
            return "AES-GCM 加密 · 钥匙串保护密钥"
        }
        return hasLocalChanges ? "本地状态明文（旧版格式）" : "尚未写入修改"
    }

    private func apply(entry id: String, override: EntryOverride) {
        guard data != nil else { return }

        if let index = data?.entries.firstIndex(where: { $0.id == id }) {
            data?.entries[index].overview = override.overview
            data?.entries[index].score = Double(overallScore(override))
            data?.entries[index].tags = override.tags
            data?.entries[index].category = override.category
            data?.entries[index].metrics = metrics(for: override)
            data?.entries[index].stage = stage(for: overallScore(override))
        } else if var updatedData = data, let date = dateFromLocalID(id) {
            let newEntry = DiaryEntry(
                pageID: id,
                date: date,
                score: Double(overallScore(override)),
                daily: nil,
                overview: override.overview,
                thoughts: nil,
                memos: nil,
                tags: override.tags,
                category: override.category,
                metrics: metrics(for: override),
                stage: stage(for: overallScore(override))
            )
            updatedData.entries.append(newEntry)
            updatedData.entries.sort { $0.date < $1.date }
            data = updatedData
        }
    }

    private func stage(for score: Int) -> Stage {
        if score >= 70 {
            return Stage(label: "积极", color: "#7CB342")
        }
        if score >= 40 {
            return Stage(label: "平稳", color: "#D4A017")
        }
        return Stage(label: "低落", color: "#E57373")
    }

    private func metrics(for override: EntryOverride) -> DayMetrics {
        DayMetrics(
            mood: Double(override.mood),
            energy: Double(override.energy),
            focus: Double(override.focus),
            output: Double(override.output),
            overall: Double(overallScore(override))
        )
    }

    private func overallScore(_ override: EntryOverride) -> Int {
        Int(Double(override.mood) * 0.4 + Double(override.output) * 0.25 + Double(override.focus) * 0.2 + Double(override.energy) * 0.15)
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
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty
                isEncrypted = true
            } catch {
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
                dismissedDrafts = Set((state.dismissedDrafts ?? [:]).keys)
                careAcknowledgments = Set((state.careAcknowledgments ?? [:]).keys)
                autoDraftPaused = state.autoDraftPaused ?? false
                draftPausedUntil = state.draftPausedUntil
                hasLocalChanges = !overrides.isEmpty || !quickCaptures.isEmpty
                try persist()
                try? fileManager.removeItem(at: legacyStateURL)
                isEncrypted = true
            } catch {
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
            let empty = DiaryData(generated: "", today: "", poem: "情绪会沉淀，日子会向前。", entries: [])
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
            for (index, entry) in decoded.entries.enumerated() {
                if let override = overrides[entry.id] {
                    effective.entries[index].overview = override.overview
                    effective.entries[index].score = Double(overallScore(override))
                    effective.entries[index].tags = override.tags
                    effective.entries[index].category = override.category
                    effective.entries[index].metrics = metrics(for: override)
                    effective.entries[index].stage = stage(for: overallScore(override))
                }
            }

            for (id, override) in overrides where id.hasPrefix("local-") {
                guard let date = dateFromLocalID(id) else { continue }

                effective.entries.append(
                    DiaryEntry(
                        pageID: id,
                        date: date,
                        score: Double(overallScore(override)),
                        daily: nil,
                        overview: override.overview,
                        thoughts: nil,
                        memos: nil,
                        tags: override.tags,
                        category: override.category,
                        metrics: metrics(for: override),
                        stage: stage(for: overallScore(override))
                    )
                )
            }

            let knownDates = Set(effective.entries.map(\.date))
            var ingestedDates = Set(ingestedHealth.keys)
            ingestedScores.keys.forEach { ingestedDates.insert($0) }
            quickCaptures.keys.forEach { ingestedDates.insert($0) }

            for date in ingestedDates.subtracting(knownDates).sorted() {
                let score = ingestedScores[date]
                let metrics = DayMetrics(
                    mood: Double(score ?? 50),
                    energy: 65,
                    focus: 65,
                    output: 65,
                    overall: Double(score ?? 50)
                )
                effective.entries.append(
                    DiaryEntry(
                        pageID: "ingested-\(date)",
                        date: date,
                        score: score.map(Double.init),
                        daily: nil,
                        overview: "",
                        thoughts: nil,
                        memos: nil,
                        tags: [],
                        category: "身心",
                        metrics: metrics,
                        stage: stage(for: score ?? 50)
                    )
                )
            }

            for index in effective.entries.indices {
                let date = effective.entries[index].date
                if let health = ingestedHealth[date] {
                    effective.entries[index].health = health
                }
                if let override = overrides[effective.entries[index].id] {
                    effective.entries[index].overview = override.overview
                    effective.entries[index].score = Double(overallScore(override))
                    effective.entries[index].tags = override.tags
                    effective.entries[index].category = override.category
                    effective.entries[index].metrics = metrics(for: override)
                    effective.entries[index].stage = stage(for: overallScore(override))
                } else if let score = ingestedScores[date] {
                    effective.entries[index].score = Double(score)
                    effective.entries[index].metrics?.mood = Double(score)
                }
            }

            effective.entries.sort { $0.date < $1.date }
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

    private func persist() throws {
        guard let stateURL, let supportDirectory else {
            throw NSError(domain: "RiverDiaryMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法访问应用支持目录"])
        }

        let state = UserState(
            entries: overrides,
            quickCaptures: quickCaptures,
            dismissedDrafts: dismissedDrafts.reduce(into: [:]) { result, value in result[value] = Date() },
            careAcknowledgments: careAcknowledgments.reduce(into: [:]) { result, value in result[value] = Date() },
            autoDraftPaused: autoDraftPaused,
            draftPausedUntil: draftPausedUntil
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
