import Foundation

struct DiaryData: Codable {
    var generated: String
    var today: String
    var poem: String
    var entries: [DiaryEntry]
    var dataQuality: DataQuality?

    enum CodingKeys: String, CodingKey {
        case generated, today, poem, entries
        case dataQuality = "data_quality"
    }
}

struct DataQuality: Codable, Hashable {
    var status: String
    var criticalCount: Int?
    var warningCount: Int?
    var issues: DataQualityIssues?

    enum CodingKeys: String, CodingKey {
        case status
        case criticalCount = "critical_count"
        case warningCount = "warning_count"
        case issues
    }
}

struct DataQualityIssues: Codable, Hashable {
    var missingScores: [String]?
    var missingOverview: [String]?
    var missingPlan: [String]?
    var invalidStage: [String]?

    enum CodingKeys: String, CodingKey {
        case missingScores = "missing_scores"
        case missingOverview = "missing_overview"
        case missingPlan = "missing_plan"
        case invalidStage = "invalid_stage"
    }
}

struct DiaryEntry: Codable, Identifiable, Hashable {
    var pageID: String
    var date: String
    var score: Double?
    var daily: String?
    var title: String?
    var tags: [String]?
    var status: String?
    var views: Int?
    var screenHours: Double?
    var mood: String?
    var overview: String?
    var thoughts: [String]?
    var activities: [ActivityGroup]?
    var screenApps: [AppUsage]?
    var browseSites: [SiteUsage]?
    var screenNote: String?
    var browseNote: String?
    var plan: String?
    var workBuddy: String?
    var memos: [String]?
    var metrics: DayMetrics?
    var stage: Stage?
    var health: HealthData?

    var id: String { pageID }

    var displayTitle: String {
        title?.isEmpty == false ? title! : shortDate + " 使用日志"
    }

    var entryDate: Date {
        Self.dateFormatter.date(from: date) ?? Date()
    }

    var shortDate: String {
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(Int(parts[1]) ?? 1)月\(Int(parts[2]) ?? 1)日"
    }

    var stageLabel: String {
        stage?.label ?? "平稳"
    }

    var stageColorHex: String {
        stage?.color ?? "#D4A017"
    }

    var hasJournal: Bool {
        !(overview ?? "").isEmpty || !(thoughts ?? []).isEmpty || !(memos ?? []).isEmpty
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
        case date, score, daily, title, tags, status, views, mood, overview, thoughts, plan, metrics, stage
        case screenHours = "screen_h"
        case activities = "did"
        case screenApps = "screen_apps"
        case browseSites = "browse_sites"
        case screenNote = "screen_note"
        case browseNote = "browse_note"
        case workBuddy = "workbuddy"
        case health = "ios_health"
        case memos
    }
}

struct HealthData: Codable, Hashable {
    var sleepHours: Double?
    var steps: Double?
    var distanceKilometers: Double?
    var activeEnergyKilocalories: Double?
    var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case sleepHours = "sleep_hours"
        case steps
        case distanceKilometers = "distance_km"
        case activeEnergyKilocalories = "active_energy_kcal"
        case updatedAt = "updated_at"
    }
}

struct ActivityGroup: Codable, Hashable, Identifiable {
    var subtitle: String
    var items: [String]
    var category: String?

    var id: String { subtitle }

    enum CodingKeys: String, CodingKey {
        case subtitle = "sub"
        case items, category
    }
}

struct AppUsage: Codable, Hashable, Identifiable {
    var app: String
    var time: String?
    var minutes: Int?

    var id: String { app }
    var resolvedMinutes: Int { minutes ?? 0 }

    enum CodingKeys: String, CodingKey {
        case app, time
        case minutes = "min"
    }
}

struct SiteUsage: Codable, Hashable, Identifiable {
    var site: String
    var count: Int

    var id: String { site }

    init(site: String, count: Int) {
        self.site = site
        self.count = count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        site = try container.decode(String.self, forKey: .site)

        if let count = try? container.decode(Int.self, forKey: .n) {
            self.count = count
        } else if let count = try? container.decode(Int.self, forKey: .count) {
            self.count = count
        } else if let countText = try? container.decode(String.self, forKey: .count) {
            self.count = Scanner(string: countText).scanInt() ?? 0
        } else {
            self.count = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(site, forKey: .site)
        try container.encode(count, forKey: .count)
    }

    enum CodingKeys: String, CodingKey {
        case site, count, n
    }
}

struct DayMetrics: Codable, Hashable {
    var mood: Double?
    var energy: Double?
    var focus: Double?
    var output: Double?
    var overall: Double?
    var balance: Int?
    var healthBoost: Double?
    var growth: Double?
    var growthStage: GrowthStage?
    var basis: MetricBasis?

    enum CodingKeys: String, CodingKey {
        case mood, energy, focus, output, overall, balance, growth, basis
        case healthBoost = "health_boost"
        case growthStage = "growth_stage"
    }
}

struct GrowthStage: Codable, Hashable {
    var label: String
    var color: String
}

struct MetricBasis: Codable, Hashable {
    var energy: String?
    var focus: String?
    var output: String?
    var growth: String?
}

struct Stage: Codable, Hashable {
    var label: String
    var color: String
}
