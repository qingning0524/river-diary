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
    private let preferences: UserDefaults

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
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
        guard accessed else {
            markAccessLost()
            throw CocoaError(.fileReadNoPermission)
        }
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        let fileURL = folder.appendingPathComponent(Self.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserDataSnapshot.self, from: CoordinatedFileIO.read(fileURL))
    }

    func readLegacyUserDataAsynchronously() async throws -> UserDataSnapshot? {
        guard let folder = resolveURL() else { return nil }
        let accessed = folder.startAccessingSecurityScopedResource()
        guard accessed else {
            markAccessLost()
            throw CocoaError(.fileReadNoPermission)
        }
        defer { folder.stopAccessingSecurityScopedResource() }
        let fileURL = folder.appendingPathComponent(Self.fileName)
        let data = try await Task.detached(priority: .utility) { () -> Data? in
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return try CoordinatedFileIO.read(fileURL)
        }.value
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UserDataSnapshot.self, from: data)
    }

    func handlePickedFolder(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        guard accessed else {
            lastError = "无法访问所选的 iCloud Drive 文件夹。请重新选择该文件夹。"
            return
        }
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try SecurityScopedBookmark.create(for: url)
            preferences.set(data, forKey: "icloud-drive-bookmark")
            securityScopedURL = url
            bookmarkData = data
            hasAccess = true
            lastError = nil
        } catch {
            lastError = "无法保存 iCloud Drive 文件夹授权。请重新选择该文件夹。"
        }
    }

    private func restoreBookmark() {
        guard let data = preferences.data(forKey: "icloud-drive-bookmark") else { return }
        do {
            let resolution = try SecurityScopedBookmark.resolve(data)
            let url = resolution.url
            let stale = resolution.isStale
            var activeBookmark = data
            if stale {
                if let refreshed = try? SecurityScopedBookmark.create(for: url) {
                    preferences.set(refreshed, forKey: "icloud-drive-bookmark")
                    activeBookmark = refreshed
                }
            }
            securityScopedURL = url
            bookmarkData = activeBookmark
            hasAccess = true
            lastError = nil
        } catch {
            markAccessLost()
        }
    }

    private func resolveURL() -> URL? {
        guard let data = bookmarkData else { return nil }
        do {
            let result = try SecurityScopedBookmark.resolve(data)
            if result.isStale, let refreshed = try? SecurityScopedBookmark.create(for: result.url) {
                bookmarkData = refreshed
                preferences.set(refreshed, forKey: "icloud-drive-bookmark")
            }
            securityScopedURL = result.url
            hasAccess = true
            lastError = nil
            return result.url
        } catch {
            markAccessLost()
            return nil
        }
    }

    func markAccessLost() {
        hasAccess = false
        securityScopedURL = nil
        lastError = "无法访问已授权的共享文件夹。请重新选择 iCloud Drive 文件夹；本机记录仍可继续使用。"
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
