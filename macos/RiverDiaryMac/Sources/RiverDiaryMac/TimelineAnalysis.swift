import Foundation

enum TimelineInsightKind: String, Hashable {
    case observation
    case userNote
    case needsReview

    var label: String {
        switch self {
        case .observation: "观察"
        case .userNote: "我写的"
        case .needsReview: "待解释"
        }
    }
}

/// A compact, linkable statement derived from the complete, un-folded timeline.
struct TimelineAnalysisInsight: Identifiable, Hashable {
    let item: ActivityTimelineItem
    let kind: TimelineInsightKind
    let title: String
    let detail: String

    var id: String { "\(kind.rawValue):\(item.id)" }
    var itemID: String { item.id }
    var timeRange: String {
        if item.kind == .capture {
            return item.start.formatted(date: .omitted, time: .shortened)
        }
        return ActivityFormatter.timeRange(item.start, item.end)
    }
    var duration: TimeInterval { item.duration }

    var evidenceReferences: [String] {
        switch item.kind {
        case .activity:
            return item.sessions.map { "raw:\($0.id.uuidString)" }
        case .capture:
            return item.capture.map { ["capture:\($0.id.uuidString)"] } ?? []
        case .gap:
            return []
        }
    }
}

/// One deterministic, local analysis view over a day's normalized evidence.
/// It never writes facts back to the source store.
struct TimelineAnalysisSnapshot {
    let timeline: ActivityTimeline
    let stats: FusedDayStats
    let appUsage: [TimelineAppUsage]
    let categoryUsage: [TimelineAppUsage]
    let timeBuckets: [TimelineTimeBucket]
    let insights: [TimelineAnalysisInsight]

    var dayDuration: TimeInterval { timeline.dayInterval.duration }
    var recordedDuration: TimeInterval { timeline.totalDuration }
    var unrecordedDuration: TimeInterval { max(0, dayDuration - recordedDuration) }
    var sourceConflicts: [String] { stats.conflicts }

    static func make(
        timeline: ActivityTimeline,
        stats: FusedDayStats,
        calendar: Calendar = .current,
        insightLimit: Int = 3
    ) -> TimelineAnalysisSnapshot {
        let appUsage = aggregate(timeline.sessions, key: \.appName)
        let categoryUsage = aggregate(timeline.sessions, key: \.category)
        let timeBuckets = splitByTimeOfDay(timeline.sessions, calendar: calendar)
        let insights = makeInsights(
            timeline.items,
            reservedSessionID: stats.longestSession?.id,
            limit: insightLimit
        )
        return TimelineAnalysisSnapshot(
            timeline: timeline,
            stats: stats,
            appUsage: appUsage,
            categoryUsage: categoryUsage,
            timeBuckets: timeBuckets,
            insights: insights
        )
    }

    private static func aggregate(
        _ sessions: [ActivitySession],
        key: (ActivitySession) -> String
    ) -> [TimelineAppUsage] {
        let groups = Dictionary(grouping: sessions, by: key)
        return groups.map { name, values in
            TimelineAppUsage(
                name: name,
                duration: values.reduce(0) { $0 + $1.duration }
            )
        }
        .sorted { lhs, rhs in
            lhs.duration == rhs.duration ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : lhs.duration > rhs.duration
        }
    }

    private static func splitByTimeOfDay(
        _ sessions: [ActivitySession],
        calendar: Calendar
    ) -> [TimelineTimeBucket] {
        let ranges: [(title: String, lower: Int, upper: Int)] = [
            ("凌晨", 0, 5), ("上午", 5, 12), ("下午", 12, 18), ("晚上", 18, 24)
        ]
        var totals = Dictionary(uniqueKeysWithValues: ranges.map { ($0.title, 0.0) })

        for session in sessions {
            var cursor = session.start
            while cursor < session.end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor), hour.end > cursor else { break }
                let end = min(session.end, hour.end)
                let hourOfDay = calendar.component(.hour, from: cursor)
                if let range = ranges.first(where: { $0.lower <= hourOfDay && hourOfDay < $0.upper }) {
                    totals[range.title, default: 0] += end.timeIntervalSince(cursor)
                }
                cursor = end
            }
        }

        return ranges.compactMap { range in
            let duration = totals[range.title, default: 0]
            guard duration > 0 else { return nil }
            return TimelineTimeBucket(title: range.title, duration: duration)
        }
    }

    private static func makeInsights(
        _ items: [ActivityTimelineItem],
        reservedSessionID: UUID?,
        limit: Int
    ) -> [TimelineAnalysisInsight] {
        guard limit > 0 else { return [] }
        let candidates = items.filter { $0.kind != .gap }

        let userNotes = candidates.filter { item in
            item.kind == .capture || hasUserDescription(item.annotation)
        }
        .sorted { $0.start < $1.start }
        .map(userNoteInsight)

        let userNoteIDs = Set(userNotes.map(\.itemID))
        let reviewItems = candidates.filter { $0.needsReview && !userNoteIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.reviewSpan == rhs.reviewSpan ? lhs.start < rhs.start : lhs.reviewSpan > rhs.reviewSpan
            }
            .prefix(1)
            .map(reviewInsight)

        let alreadyShown = userNoteIDs.union(reviewItems.map(\.itemID))
        let observations = candidates
            .filter { item in
                item.kind == .activity
                    && item.duration > 0
                    && !alreadyShown.contains(item.id)
                    && !(reservedSessionID.map { id in item.sessions.contains(where: { $0.id == id }) } ?? false)
            }
            .sorted { lhs, rhs in
                lhs.duration == rhs.duration ? lhs.start < rhs.start : lhs.duration > rhs.duration
            }
            .map(observationInsight)

        return Array((userNotes + reviewItems + observations).prefix(limit))
    }

    private static func hasUserDescription(_ annotation: TimelineAnnotation?) -> Bool {
        guard let annotation = annotation?.normalized else { return false }
        return !annotation.title.isEmpty
            || !annotation.note.isEmpty
            || !annotation.placeName.isEmpty
            || !annotation.activityLabel.isEmpty
    }

    private static func userNoteInsight(_ item: ActivityTimelineItem) -> TimelineAnalysisInsight {
        if let capture = item.capture {
            let tag = capture.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return TimelineAnalysisInsight(
                item: item,
                kind: .userNote,
                title: capture.text,
                detail: tag.isEmpty ? "手动快记" : tag
            )
        }

        let annotation = item.annotation?.normalized
        let title = [annotation?.title, annotation?.activityLabel, annotation?.placeName, annotation?.note]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? item.title
        let detail = [annotation?.note, annotation?.placeName, annotation?.activityLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != title }
            .joined(separator: " · ")
        return TimelineAnalysisInsight(
            item: item,
            kind: .userNote,
            title: title,
            detail: detail.isEmpty ? item.evidenceLine : detail
        )
    }

    private static func reviewInsight(_ item: ActivityTimelineItem) -> TimelineAnalysisInsight {
        let appNames = item.apps.prefix(2).map(\.name).joined(separator: "、")
        let detail = [appNames.isEmpty ? nil : appNames, item.needsReviewReason]
            .compactMap { $0 }
            .joined(separator: " · ")
        return TimelineAnalysisInsight(
            item: item,
            kind: .needsReview,
            title: "这段活动还没有说明",
            detail: detail
        )
    }

    private static func observationInsight(_ item: ActivityTimelineItem) -> TimelineAnalysisInsight {
        let title = item.narrativeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = ActivityFormatter.time(item.duration)
        let evidence = item.evidenceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [duration, evidence.isEmpty || evidence == title ? nil : evidence]
            .compactMap { $0 }
            .joined(separator: " · ")
        return TimelineAnalysisInsight(
            item: item,
            kind: .observation,
            title: title.isEmpty ? "应用活动" : title,
            detail: detail
        )
    }
}

struct TimelineTimeBucket: Identifiable, Hashable {
    let title: String
    let duration: TimeInterval
    var id: String { title }
}
