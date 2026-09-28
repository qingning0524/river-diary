import Foundation
import RiverDiaryCore

struct ActivityTimelinePlaceMarker: Identifiable, Hashable {
    var id: UUID
    var time: Date
    var title: String
    var detail: String
    var originDeviceID: String
}

/// A presentation model derived from recorded evidence; it never changes source sessions.
struct ActivityTimelineItem: Identifiable, Hashable {
    enum Kind: String { case activity, capture, gap, place }

    var id: String
    var kind: Kind
    var start: Date
    var end: Date
    var sessions: [ActivitySession] = []
    var secondarySessions: [ActivitySession] = []
    var capture: QuickCapture?
    var placeMarker: ActivityTimelinePlaceMarker?
    var annotationKey: String?
    var annotation: TimelineAnnotation?

    var isFavorite: Bool { annotation?.isFavorite == true }

    /// 能不能人工整理这一条。**只有真实的活动块有标注键**：空档、快记和碎片带
    /// 都是派生出来的行，给它们写标注会存进一个永远读不回来的键——检查器上的
    /// "编辑"按下去没有任何反应，也不会报错。
    var isAnnotatable: Bool { annotationKey != nil }

    /// 一条节点单独占一行的分量。不到 3 分钟的切屏碎片不单独占一行，
    /// 而是折进它所在的那条"碎片带"（见 `ActivityTimelineEngine.foldFragments`）。
    static let fragmentFoldThreshold: TimeInterval = 180

    /// 什么才值得请你确认：产品决策（2026-09-26 修订）。
    ///
    /// 原判据是"≥3 分钟且缺少窗口标题"，前提是窗口标题会被采集。实测本机
    /// 2297 条片段里只有 1 条带标题（辅助功能未授权、且标题只在应用切换的瞬间读一次），
    /// 于是"缺少标题"退化成恒真，判据实际只剩"≥3 分钟"：中位每天 9 条待确认，
    /// 队列永远不空，正好违背这个功能立项时写下的那句话——"日常状态是空的"。
    ///
    /// 现在要求这条时间**长得足够难解释**（20 分钟，与证据控制台自己的说明
    /// "系统无法解释的二十分钟"同一口径），**并且确实没有可说明的证据**
    /// （没有窗口标题、没有人工标注）。有标题的长块自己讲得清楚，不进队列。
    static let reviewMaterialityThreshold: TimeInterval = 20 * 60

    /// 主导证据引用：指向这一行/这一段的原始记录，供 AI 结论引用后点回原处。
    /// 活动段用它第一条原始片段的 id（`raw:` 命名空间），快记用 `capture:`。
    /// 空档没有原始记录，因此为 nil——"没有数据"本身不是一个可引用的证据。
    /// 碎片带是聚合视图，展开后每个成员各自有引用，它自己没有。
    var evidenceRef: String? {
        switch kind {
        case .activity: isFragmentRun ? nil : sessions.first.map { "raw:\($0.id.uuidString)" }
        case .capture: capture.map { "capture:\($0.id.uuidString)" }
        case .gap: nil
        case .place: placeMarker.map { "raw:\($0.id.uuidString)" }
        }
    }

    /// 折叠后的碎片带成员：非空表示这一条是"碎片带"，而不是单个节点。
    ///
    /// 折叠只发生在展示层。`ActivityTimeline.items` 始终是逐条证据——导出、
    /// 搜索、证据控制台、日复盘都读那一份——只有时间线列表读 `foldedItems`。
    /// 这样"把一天读成十几行"不改变任何统计口径，也不会丢任何一条原始片段。
    var fragments: [ActivityTimelineItem] = []

    var isFragmentRun: Bool { !fragments.isEmpty }

    /// 这一条在时间轴上占的跨度。
    var span: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// 参与确认排序/阈值判断的时长：空档没有 duration，用跨度。
    var reviewSpan: TimeInterval {
        max(duration, span)
    }

    /// 这一条是否自带说明：窗口标题，或人工写下的标注。
    var hasDescribingEvidence: Bool {
        if let annotation = annotation?.normalized,
           !annotation.title.isEmpty || !annotation.note.isEmpty || !annotation.placeName.isEmpty || !annotation.activityLabel.isEmpty {
            return true
        }
        return sessions.contains {
            !($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 为什么这条节点待确认：一段够长、又没有任何东西能解释它的时间。
    ///
    /// 空档不进队列——睡眠、离开电脑是生活常态，日复盘已有"不按零计算"
    /// 的留白陈述，每天请人确认睡眠是把免责声明变成作业。
    /// 碎片带也不进：它的每一个成员都不到 3 分钟。
    /// 四个展示位（时间线筛选、今日队列、控制台队列、行内徽章）共用这一个判定。
    var needsReviewReason: String? {
        guard annotation?.isReviewed != true else { return nil }
        guard kind == .activity, !isFragmentRun else { return nil }
        guard reviewSpan >= Self.reviewMaterialityThreshold else { return nil }
        guard !hasDescribingEvidence else { return nil }
        return "\(Int(Self.reviewMaterialityThreshold / 60)) 分钟没有可说明的证据"
    }

    var needsReview: Bool { needsReviewReason != nil }

    var duration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var category: String {
        if capture != nil { return "快记" }
        if placeMarker != nil { return "地点" }
        return sessions.first?.category ?? "未记录"
    }
    var apps: [TimelineAppUsage] {
        Dictionary(grouping: sessions, by: \.appName)
            .map { TimelineAppUsage(name: $0.key, duration: $0.value.reduce(0) { $0 + $1.duration }) }
            .sorted { $0.duration == $1.duration ? $0.name < $1.name : $0.duration > $1.duration }
    }
    var title: String {
        if let title = annotation?.normalized.title, !title.isEmpty { return title }
        if let label = annotation?.normalized.activityLabel, !label.isEmpty { return label }
        if let place = annotation?.normalized.placeName, !place.isEmpty { return place }
        if isFragmentRun {
            // 形态决定名字：多数短切换是多工具组合工作，只有真散的才叫"碎片"。
            return FragmentRunShape.classify(self).rowTitle(fallbackCount: fragments.count)
        }
        if let placeMarker { return placeMarker.title }
        if let capture { return capture.text }
        if kind == .gap { return "没有记录的时间" }
        let names = apps.prefix(2).map(\.name).joined(separator: "、")
        return "\(names) · \(category)"
    }

    /// 行内第二行：这一条自己的证据。
    ///
    /// 窗口标题可用时就是标题；不可用时退回到**块内的应用构成**（谁、多久）与
    /// **覆盖质地**（跨度里有多少时间真的在前台），而不是原始片段计数——
    /// 计数是仪表的内部数字，不是发生过的事。真的没什么可说时返回空串：
    /// 证据薄的行本来就该薄，不该用一句话把三行填满。
    var evidenceLine: String {
        if let placeMarker { return placeMarker.detail }
        let note = annotation?.normalized.note ?? ""
        if !note.isEmpty { return note }

        if let capture {
            let tag = capture.tag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return tag.isEmpty ? "手动记录" : tag
        }
        if isFragmentRun {
            let spanText = "跨度 \(ActivityFormatter.time(span))"
            return appComposition.isEmpty ? spanText : "\(appComposition) · \(spanText)"
        }
        if kind == .gap { return "这段时间没有实时足迹" }
        if let windowTitle = sessions.compactMap(\.windowTitle).first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return windowTitle
        }
        // 跨度远大于实际前台时长：这段时间里有相当一部分没有前台记录，
        // 那本身就是这一条最该说的事。
        if span > 0, duration < span * 0.85 {
            return "跨度 \(ActivityFormatter.time(span)) · 实际前台 \(ActivityFormatter.time(duration))"
        }
        return appComposition
    }

    /// 块内的应用构成："Chrome 4 分 · ZCode 3 分"。
    ///
    /// 只有一个应用时返回空串——标题已经说了应用名，再说一遍就是注水。
    var appComposition: String {
        guard apps.count > 1 else { return "" }
        return apps.prefix(2)
            .map { "\($0.name) \(ActivityFormatter.time($0.duration))" }
            .joined(separator: " · ")
    }
    var summary: String {
        if let placeMarker { return placeMarker.detail }
        if let capture { return capture.tag ?? "留给这一天的一句话" }
        if kind == .gap { return "这段时间没有实时足迹" }
        let titles = sessions.compactMap(\.windowTitle).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let title = titles.first { return title }
        return apps.map(\.name).joined(separator: " · ") + " · \(sessions.count) 个原始片段"
    }
    var narrativeTitle: String {
        if let title = annotation?.normalized.title, !title.isEmpty { return title }
        if let label = annotation?.normalized.activityLabel, !label.isEmpty { return label }
        if let place = annotation?.normalized.placeName, !place.isEmpty { return place }
        if kind != .activity { return title }
        if let title = sessions.compactMap(\.windowTitle).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return title
        }
        return "使用 " + apps.prefix(2).map(\.name).joined(separator: "、")
    }
    func matches(query: String, category: String?) -> Bool {
        // 碎片带按成员匹配：筛选与搜索永远作用在真实节点上，不作用在聚合上。
        if isFragmentRun {
            return fragments.contains { $0.matches(query: query, category: category) }
        }
        if let category, self.category != category { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let markerText = placeMarker.map { $0.title + " " + $0.detail + " " + $0.originDeviceID } ?? ""
        let text = ([title, summary, self.category, annotation?.note ?? "", markerText] + sessions.map { $0.appName + " " + ($0.windowTitle ?? "") }).joined(separator: " ")
        return text.localizedStandardContains(needle)
    }
}

struct ActivityTimeline {
    var date: Date
    /// The actual local-day interval (23/24/25 hours where the calendar requires it).
    var dayInterval: DateInterval
    var sessions: [ActivitySession]
    /// 逐条证据：活动块、快记、空档。统计、导出、搜索、复盘都读这一份。
    var items: [ActivityTimelineItem]
    /// 展示列表：连续的微小节点被折成"碎片带"。
    /// 只给时间线列表用，见 `ActivityTimelineItem.fragments`。
    var foldedItems: [ActivityTimelineItem]
    /// Notes assigned to this diary day but written on another day have no known event time.
    var retrospectiveCaptures: [QuickCapture]

    var totalDuration: TimeInterval { sessions.reduce(0) { $0 + $1.duration } }
    var focusDuration: TimeInterval {
        sessions.filter { ActivityClassifier.isFocus($0.category) }.reduce(0) { $0 + $1.duration }
    }
    /// "节点"数：活动块 + 快记，不含空档，也不把一条碎片带算成一个。
    var recordedNodeCount: Int { items.filter { $0.kind != .gap }.count }
    /// 会被折进碎片带的节点数：页面用它解释"为什么行数比节点少"。
    var fragmentNodeCount: Int {
        items.filter(ActivityTimelineEngine.isFoldable).count
    }
    /// 最长的一段专注（工作/学习/创作）。比"日记已写"更值得占一个展示位。
    var longestFocusSpan: TimeInterval {
        items.filter { $0.kind == .activity && ActivityClassifier.isFocus($0.category) }
            .map(\.duration).max() ?? 0
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
        placeMarkers: [ActivityTimelinePlaceMarker] = [],
        grouped: Bool = true, calendar: Calendar = .current,
        annotations: [String: TimelineAnnotation] = [:]
    ) -> ActivityTimeline {
        guard let day = calendar.dateInterval(of: .day, for: date) else {
            return ActivityTimeline(
                date: date,
                dayInterval: DateInterval(start: date, end: date),
                sessions: [], items: [], foldedItems: [], retrospectiveCaptures: captures
            )
        }
        let normalized = normalizedSessions(sessions, in: day)
        let localID = RiverDeviceID(rawValue: "mac_local")
        let coreSessions = normalized.map { session in
            RiverAppSession(
                id: "session:\(session.id.uuidString.lowercased())",
                originDeviceID: session.originDeviceID.map { RiverDeviceID(rawValue: $0) } ?? localID,
                applicationIdentifier: session.bundleID,
                displayName: session.appName,
                start: session.start,
                end: session.end,
                endReason: RiverSessionEndReason(rawValue: session.endReason ?? "") ?? .observedSessionBoundary,
                quality: RiverSessionEvidenceQuality(rawValue: Int(session.evidenceQuality ?? "2") ?? 2) ?? .observed,
                evidenceEventIDs: [session.id]
            )
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id.uuidString.lowercased(), $0) })
        let fusedGroups = SessionFusionEngine.fuse(coreSessions)
        var blocks: [ActivityTimelineItem] = []
        for group in fusedGroups {
            guard let sessionID = UUID(uuidString: group.primary.id.replacingOccurrences(of: "session:", with: "")),
                  let session = sessionsByID[sessionID.uuidString.lowercased()] else { continue }
            let secondary = group.secondary.compactMap { secondary -> ActivitySession? in
                guard let id = UUID(uuidString: secondary.id.replacingOccurrences(of: "session:", with: "")) else { return nil }
                return sessionsByID[id.uuidString.lowercased()]
            }
            let annotationKey = TimelineAnnotation.key(for: session)
            if grouped, let last = blocks.last,
               annotations[annotationKey]?.isEmpty != false,
               last.category == session.category,
               session.start.timeIntervalSince(last.end) <= 120,
               session.end.timeIntervalSince(last.start) <= 45 * 60 {
                blocks[blocks.count - 1].sessions.append(session)
                blocks[blocks.count - 1].secondarySessions.append(contentsOf: secondary)
                let secondaryStart = secondary.map { $0.start }.min() ?? session.start
                let secondaryEnd = secondary.map { $0.end }.max() ?? session.end
                blocks[blocks.count - 1].start = min(blocks[blocks.count - 1].start, min(session.start, secondaryStart))
                blocks[blocks.count - 1].end = max(blocks[blocks.count - 1].end, max(session.end, secondaryEnd))
            } else {
                let secondaryStart = secondary.map { $0.start }.min() ?? session.start
                let secondaryEnd = secondary.map { $0.end }.max() ?? session.end
                let groupStart = min(session.start, secondaryStart)
                let groupEnd = max(session.end, secondaryEnd)
                blocks.append(ActivityTimelineItem(
                    id: "activity-\(session.id)-\(session.start.timeIntervalSince1970)",
                    kind: .activity, start: groupStart, end: groupEnd, sessions: [session], secondarySessions: secondary,
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
        for marker in placeMarkers where day.start <= marker.time && marker.time < day.end {
            items.append(ActivityTimelineItem(
                id: "place-\(marker.id.uuidString.lowercased())",
                kind: .place,
                start: marker.time,
                end: marker.time,
                placeMarker: marker
            ))
        }
        items.sort { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        return ActivityTimeline(
            date: date, dayInterval: day, sessions: normalized, items: items, foldedItems: foldFragments(items),
            retrospectiveCaptures: captures.filter { !sameDay.contains($0) }.sorted { $0.createdAt < $1.createdAt }
        )
    }

    // MARK: - 碎片带

    /// 一条碎片带最多覆盖的跨度。超过就另起一条——"碎片带"描述的是一段
    /// 来回切换的时间，一小时已经够长；这也让展开后的行数有上限。
    static let fragmentRunMaxSpan: TimeInterval = 60 * 60
    /// 一条碎片带最多容纳的节点数，同上。
    static let fragmentRunMaxCount = 24

    /// 可以折进碎片带的节点：跨度不到 3 分钟、没有人工标注。
    ///
    /// 用**跨度**而不是前台时长：一条 4 分钟里切了 7 次的记录，前台时长可能只有
    /// 70 秒，但它占用的仍是这 4 分钟的注意力，就是要折的那种churn。
    /// 反过来，一段实心的 4 分钟记录跨度也是 4 分钟，不会被折。
    ///
    /// 空档与快记会打断一条碎片带——它们本身就是有意义的边界：
    /// 快记是当天真正发生的事件，空档是"这段时间没有记录"的陈述，
    /// 把任何一个折进"碎片"都是把两种不同的事实混为一谈。
    static func isFoldable(_ item: ActivityTimelineItem) -> Bool {
        item.kind == .activity
            && !item.isFragmentRun
            && !item.isFavorite
            && item.span < ActivityTimelineItem.fragmentFoldThreshold
            && item.annotation?.isEmpty != false
    }

    /// 把连续的微小节点折成一条"碎片带"。
    ///
    /// 产品决策的另一半：不到 3 分钟的切屏不值得请你确认，那它也不该各自占一张卡。
    /// 实测中位一天有 72% 的节点短于 3 分钟（最忙的一天 285 行、约 24 屏），
    /// 折叠后同样的证据只要 1–3 屏，而且被折叠的每一段仍然可以展开逐条查看。
    ///
    /// 折叠是**展示层**的事：成员完整保留在 `items`、导出、搜索与证据库里，
    /// 只是列表默认不逐条铺开。
    static func foldFragments(_ items: [ActivityTimelineItem]) -> [ActivityTimelineItem] {
        var result: [ActivityTimelineItem] = []
        var pending: [ActivityTimelineItem] = []

        func flush() {
            defer { pending = [] }
            guard let first = pending.first, let last = pending.last else { return }
            guard pending.count > 1 else {
                result.append(first)
                return
            }
            result.append(ActivityTimelineItem(
                id: "fragments-\(first.id)-\(last.id)",
                kind: .activity,
                start: first.start,
                end: last.end,
                sessions: pending.flatMap(\.sessions),
                fragments: pending
            ))
        }

        for item in items {
            guard isFoldable(item) else {
                flush()
                result.append(item)
                continue
            }
            if let first = pending.first,
               item.end.timeIntervalSince(first.start) > fragmentRunMaxSpan || pending.count >= fragmentRunMaxCount {
                flush()
            }
            pending.append(item)
        }
        flush()
        return result
    }

    /// 把折叠后的展示列表摊平成逐条节点。筛选与搜索用它：
    /// 一个查询不该命中一条"碎片带"却看不见命中的是哪一段。
    static func flattenFragments(_ items: [ActivityTimelineItem]) -> [ActivityTimelineItem] {
        items.flatMap { $0.isFragmentRun ? $0.fragments : [$0] }
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

/// 一条碎片带的形态。**切屏是中性的**：多数短切换是多工具组合工作的常态，
/// 只有结构指向"没有主基地"时才换词。判定只用应用结构，不下结论——
/// "组合工作""短切换"是模式描述，"分心"这个词永远不该出现在这个文件里。
///
/// 阈值来自本机真实数据的分布（2026-09-26，17 天 / 2378 段 / 133 条带）：
/// 主导应用占比 p50 = 0.74、p25 = 0.58；「占比 ≥ 0.6 且回到主导应用 ≥ 2 次」
/// 捕获 40% 的带；「应用数 ≥ 3 且占比 < 0.4」的游移带为 **0** 条——这一档是
/// 留给未来数据的，当下默认沉默。改阈值前先重新跑一遍分布。
enum FragmentRunShape: Equatable {
    /// 同一个应用里的连续短会话：换窗口、换标签页。标题重采样（每 25 秒）
    /// 把长会话按标题切开之后，这会是最常见的形态。
    case intraApp(app: String, count: Int)
    /// 组合工作：反复回到主导应用（主基地），其余工具是短插针。
    case composedWork(dominant: String, second: String, returns: Int)
    /// 没有主基地：好几个应用，谁都不占多数。
    case wandering(appCount: Int)
    /// 其余：两次切换、均匀混用等，用中性的默认措辞，不硬编形态。
    case mixed

    static let composedMinMembers = 3
    static let composedShareThreshold = 0.6
    static let composedReturnsThreshold = 2
    static let wanderingAppThreshold = 3
    static let wanderingShareThreshold = 0.4

    var isComposedWork: Bool {
        if case .composedWork = self { return true }
        return false
    }

    var isWandering: Bool {
        if case .wandering = self { return true }
        return false
    }

    /// 行的第二行 / 检查器用的形态短语。`mixed` 返回 nil：没有可说的结构，
    /// 就退回应用构成，别硬编一句话。
    var phrase: String? {
        switch self {
        case .intraApp(let app, let count): "\(app) 里的 \(count) 段短切换"
        case .composedWork(let dominant, let second, let returns): "在 \(dominant) 与 \(second) 之间来回 \(returns) 次"
        case .wandering(let appCount): "分散在 \(appCount) 个应用之间"
        case .mixed: nil
        }
    }

    /// 行标题。组合工作与同应用切换值得一个具体的名字；真散的才叫"碎片"。
    func rowTitle(fallbackCount: Int) -> String {
        switch self {
        case .composedWork: "组合工作 · \(fallbackCount) 段"
        case .intraApp: phrase ?? "\(fallbackCount) 段碎片"
        case .wandering, .mixed: "\(fallbackCount) 段碎片"
        }
    }

    /// 只读结构，不读标注：形态是给"没有人工解释的切换"自动起名用的，
    /// 人工写过的标题在 `ActivityTimelineItem.title` 里本来就优先。
    static func classify(_ run: ActivityTimelineItem) -> FragmentRunShape {
        let members = run.fragments
        guard !members.isEmpty else { return .mixed }

        var durations: [String: TimeInterval] = [:]
        var bundles: [String: String] = [:]
        for member in members {
            for session in member.sessions {
                durations[session.appName, default: 0] += max(session.duration, 0)
                bundles[session.appName] = session.bundleID
            }
        }
        // 没有任何前台时长（理论上不该发生）就按段数计权，保证判定仍可进行。
        if durations.values.allSatisfy({ $0 <= 0 }) {
            for member in members {
                for session in member.sessions {
                    durations[session.appName, default: 0] += 1
                }
            }
        }

        // 同一个应用：换窗口/换标签，不是跨应用切换。
        if Set(bundles.values).count <= 1, let app = durations.keys.sorted().first {
            return .intraApp(app: app, count: members.count)
        }

        let ranked = durations.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let dominant = ranked.first?.key else { return .mixed }
        let total = durations.values.reduce(0, +)
        let share = total > 0 ? (ranked.first?.value ?? 0) / total : 0

        if ranked.count >= wanderingAppThreshold, share < wanderingShareThreshold {
            return .wandering(appCount: ranked.count)
        }

        // 主基地：主导应用在成员序列里反复出现，隔了别的工具再回来也算一次。
        var returns = 0
        var previousWasDominant = false
        for member in members {
            let isDominant = member.sessions.contains { $0.appName == dominant }
            if isDominant, !previousWasDominant { returns += 1 }
            previousWasDominant = isDominant
        }

        if members.count >= composedMinMembers,
           share >= composedShareThreshold,
           returns >= composedReturnsThreshold {
            let second = ranked.dropFirst().first?.key ?? dominant
            return .composedWork(dominant: dominant, second: second, returns: returns)
        }

        return .mixed
    }
}

enum ActivityTimelineExport {
    static func markdown(_ timeline: ActivityTimeline) -> String {
        // 隐私边界：这是唯一会带窗口标题的导出（目前没有 UI 入口，仅测试引用）。
        // 标题一旦存在，文件头部必须声明——分享这个文件的人应当知道里面有什么。
        let hasTitles = timeline.sessions.contains { !($0.windowTitle ?? "").isEmpty }
        var lines = [
            "# 河流时间线 · \(timeline.date.formatted(.dateTime.year().month().day()))", "",
            "已记录 \(ActivityFormatter.time(timeline.totalDuration)) · 专注类应用 \(ActivityFormatter.time(timeline.focusDuration))", "",
            hasTitles
                ? "依据本机应用片段与快记整理；空档表示未记录。**本文件包含窗口标题（敏感）**，分享前请检查。"
                : "依据本机应用片段与快记整理；空档表示未记录。",
            ""
        ]
        for item in timeline.items {
            let clock = item.start.formatted(date: .omitted, time: .shortened)
            if item.kind == .capture {
                lines += ["## \(clock) · 快记", "", item.capture?.text ?? "", ""]
            } else if let marker = item.placeMarker {
                lines += ["## \(clock) · \(marker.title)", "", marker.detail, ""]
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
