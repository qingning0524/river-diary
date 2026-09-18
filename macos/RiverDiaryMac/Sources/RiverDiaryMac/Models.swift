import Foundation

struct DiaryData: Codable {
    var generated: String
    var today: String
    var poem: String
    var entries: [DiaryEntry]
}

struct DiaryEntry: Codable, Identifiable, Hashable {
    var pageID: String
    var date: String
    var score: Double?
    var daily: String?
    var overview: String?
    var thoughts: [String]?
    var memos: [String]?
    var tags: [String]?
    var category: String?
    var metrics: DayMetrics?
    var stage: Stage?
    var screenHours: Double?
    var views: Int?
    var screenApps: [ScreenAppUsage]?
    var browseSites: [BrowseSiteUsage]?
    var screenNote: String?
    var browseNote: String?
    var didItems: [DidItem]?
    var health: IOSHealthSummary?

    var id: String { pageID }

    var entryDate: Date? {
        Self.dateFormatter.date(from: date)
    }

    var shortDate: String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(Int(parts[1]) ?? 1)月\(Int(parts[2]) ?? 1)日"
    }

    var stateLabel: String {
        stage?.label ?? "平稳"
    }

    var mood: Int { Int(metrics?.mood ?? score ?? 0) }
    var energy: Int { Int(metrics?.energy ?? score ?? 0) }
    var focus: Int { Int(metrics?.focus ?? score ?? 0) }
    var output: Int { Int(metrics?.output ?? score ?? 0) }
    var overall: Int { Int(metrics?.overall ?? score ?? 0) }

    var displayOverview: String {
        overview?.isEmpty == false ? overview! : daily ?? ""
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case pageID = "page_id"
        case date, score, daily, overview, thoughts, memos, tags, category, metrics, stage
        case screenHours = "screen_h"
        case views, screenApps = "screen_apps", browseSites = "browse_sites"
        case screenNote = "screen_note", browseNote = "browse_note"
        case didItems = "did"
        case health = "ios_health"
    }

    var screenMinutes: Int? {
        guard let hours = screenHours, hours > 0 else {
            return screenApps?.reduce(0) { $0 + ($1.minutes ?? 0) }
        }
        return Int((hours * 60).rounded())
    }

    var hasProjectSignals: Bool {
        screenMinutes != nil || health != nil
    }
}

struct DayMetrics: Codable, Hashable {
    var mood: Double?
    var energy: Double?
    var focus: Double?
    var output: Double?
    var overall: Double?
}

struct Stage: Codable, Hashable {
    var label: String
    var color: String
}

struct EntryOverride: Codable, Hashable {
    var overview: String
    var mood: Int
    var energy: Int
    var focus: Int
    var output: Int
    var category: String?
    var tags: [String]?
    var updatedAt: Date
    var preservesMetrics: Bool? = nil
    var writtenMood: Int? = nil
}

struct QuickCapture: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var createdAt: Date
    var source: String = "菜单栏快记"
    var isPinned: Bool?
    var tag: String?

    var pinned: Bool { isPinned ?? false }

    static func sortedForDisplay(_ captures: [QuickCapture]) -> [QuickCapture] {
        captures.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.createdAt < $1.createdAt
        }
    }
}

struct UserState: Codable {
    var version = 3
    var entries: [String: EntryOverride] = [:]
    var quickCaptures: [String: [QuickCapture]]?
    var dismissedDrafts: [String: Date]?
    var careAcknowledgments: [String: Date]?
    var autoDraftPaused: Bool?
    var draftPausedUntil: Date?
    var monthlyLetters: [String: MonthlyLetter]?
    var savedQueries: [SavedQuery]? = nil
    var timelineAnnotations: [String: TimelineAnnotation]? = nil
}

struct SavedQuery: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var query: String
    var days: Int
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastUsedAt: Date?

    var rangeLabel: String { "近 \(days) 天" }
}

struct DraftEvidence: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var source: String
}

struct AIDraft: Hashable {
    var headline: String
    var narrative: String
    var category: String
    var tags: [String]
    var mood: Int
    var energy: Int
    var focus: Int
    var output: Int
    var confidence: Int
    var confidenceFactors: [String]
    var evidence: [DraftEvidence]
    var signals: [String]
    var care: CareLevel
    var isEmpty: Bool
}

enum CareLevel: String, Hashable {
    case none
    case gentle
    case support
}

struct ScreenAppUsage: Codable, Hashable {
    var app: String
    var time: String?
    var minutes: Int?

    enum CodingKeys: String, CodingKey {
        case app, time
        case minutes = "min"
    }
}

struct BrowseSiteUsage: Codable, Hashable {
    var site: String
    var count: String?
    var views: Int?

    enum CodingKeys: String, CodingKey {
        case site, count
        case views = "n"
    }

    var visits: Int? {
        if let views { return views }
        guard let count else { return nil }
        return Int(count)
    }
}

struct DidItem: Codable, Hashable {
    var subtitle: String?
    var items: [String]?
    var category: String?

    enum CodingKeys: String, CodingKey {
        case subtitle = "sub"
        case items
        case category = "cat"
    }
}

struct IOSHealthSummary: Codable, Hashable {
    var steps: Int?
    var distanceKM: Double?
    var activeEnergyKcal: Double?
    var sleepHours: Double?
    var sleepMinutes: Int?
    var bedAt: String?
    var wakeAt: String?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case steps, sleepHours = "sleep_hours"
        case sleepMinutes = "sleep_minutes"
        case bedAt = "bed_time"
        case wakeAt = "wake_time"
        case distanceKM = "distance_km"
        case activeEnergyKcal = "active_energy_kcal"
        case updatedAt = "updated_at"
    }

    var resolvedSleepHours: Double? {
        if let sleepHours { return sleepHours }
        if let sleepMinutes { return Double(sleepMinutes) / 60 }
        return nil
    }
}

struct SleepSignal: Identifiable, Hashable {
    var id: String { text }
    var text: String
    var source: String
}

extension DiaryEntry {
    var hasMovementSignal: Bool {
        health?.steps != nil || health?.distanceKM != nil || health?.activeEnergyKcal != nil
    }

    var hasStructuredSleepSignal: Bool {
        health?.resolvedSleepHours != nil || health?.bedAt != nil || health?.wakeAt != nil
    }

    var sleepSignals: [SleepSignal] {
        var candidates: [(String, String)] = []
        if let overview, !overview.isEmpty { candidates.append((overview, "当天总览")) }
        for text in thoughts ?? [] where !text.isEmpty { candidates.append((text, "想法片段")) }
        for text in memos ?? [] where !text.isEmpty { candidates.append((text, "随笔/备忘录")) }

        let keywords = ["睡眠", "睡觉", "失眠", "熬夜", "入睡", "早睡", "晚睡", "睡了", "没睡", "清醒", "犯困", "困"]
        return candidates.compactMap { text, source in
            let lines = text.components(separatedBy: .newlines)
            guard let match = lines.first(where: { line in keywords.contains(where: line.contains) }) else { return nil }
            let clipped = match.trimmingCharacters(in: .whitespacesAndNewlines)
            return clipped.isEmpty ? nil : SleepSignal(text: clipped, source: source)
        }
    }
}
