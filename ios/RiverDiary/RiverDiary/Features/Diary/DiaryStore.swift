import SwiftUI
import RiverDiaryCore

@MainActor
final class DiaryStore: ObservableObject {
    @Published private(set) var data: DiaryData?
    @Published var selectedEntryID: String?
    @Published var loadError: String?
    @Published private(set) var syncStatus: String = "未检查"
    @Published private(set) var syncError: String?
    @Published private(set) var remoteGenerated: String?
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var drive = ICloudDriveStore()

    private let overrideKey = "local-diary-scores"
    private var bundleScores: [String: Int?] = [:]
    private var syncedMoodScores: [String: Int] = [:]
    private var syncedMoodResets = Set<String>()
    private var latestRemoteDiarySnapshot: DiaryData?
    private var latestRemoteDiarySnapshotBytes: Data?
    var onScoreChanged: ((DiaryEntry, Int) -> Void)?
    var onScoreReset: ((String) -> Void)?
    var onLegacyDiarySnapshotLoaded: ((DiaryData) -> Void)? {
        didSet {
            if let latestRemoteDiarySnapshot {
                onLegacyDiarySnapshotLoaded?(latestRemoteDiarySnapshot)
            }
        }
    }

    var entries: [DiaryEntry] {
        (data?.entries ?? []).sorted { $0.date > $1.date }
    }

    var selectedEntry: DiaryEntry? {
        entries.first { $0.id == selectedEntryID } ?? entries.first
    }

    var latestEntry: DiaryEntry? { entries.first }
    var localMoodScoresByDate: [String: Int] {
        let overrides = localScores()
        return Dictionary(uniqueKeysWithValues: (data?.entries ?? []).compactMap { entry in
            guard let score = overrides[entry.pageID] else { return nil }
            return (entry.date, score)
        })
    }

    init(snapshotURL: URL? = Bundle.main.url(forResource: "data", withExtension: "json")) {
        loadBundleData(from: snapshotURL)
    }

    func select(_ entry: DiaryEntry?) {
        selectedEntryID = entry?.id
    }

    private func loadBundleData(from snapshotURL: URL?) {
        guard let url = snapshotURL else {
            // New installs have no personal archive. The local event database is
            // still usable; missing optional legacy data is an ordinary empty state.
            data = DiaryData(generated: "", today: "", poem: "", entries: [])
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
            applySyncedMoodState(to: &decoded)
            data = decoded
            selectedEntryID = data?.entries.max(by: { $0.date < $1.date })?.pageID

            Task { [weak self] in
                await self?.loadFromICloudDrive()
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func refreshFromICloud() async {
        await loadFromICloudDrive()
    }

    func applySyncedMoodState(scores: [String: Int], resetDays: Set<String>) {
        syncedMoodScores = scores
        syncedMoodResets = resetDays
        guard var updated = data else { return }
        applySyncedMoodState(to: &updated)
        data = updated
    }

    private func applySyncedMoodState(to data: inout DiaryData) {
        for index in data.entries.indices {
            let day = data.entries[index].date
            if let score = syncedMoodScores[day] {
                data.entries[index].score = Double(score)
                data.entries[index].stage = Scoring.stage(for: score)
                data.entries[index].metrics?.mood = Double(score)
            } else if syncedMoodResets.contains(day) {
                let bundled = bundleScores[data.entries[index].pageID] ?? nil
                data.entries[index].score = bundled.map(Double.init)
                data.entries[index].stage = bundled.map(Scoring.stage(for:))
                data.entries[index].metrics?.mood = bundled.map(Double.init)
            }
        }
    }

    private func loadFromICloudDrive() async {
        guard drive.hasAccess, let folder = drive.accessedFolder else {
            syncStatus = "iCloud Drive 未连接"
            return
        }
        let fileURL = folder.appendingPathComponent("data.json")

        let accessed = folder.startAccessingSecurityScopedResource()
        guard accessed else {
            drive.markAccessLost()
            syncStatus = "共享文件夹授权失效，请重新选择 iCloud Drive 文件夹。"
            syncError = drive.lastError
            return
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        do {
            let result = try await Task.detached(priority: .utility) { () throws -> (data: Data?, status: String?) in
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    return (nil, "正在等待 iCloud 下载")
                }
                let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                guard resourceValues.ubiquitousItemDownloadingStatus == .current else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    return (nil, "正在下载最新数据")
                }
                return (try CoordinatedFileIO.read(fileURL), nil)
            }.value
            guard let remoteData = result.data else {
                syncStatus = result.status ?? "正在等待 iCloud 下载"
                syncError = nil
                return
            }
            let decoded = try JSONDecoder().decode(DiaryData.self, from: remoteData)
            remoteGenerated = decoded.generated
            lastSyncDate = Date()
            syncStatus = "已同步"
            syncError = nil
            publishLegacyDiarySnapshot(decoded, bytes: remoteData)

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
            syncStatus = "同步失败"
            syncError = error.localizedDescription
            lastSyncDate = Date()
        }
    }

    private func publishLegacyDiarySnapshot(_ snapshot: DiaryData, bytes: Data) {
        guard bytes != latestRemoteDiarySnapshotBytes else { return }
        latestRemoteDiarySnapshotBytes = bytes
        latestRemoteDiarySnapshot = snapshot
        onLegacyDiarySnapshotLoaded?(snapshot)
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
        onScoreChanged?(entry, validScore)
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
        let resetDays = Set(localScores().keys.compactMap { pageID in
            updatedData.entries.first(where: { $0.pageID == pageID })?.date
        })

        for index in updatedData.entries.indices {
            let pageID = updatedData.entries[index].pageID
            let score = bundleScores[pageID] ?? nil
            updatedData.entries[index].score = score.map(Double.init)
            updatedData.entries[index].stage = score.map { Scoring.stage(for: $0) }
            updatedData.entries[index].metrics?.mood = score.map(Double.init)
        }

        data = updatedData
        UserDefaults.standard.removeObject(forKey: overrideKey)
        for day in resetDays { onScoreReset?(day) }
    }
}
