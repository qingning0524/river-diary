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
    var originDeviceID: String? = nil
    var evidenceQuality: String? = nil
    var endReason: String? = nil

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var hour: Int { Calendar.current.component(.hour, from: start) }
    var dayKey: String { Self.dayKey(for: start) }

    static func dayKey(for date: Date) -> String {
        DiaryEntry.dateFormatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case id, appName = "app", bundleID = "bundle", windowTitle = "title", category, start, end
        case originDeviceID, evidenceQuality, endReason
    }

    /// 在同一应用里换了窗口标题：在 `moment` 处切开，返回（截断到此刻的旧段，带新标题的新段）。
    ///
    /// 切点一定落在这段里面：时钟回拨、睡眠唤醒、辅助功能读回来的时刻都可能越界，
    /// 而越界的切点会造出一段负时长的记录——那比"没有标题"严重得多。
    /// 类别也按新标题重算：同一个应用里的文档和视频不是一个东西。
    func split(at moment: Date, now: Date, windowTitle: String) -> (closed: ActivitySession, next: ActivitySession) {
        let boundary = min(max(moment, start), max(now, start))
        var closed = self
        closed.end = boundary

        var next = self
        next.id = UUID()
        next.start = boundary
        next.end = max(now, boundary)
        next.windowTitle = windowTitle
        next.category = ActivityClassifier.category(appName: appName, title: windowTitle)
        return (closed, next)
    }
}

enum ActivitySessionSnapshot {
    static func day(
        _ date: Date, sessions: [ActivitySession], active: ActivitySession?,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [ActivitySession] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        var candidates = sessions
        if var active {
            active.end = max(active.end, now)
            candidates.append(active)
        }
        return candidates.compactMap { session -> ActivitySession? in
            guard ActivityClassifier.isRecordable(appName: session.appName, bundleID: session.bundleID),
                  session.start < day.end, session.end > day.start else { return nil }
            var clipped = session
            clipped.start = max(session.start, day.start)
            clipped.end = min(session.end, day.end)
            return clipped.end > clipped.start ? clipped : nil
        }.sorted { $0.start < $1.start }
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

