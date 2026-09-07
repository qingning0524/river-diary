import Foundation

// MARK: - Models

struct ActivitySession: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var appName: String
    var bundleID: String
    var windowTitle: String?
    var category: String
    var start: Date
    var end: Date

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var hour: Int { Calendar.current.component(.hour, from: start) }
    var dayKey: String { Self.dayKey(for: start) }

    static func dayKey(for date: Date) -> String {
        DiaryEntry.dateFormatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, appName = "app", bundleID = "bundle", windowTitle = "title", category, start, end
    }
}

enum ActivitySourceKind: String, Hashable {
    case pipeline
    case live
    case fused

    var label: String {
        switch self {
        case .pipeline: "项目管道"
        case .live: "macOS 实时"
        case .fused: "双源一致"
        }
    }
}

struct UsageItem: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var duration: TimeInterval
    var count: Int
    var category: String
    var source: ActivitySourceKind = .pipeline

    var timeText: String { ActivityFormatter.time(duration) }
}

struct BrowseUsageItem: Identifiable, Hashable {
    var id: String { site }
    var site: String
    var visits: Int
    var days: Int
}

struct ActivityHour: Identifiable {
    var id: Int { hour }
    var hour: Int
    var duration: TimeInterval
    var primaryCategory: String
}

struct FusedDayStats: Identifiable {
    var id: String { dateKey }
    var dateKey: String
    var pipelineAvailable: Bool
    var pipelineTotal: TimeInterval
    var liveTotal: TimeInterval
    var focusTotal: TimeInterval
    var appUsage: [UsageItem]
    var categoryUsage: [UsageItem]
    var browseUsage: [BrowseUsageItem]
    var timeline: [ActivityHour]
    var liveSessions: [ActivitySession]
    var focusSessions: [ActivitySession]
    var longestSession: ActivitySession?
    var health: IOSHealthSummary?
    var conflicts: [String]
    var fragmentation: Int
    var confidence: Int
    var confidenceFactors: [ActivityConfidenceFactor]
    var headline: String
    var narrative: String
}

struct FusedRangeStats {
    var days: Int
    var dateKeys: [String]
    var pipelineTotal: TimeInterval
    var liveTotal: TimeInterval
    var focusTotal: TimeInterval
    var appUsage: [UsageItem]
    var categoryUsage: [UsageItem]
    var browseUsage: [BrowseUsageItem]
    var timeline: [ActivityHour]
    var liveSessions: [ActivitySession]
    var focusSessions: [ActivitySession]
    var healthSteps: Int
    var healthDistance: Double
    var healthEnergy: Double
    var conflicts: [String]
    var fragmentation: Int
    var confidence: Int
    var confidenceFactors: [ActivityConfidenceFactor]
    var headline: String
    var narrative: String
    var dayStats: [FusedDayStats]
}


struct ActivityAnswer {
    var summary: String
    var filters: [String]
    var sessions: [ActivitySession]
}
