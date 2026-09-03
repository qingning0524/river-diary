import SwiftUI

@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var data: DiaryData?
    @Published var selectedEntryID: String?
    @Published var loadError: String?
    @Published private(set) var drive = ICloudDriveStore()

    private let overrideKey = "local-diary-scores"
    private var bundleScores: [String: Int?] = [:]

    var entries: [DiaryEntry] {
        (data?.entries ?? []).sorted { $0.date > $1.date }
    }

    var selectedEntry: DiaryEntry? {
        entries.first { $0.id == selectedEntryID } ?? entries.first
    }

    var latestEntry: DiaryEntry? { entries.first }

    init() {
        loadBundleData()
    }

    func select(_ entry: DiaryEntry?) {
        selectedEntryID = entry?.id
    }

    private func loadBundleData() {
        guard let url = Bundle.main.url(forResource: "data", withExtension: "json") else {
            loadError = "没有找到 data.json"
            return
        }

        do {
            let raw = try Data(contentsOf: url)
            var decoded = try JSONDecoder().decode(DiaryData.self, from: raw)
            bundleScores = Dictionary(uniqueKeysWithValues: decoded.entries.map {
                ($0.pageID, $0.score.map { Int($0.rounded()) })
            })
            let overrides = localScores()
            for index in decoded.entries.indices {
                let entry = decoded.entries[index]
                if let score = overrides[entry.pageID] {
                    decoded.entries[index].score = Double(score)
                    decoded.entries[index].stage = Scoring.stage(for: score)
                    decoded.entries[index].metrics?.mood = Double(score)
                }
            }
            data = decoded
            selectedEntryID = data?.entries.max(by: { $0.date < $1.date })?.pageID

            Task { [weak self] in
                await self?.loadFromICloudDrive()
                await self?.applyRemoteScores()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func applyRemoteScores() async {
    }

    func refreshFromICloud() async {
        await loadFromICloudDrive()
    }

    func saveHealthSnapshot(
        sleepNights: [SleepNight],
        exerciseDays: [ExerciseDay]
    ) async {
        guard drive.hasAccess else { return }

        let dateFormatter = HealthKitStore.dayFormatter
        var moodScores: [String: Int] = [:]
        for entry in data?.entries ?? [] {
            if let score = entry.score {
                moodScores[entry.date] = Int(score.rounded())
            }
        }

        await drive.saveUserData(
            UserDataSnapshot(
                updatedAt: Date(),
                moodScores: moodScores,
                sleepNights: sleepNights.map { night in
                    SleepNightSnapshot(
                        date: dateFormatter.string(from: night.date),
                        totalHours: night.totalHours,
                        deepMinutes: night.deep / 60,
                        remMinutes: night.rem / 60,
                        awakeMinutes: night.awake / 60
                    )
                },
                exerciseDays: exerciseDays.map { day in
                    ExerciseDaySnapshot(
                        date: dateFormatter.string(from: day.date),
                        exerciseMinutes: day.exerciseMinutes,
                        steps: day.steps,
                        distanceKilometers: day.distanceKilometers,
                        activeEnergyKilocalories: day.activeEnergyKilocalories
                    )
                },
                quickNotes: []
            )
        )
    }

    private func loadFromICloudDrive() async {
        guard drive.hasAccess, let folder = drive.accessedFolder else { return }
        let fileURL = folder.appendingPathComponent("data.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let remoteData = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(DiaryData.self, from: remoteData)

            if let current = data, decoded.generated > current.generated {
                var updated = decoded
                let overrides = localScores()
                for index in updated.entries.indices {
                    let entry = updated.entries[index]
                    if let score = overrides[entry.pageID] {
                        updated.entries[index].score = Double(score)
                        updated.entries[index].stage = Scoring.stage(for: score)
                        updated.entries[index].metrics?.mood = Double(score)
                    }
                }
                data = updated
                selectedEntryID = updated.entries.max(by: { $0.date < $1.date })?.pageID
            } else if data == nil {
                data = decoded
            }
        } catch {
        }
    }

    func setScore(_ score: Int, for entry: DiaryEntry) {
        let validScore = min(100, max(0, score))
        guard var updatedData = data,
              let index = updatedData.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        updatedData.entries[index].score = Double(validScore)
        updatedData.entries[index].stage = Scoring.stage(for: validScore)
        updatedData.entries[index].metrics?.mood = Double(validScore)
        data = updatedData

        var overrides = localScores()
        overrides[entry.pageID] = validScore
        UserDefaults.standard.set(overrides, forKey: overrideKey)

        Task { [weak self] in
            guard let self, let data = self.data else { return }
            var moodScores: [String: Int] = [:]
            for entry in data.entries {
                if let score = entry.score {
                    moodScores[entry.date] = Int(score.rounded())
                }
            }
            let snapshot = UserDataSnapshot(
                updatedAt: Date(),
                moodScores: moodScores,
                sleepNights: [],
                exerciseDays: [],
                quickNotes: []
            )
            await self.drive.saveUserData(snapshot)
        }
    }

    private func localScores() -> [String: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: overrideKey) as? [String: NSNumber] ?? [:]
        return raw.mapValues(\.intValue)
    }

    var hasLocalScoreEdits: Bool {
        !localScores().isEmpty
    }

    func resetLocalScores() {
        guard var updatedData = data else { return }

        for index in updatedData.entries.indices {
            let pageID = updatedData.entries[index].pageID
            let score = bundleScores[pageID] ?? nil
            updatedData.entries[index].score = score.map(Double.init)
            updatedData.entries[index].stage = score.map { Scoring.stage(for: $0) }
            updatedData.entries[index].metrics?.mood = score.map(Double.init)
        }

        data = updatedData
        UserDefaults.standard.removeObject(forKey: overrideKey)
    }
}
