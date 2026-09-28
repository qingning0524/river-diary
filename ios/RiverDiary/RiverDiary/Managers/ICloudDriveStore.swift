import Foundation
import SwiftUI
import UniformTypeIdentifiers
import RiverDiaryCore

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

    func resolvedFolderURLForSync() -> URL? { resolveURL() }

    func beginSyncActivity() { isWriting = true }
    func endSyncActivity() { isWriting = false }

    func readLegacyUserData() throws -> UserDataSnapshot? {
        guard let folder = resolveURL() else { return nil }
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let fileURL = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserDataSnapshot.self, from: CoordinatedFileIO.read(fileURL))
    }

    func handlePickedFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try SecurityScopedBookmark.create(for: url)
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
            let resolution = try SecurityScopedBookmark.resolve(data)
            let url = resolution.url
            let stale = resolution.isStale
            if stale {
                if let refreshed = try? SecurityScopedBookmark.create(for: url) {
                    UserDefaults.standard.set(refreshed, forKey: "icloud-drive-bookmark")
                    bookmarkData = refreshed
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
            let result = try SecurityScopedBookmark.resolve(data)
            if result.isStale, let refreshed = try? SecurityScopedBookmark.create(for: result.url) {
                bookmarkData = refreshed
                UserDefaults.standard.set(refreshed, forKey: "icloud-drive-bookmark")
            }
            return result.url
        } catch {
            return nil
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
