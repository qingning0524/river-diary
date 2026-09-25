import Foundation

/// A presentation model derived from recorded evidence; it never changes source sessions.
struct ActivityTimelineItem: Identifiable, Hashable {
    enum Kind: String { case activity, capture, gap }

    var id: String
    var kind: Kind
    var start: Date
    var end: Date
    var sessions: [ActivitySession] = []
    var capture: QuickCapture?
    var annotationKey: String?
    var annotation: TimelineAnnotation?

    var isFavorite: Bool { annotation?.isFavorite == true }

    /// 什么才值得请你确认：产品决策（2026-09-25）——一两分钟的切屏碎片
    /// 不构成确认请求。快速切换时窗口标题本来就读不到，这类碎片注定
    /// 没有标题；它们仍完整保留在时间线与证据库里，只是不再打扰你。
    /// 只有达到 3 分钟的未知时间才进入待确认队列。
    static let reviewMaterialityThreshold: TimeInterval = 180

    /// 参与确认排序/阈值判断的时长：空档没有 duration，用跨度。
    var reviewSpan: TimeInterval {
        max(duration, end.timeIntervalSince(start))
    }

    /// 为什么这条节点待确认：够分量（≥3 分钟）且缺少窗口标题的活动片段。
    /// 空档不进队列——睡眠、离开电脑是生活常态，日复盘已有"不按零计算"
    /// 的留白陈述，每天请人确认睡眠是把免责声明变成作业。
    /// 三个展示位（时间线筛选、今日队列、控制台队列）共用这一个判定。
    var needsReviewReason: String? {
        guard annotation?.isReviewed != true else { return nil }
        guard kind != .gap else { return nil }
        guard reviewSpan >= Self.reviewMaterialityThreshold else { return nil }
        if sessions.contains(where: {
            ($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) { return "缺少窗口标题" }
        return nil
    }

    var needsReview: Bool { needsReviewReason != nil }

    var duration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var category: String { capture != nil ? "快记" : sessions.first?.category ?? "未记录" }
    var apps: [TimelineAppUsage] {
        Dictionary(grouping: sessions, by: \.appName)
            .map { TimelineAppUsage(name: $0.key, duration: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.duration == $1.duration ? $0.name < $1.name : $0.duration > $1.duration }
    }
    var title: String {
        if let title = annotation?.normalized.title, !title.isEmpty { return title }
        if let capture { return capture.text }
        if kind == .gap { return "没有记录的时间" }
        let names = apps.prefix(2).map(\.name).joined(separator: "、")
        return "\(names) · \(category)"
    }
    var summary: String {
        if let capture { return capture.tag ?? "留给这一天的一句话" }
        if kind == .gap { return "这段时间没有实时足迹" }
        let titles = sessions.compactMap(\.windowTitle).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let title = titles.first { return title }
        return apps.map(\.name).joined(separator: " · ") + " · \(sessions.count) 个原始片段"
    }
    var narrativeTitle: String {
        if let title = annotation?.normalized.title, !title.isEmpty { return title }
        if kind != .activity { return title }
        if let title = sessions.compactMap(\.windowTitle).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return title
        }
        return "使用 " + apps.prefix(2).map(\.name).joined(separator: "、")
    }
    func matches(query: String, category: String?) -> Bool {
        if let category, self.category != category { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let text = ([title, summary, self.category, annotation?.note ?? ""] + sessions.map { $0.appName + " " + ($0.windowTitle ?? "") }).joined(separator: " ")
        return text.localizedStandardContains(needle)
    }
}

struct ActivityTimeline {
    var date: Date
    var sessions: [ActivitySession]
    var items: [ActivityTimelineItem]
    /// Notes assigned to this diary day but written on another day have no known event time.
    var retrospectiveCaptures: [QuickCapture]

    var totalDuration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var focusDuration: TimeInterval {
        sessions.filter { ActivityClassifier.isFocus($0.category) }.reduce(0) { $0 + $1.duration }
    }
    var categories: [String] { Array(Set(items.filter { $0.kind != .gap }.map(\.category))).sorted() }
    var categoryUsage: [TimelineAppUsage] {
        let groups = Dictionary(grouping: sessions, by: \.category)
        let usage = groups.map { name, sessions in
            TimelineAppUsage(name: name, duration: sessions.reduce(0.0) { $0 + $1.duration })
        }
        return usage.sorted { $0.duration == $1.duration ? $0.name < $1.name : $0.duration > $1.duration }
    }
}

enum ActivityTimelineEngine {
    static func build(
        for date: Date, sessions: [ActivitySession], captures: [QuickCapture] = [],
        grouped: Bool = true, calendar: Calendar = .current,
        annotations: [String: TimelineAnnotation] = [:]
    ) -> ActivityTimeline {
        guard let day = calendar.dateInterval(of: .day, for: date) else {
            return ActivityTimeline(date: date, sessions: [], items: [], retrospectiveCaptures: captures)
        }
        let normalized = normalizedSessions(sessions, in: day)
        var blocks: [ActivityTimelineItem] = []
        for session in normalized {
            let annotationKey = TimelineAnnotation.key(for: session)
            if grouped, let last = blocks.last,
               annotations[annotationKey]?.isEmpty != false,
               last.category == session.category,
               session.start.timeIntervalSince(last.end) <= 120,
               session.end.timeIntervalSince(last.start) <= 45 * 60 {
                blocks[blocks.count - 1].sessions.append(session)
                blocks[blocks.count - 1].end = session.end
            } else {
                blocks.append(ActivityTimelineItem(
                    id: "activity-\(session.id)-\(session.start.timeIntervalSince1970)",
                    kind: .activity, start: session.start, end: session.end, sessions: [session],
                    annotationKey: annotationKey, annotation: annotations[annotationKey]
                ))
            }
        }
        var items = blocks
        for pair in zip(blocks, blocks.dropFirst()) where pair.1.start.timeIntervalSince(pair.0.end) >= 5 * 60 {
            items.append(ActivityTimelineItem(
                id: "gap-\(pair.0.id)", kind: .gap, start: pair.0.end, end: pair.1.start
            ))
        }
        let sameDay = captures.filter { day.start <= $0.createdAt && $0.createdAt < day.end }
        for capture in sameDay {
            items.append(ActivityTimelineItem(
                id: "capture-\(capture.id)", kind: .capture,
                start: capture.createdAt, end: capture.createdAt, capture: capture
            ))
        }
        items.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return ActivityTimeline(
            date: date, sessions: normalized, items: items,
            retrospectiveCaptures: captures.filter { !sameDay.contains($0) }.sorted { $0.createdAt < $1.createdAt }
        )
    }

    /// Day clipping also handles DST and midnight. Overlapping imports cannot inflate screen time.
    static func normalizedSessions(_ sessions: [ActivitySession], in day: DateInterval) -> [ActivitySession] {
        let sorted = sessions.filter {
            ActivityClassifier.isRecordable(appName: $0.appName, bundleID: $0.bundleID)
                && $0.end > $0.start && $0.start < day.end && $0.end > day.start
        }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        var result: [ActivitySession] = []
        var coveredUntil = day.start
        for var session in sorted {
            session.start = max(day.start, session.start, coveredUntil)
            session.end = min(day.end, session.end)
            guard session.end > session.start else { continue }
            result.append(session)
            coveredUntil = session.end
        }
        return result
    }
}

enum ActivityTimelineExport {
    static func markdown(_ timeline: ActivityTimeline) -> String {
        var lines = [
            "# 河流时间线 · \(timeline.date.formatted(.dateTime.year().month().day()))", "",
            "已记录 \(ActivityFormatter.time(timeline.totalDuration)) · 专注类应用 \(ActivityFormatter.time(timeline.focusDuration))", "",
            "依据本机应用片段与快记整理；空档表示未记录。", ""
        ]
        for item in timeline.items {
            let clock = item.start.formatted(date: .omitted, time: .shortened)
            if item.kind == .capture {
                lines += ["## \(clock) · 快记", "", item.capture?.text ?? "", ""]
            } else {
                lines += ["## \(ActivityFormatter.timeRange(item.start, item.end)) · \(item.title)", ""]
                if item.kind == .activity {
                    lines += ["记录时长：\(ActivityFormatter.time(item.duration))", ""]
                    if item.isFavorite { lines += ["★ 已收藏", ""] }
                    if let note = item.annotation?.note, !note.isEmpty { lines += ["### 我的补充", "", note, "", "### 原始依据", ""] }
                    for session in item.sessions {
                        let title = session.windowTitle.map { " · " + $0 } ?? ""
                        lines.append("- \(session.start.formatted(date: .omitted, time: .shortened)) \(session.appName) · \(ActivityFormatter.time(session.duration))\(title)")
                    }
                    lines.append("")
                }
            }
        }
        if !timeline.retrospectiveCaptures.isEmpty {
            lines += ["## 为这一天补记", "", "以下记录写于其他日期，未指定当天的发生时间。", ""]
            for capture in timeline.retrospectiveCaptures {
                lines += ["- \(capture.text)（补记于 \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))）", ""]
            }
        }
        return lines.joined(separator: "\n")
    }
}
