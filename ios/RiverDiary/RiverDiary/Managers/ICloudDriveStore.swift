import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ICloudDriveStore: ObservableObject {
    @Published private(set) var hasAccess = false
    @Published private(set) var isWriting = false
    @Published var lastError: String?

    private static let fileName = "river-diary-user-data.json"
    private var securityScopedURL: URL?
    private var bookmarkData: Data?

    init() {
        restoreBookmark()
    }

    var isAvailable: Bool { hasAccess }

    var accessedFolder: URL? { securityScopedURL }
    var folderDisplayName: String? { securityScopedURL?.lastPathComponent }

    func handlePickedFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: "icloud-drive-bookmark")
            securityScopedURL = url
            bookmarkData = data
            hasAccess = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func restoreBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "icloud-drive-bookmark") else { return }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                if let refreshed = try? url.bookmarkData() {
                    UserDefaults.standard.set(refreshed, forKey: "icloud-drive-bookmark")
                }
            }
            securityScopedURL = url
            bookmarkData = data
            hasAccess = true
        } catch {
            hasAccess = false
        }
    }

    private func resolveURL() -> URL? {
        guard let data = bookmarkData else { return nil }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            return url
        } catch {
            return nil
        }
    }

    func saveUserData(_ data: UserDataSnapshot) async {
        guard let folder = resolveURL() else {
            lastError = "iCloud Drive 文件夹未设置"
            return
        }
        isWriting = true
        lastError = nil
        defer { isWriting = false }

        do {
            let accessed = folder.startAccessingSecurityScopedResource()
            defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
            let mergedData = await mergeUserData(data, folder: folder)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let json = try encoder.encode(mergedData)
            let fileURL = folder.appendingPathComponent(Self.fileName)
            try json.write(to: fileURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func mergeUserData(_ incoming: UserDataSnapshot, folder: URL) async -> UserDataSnapshot {
        let fileURL = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return incoming }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let existing = try decoder.decode(UserDataSnapshot.self, from: Data(contentsOf: fileURL))
            var merged = incoming
            if incoming.moodScores.isEmpty { merged.moodScores = existing.moodScores }
            if incoming.sleepNights.isEmpty { merged.sleepNights = existing.sleepNights }
            if incoming.exerciseDays.isEmpty { merged.exerciseDays = existing.exerciseDays }
            if incoming.quickNotes.isEmpty { merged.quickNotes = existing.quickNotes }
            return merged
        } catch {
            return incoming
        }
    }
}

struct UserDataSnapshot: Codable {
    var updatedAt: Date
    var moodScores: [String: Int]
    var sleepNights: [SleepNightSnapshot]
    var exerciseDays: [ExerciseDaySnapshot]
    var quickNotes: [QuickNoteSnapshot]

    init(
        updatedAt: Date,
        moodScores: [String: Int],
        sleepNights: [SleepNightSnapshot],
        exerciseDays: [ExerciseDaySnapshot],
        quickNotes: [QuickNoteSnapshot]
    ) {
        self.updatedAt = updatedAt
        self.moodScores = moodScores
        self.sleepNights = sleepNights
        self.exerciseDays = exerciseDays
        self.quickNotes = quickNotes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date(),
            moodScores: try container.decodeIfPresent([String: Int].self, forKey: .moodScores) ?? [:],
            sleepNights: try container.decodeIfPresent([SleepNightSnapshot].self, forKey: .sleepNights) ?? [],
            exerciseDays: try container.decodeIfPresent([ExerciseDaySnapshot].self, forKey: .exerciseDays) ?? [],
            quickNotes: try container.decodeIfPresent([QuickNoteSnapshot].self, forKey: .quickNotes) ?? []
        )
    }
}

struct SleepNightSnapshot: Codable {
    var date: String
    var totalHours: Double
    var deepMinutes: Double
    var remMinutes: Double
    var awakeMinutes: Double
}

struct QuickNoteSnapshot: Codable {
    var date: String
    var text: String
    var createdAt: Date
}

struct ExerciseDaySnapshot: Codable {
    var date: String
    var steps: Double
    var distanceKilometers: Double
    var activeEnergyKilocalories: Double
}
