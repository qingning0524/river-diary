import Foundation

/// Builds the first usable V2 projection from the event-driven collector.
/// IDs are anchored to the first source session so repeated imports replace the
/// same derived row instead of multiplying records.
@MainActor
enum ActivityV2Projection {
    /// Writes the day's activities and episodes into the V2 fact layer.
    /// Returns false when any insert failed (the store's `lastError` says why);
    /// callers surface that instead of letting the write vanish silently.
    @discardableResult
    static func rebuildDay(_ sessions: [ActivitySession], into store: V2Store) -> Bool {
        let sorted = sessions.sorted { $0.start < $1.start }
        var succeeded = true
        for session in sorted {
            let activity = Activity(
                id: session.id,
                startTime: session.start,
                endTime: session.end,
                groupKey: ActivityClassifier.identity(appName: session.appName, bundleID: session.bundleID),
                primaryApp: session.appName,
                category: activityCategory(session.category),
                evidenceIDs: [session.id]
            )
            if !store.insertActivity(activity) { succeeded = false }
        }

        var groups: [[ActivitySession]] = []
        for session in sorted {
            if let index = groups.indices.last,
               let previous = groups[index].last,
               previous.category == session.category,
               previous.appName == session.appName,
               session.start.timeIntervalSince(previous.end) <= 120,
               session.end.timeIntervalSince(groups[index][0].start) <= 45 * 60 {
                groups[index].append(session)
            } else {
                groups.append([session])
            }
        }

        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let title = group.count == 1 ? first.appName : "\(first.appName) · \(group.count) 个片段"
            let summary = group.compactMap(\.windowTitle).first ?? "连续使用 \(ActivityFormatter.time(group.reduce(0) { $0 + $1.duration }))"
            let episode = Episode(
                id: first.id,
                startTime: first.start,
                endTime: last.end,
                title: title,
                summary: summary,
                category: episodeCategory(first.category),
                confidence: first.windowTitle?.isEmpty == false ? 85 : 65,
                confidenceFactors: [ConfidenceFactor(name: "实时应用片段", value: 1)],
                activityIDs: group.map(\.id),
                evidenceIDs: group.map(\.id)
            )
            if !store.insertEpisode(episode) { succeeded = false }
        }
        return succeeded
    }

    private static func activityCategory(_ value: String) -> ActivityCategory {
        switch value {
        case "工作", "学习", "创作": .focused
        case "沟通": .communication
        case "浏览": .exploring
        case "系统": .admin
        case "娱乐": .leisure
        default: .other
        }
    }

    private static func episodeCategory(_ value: String) -> EpisodeCategory {
        switch value {
        case "工作", "创作": .work
        case "学习": .study
        case "沟通": .communication
        case "系统": .admin
        case "娱乐": .leisure
        case "生活": .personal
        default: .other
        }
    }
}
