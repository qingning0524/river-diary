import AppKit
import SwiftUI

/// The evidence timeline: one spine, one grid, two lines per row.
///
/// Rows carry no vertical padding of their own — the padding lives inside each
/// column — so that the spine drawn by every row meets the next row's spine and
/// the day reads as one continuous line instead of a dashed series of dots.
///
/// 每一行只说两件事：**什么时候**、**发生了什么**（加它站在哪条证据上）。
/// 第三行（来源）曾经单独占一行，实际只是把同一件事说了两遍，现在并进第二行。
struct RiverTimelineView: View {
    @Environment(\.riverDensity) private var density
    let items: [ActivityTimelineItem]
    let nowSession: ActivitySession?
    let selectedItemID: String?
    let onSelect: (ActivityTimelineItem, String) -> Void
    let onWriteNote: () -> Void
    @FocusState.Binding var inspectorSourceFocusID: String?
    var focusScope = "timeline"
    var isScrollable: Bool = true
    /// Materialize all rows temporarily when an off-screen insight is being
    /// revealed. Normal browsing stays lazy.
    var materializeAllRows: Bool = false
    /// 已经展开的碎片带 id。默认空集：嵌入场景（工作 · 学习预览）不展开。
    var expandedRunIDs: Set<String> = []
    var onToggleRun: (ActivityTimelineItem) -> Void = { _ in }

    var body: some View {
        // `riverScrollIndicators()` 会插入一层 `.background(NativeScrollbarSuppressor())`
        // 用来关掉祖先 NSScrollView 的原生滚动条。非滚动分支（被外层 ScrollView
        // 托管的嵌入场景，以及像素级渲染测试）自己没有滚动容器，套上去只会多出
        // 一层寄生背景并改变布局，因此只在真正的滚动分支上应用。
        Group {
            if isScrollable {
                ScrollView { timelineContent }
                    .riverScrollIndicators()
            } else {
                timelineContent
            }
        }
    }

    /// 展示行：折叠后的节点列表，加上已展开的碎片带成员。
    ///
    /// 脊柱的起止（`isFirst` / `isLast`）按**摊平后**的顺序算：展开一条碎片带
    /// 会在它后面插入若干子行，那条碎片带自己就不再是最后一行，它的下半截脊柱
    /// 必须继续画下去，否则展开处会出现一个空洞。
    private var displayRows: [TimelineDisplayList.Row] {
        TimelineDisplayList.rows(
            items: items,
            expandedRunIDs: expandedRunIDs,
            hasNowRow: nowSession != nil
        )
    }

    @ViewBuilder
    private var timelineContent: some View {
        Group {
            if materializeAllRows {
                VStack(alignment: .leading, spacing: 0) { timelineRows }
            } else {
                // Normal browsing stays lazy; only a deliberate jump from an
                // insight expands the whole list long enough to materialize its target.
                LazyVStack(alignment: .leading, spacing: 0) { timelineRows }
            }
        }
        .padding(.bottom, density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var timelineRows: some View {
        if items.isEmpty && nowSession == nil {
            EmptyStateView(
                title: "这一天还没有记录。",
                message: "使用身边的应用后，带来源的事实会在这里出现。",
                symbol: "clock"
            )
            .padding(.vertical, density.spacing(AppSpacing.lg))
        } else {
            ForEach(displayRows) { row in
                let focusID = "\(focusScope):\(row.item.id)"
                TimelineRow(
                    item: row.item,
                    isSelected: selectedItemID == row.item.id,
                    isChild: row.isChild,
                    isFirst: row.isFirst,
                    isLast: row.isLast,
                    isExpandedRun: row.isExpandedRun,
                    focusID: focusID,
                    inspectorSourceFocusID: $inspectorSourceFocusID,
                    onSelect: {
                        inspectorSourceFocusID = focusID
                        onSelect(row.item, focusID)
                    },
                    onToggleRun: { onToggleRun(row.item) },
                    onWriteNote: onWriteNote
                )
                .id(row.id)
            }
        }
        if let nowSession {
            TimelineNowRow(session: nowSession)
        }
    }
}

// MARK: - Display list

/// 时间线列表的展示行：折叠后的节点，加上已展开的碎片带成员。
///
/// 单独抽出来是因为有两处要用它：`RiverTimelineView` 渲染它，页面把
/// "时间带拖到了哪里"翻译成"哪一行"也用它。两份实现迟早会漂移。
enum TimelineDisplayList {
    /// A quick-capture marker is only three points wide on the ribbon. Give its
    /// visible tick a small temporal hit area so it remains selectable.
    static let captureHitTolerance: TimeInterval = 6 * 60

    struct Row: Identifiable {
        let item: ActivityTimelineItem
        var isChild = false
        var isFirst = false
        var isLast = false
        var isExpandedRun = false
        var id: String { isChild ? "fragment-\(item.id)" : item.id }
    }

    static func rows(
        items: [ActivityTimelineItem],
        expandedRunIDs: Set<String>,
        hasNowRow: Bool
    ) -> [Row] {
        var rows: [Row] = []
        for (index, item) in items.enumerated() {
            let isLastItem = index == items.count - 1
            let expanded = !item.fragments.isEmpty && expandedRunIDs.contains(item.id)
            rows.append(
                Row(
                    item: item,
                    isFirst: index == 0,
                    isLast: isLastItem && !hasNowRow && !expanded,
                    isExpandedRun: expanded
                )
            )
            guard expanded else { continue }
            for (childIndex, child) in item.fragments.enumerated() {
                rows.append(
                    Row(
                        item: child,
                        isChild: true,
                        isLast: childIndex == item.fragments.count - 1 && isLastItem && !hasNowRow
                    )
                )
            }
        }
        return rows
    }

    /// 时间带拖到某一刻要做什么：滚到哪一行，以及要不要先展开一条碎片带。
    struct ScrubTarget: Equatable {
        let rowID: String
        let item: ActivityTimelineItem
        /// 落在折叠的碎片带上时先展开它，再定位实际成员。
        var expandsRunID: String?
    }

    /// 只把时间带定位到实际覆盖这一刻的证据。未被记录的时刻不会跳到邻近行，
    /// 以免把空白误读成已观察到的活动。
    static func scrubTarget(for moment: Date, rows: [Row]) -> ScrubTarget? {
        let captureRows = rows.filter { $0.item.kind == .capture }
        if let capture = captureRows.min(by: {
            abs($0.item.start.timeIntervalSince(moment)) < abs($1.item.start.timeIntervalSince(moment))
        }), abs(capture.item.start.timeIntervalSince(moment)) <= captureHitTolerance {
            return ScrubTarget(rowID: capture.id, item: capture.item, expandsRunID: nil)
        }
        let covering = rows.filter { row in
            if row.item.kind == .capture { return false }
            return row.item.start <= moment && moment < row.item.end
        }
        guard let row = covering.min(by: { $0.item.span < $1.item.span }) else { return nil }
        if !row.isChild, row.item.isFragmentRun,
           let fragment = row.item.fragments.first(where: { $0.start <= moment && moment < $0.end }) {
            return ScrubTarget(
                rowID: "fragment-\(fragment.id)",
                item: fragment,
                expandsRunID: row.item.id
            )
        }
        if row.item.isFragmentRun { return nil }
        return ScrubTarget(rowID: row.id, item: row.item, expandsRunID: nil)
    }
}

// MARK: - Row metrics
//
// Every column is a fixed width so rows line up across the whole timeline,
// regardless of how long a title or a duration happens to be.

enum TimelineRowMetrics {
    /// Start and end time, stacked, plus the gap before the spine. The gap is part
    /// of this width on purpose: a separate `.padding(.trailing:)` would widen the
    /// column and push the rendered node off the spine drawn behind it.
    static let timeColumn: CGFloat = 54
    /// The spine and its node.
    static let spineColumn: CGFloat = 26
    /// Duration, read as a right-aligned column of comparable magnitudes.
    static let durationColumn: CGFloat = 78
    /// The trailing affordance column: the row's own chevron. Reserved on every
    /// row so the duration column ends at the same x on all of them, whether the
    /// row is tappable-through or folds a 碎片带.
    static let controlColumn: CGFloat = 22
    /// Where the row's first text line starts, so the node can align with it.
    static let topInset: CGFloat = 13
    /// 子行文本相对父行的缩进。脊柱不缩进——一天只有一根线。
    static let childIndent: CGFloat = 12
}

private struct TimelineRow: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let item: ActivityTimelineItem
    let isSelected: Bool
    /// 碎片带展开后的一条成员。比父行小一档，缩进，脊柱虚线。
    let isChild: Bool
    let isFirst: Bool
    let isLast: Bool
    let isExpandedRun: Bool
    let focusID: String
    @FocusState.Binding var inspectorSourceFocusID: String?
    let onSelect: () -> Void
    let onToggleRun: () -> Void
    let onWriteNote: () -> Void

    @State private var isHovered = false

    private var isGap: Bool { item.kind == .gap }
    private var isRun: Bool { item.isFragmentRun && !isChild }
    private var isDashedSpine: Bool { isGap || isRun || isChild }

    /// Gaps have no sessions, so their length is the span itself.
    private var span: TimeInterval {
        isRun ? item.span : max(item.duration, item.end.timeIntervalSince(item.start))
    }

    /// 只有带来信息的类别才占一枚胶囊。日常的"工作 / 浏览 / 娱乐"每行都挂一枚，
    /// 除了把列表搅乱没有别的作用——节点颜色、筛选条、统计都已经说过这件事。
    private static let labelledCategories: Set<String> = ["系统", "快记"]

    private var displayTitle: String {
        if let custom = item.annotation?.normalized.title, !custom.isEmpty { return custom }
        if let capture = item.capture { return capture.text }
        if isGap { return "没有记录的时间" }
        if item.isFragmentRun { return item.title }
        let names = item.apps.prefix(2).map(\.name).joined(separator: "、")
        return names.isEmpty ? item.category : names
    }

    /// 第二行：证据 + 来源，标题已经说过的部分不再重复。
    ///
    /// 曾经这里是两行：一行引擎摘要（"Chrome · 3 个原始片段"），一行来源（带一个
    /// 拐弯箭头）。两行说的是同一件事，还把行高撑到 3 行文字。现在只有一行，
    /// 而且原始片段计数（仪表的内部数字）退到检查器和右键菜单里。
    private var detailLine: String {
        var parts: [String] = []
        // 碎片带：整体跨度已经在右侧时长列里，这里说清"这一段切换是什么形态"。
        // 切屏是中性的：说得出形态（在谁与谁之间来回 / 都在同应用里）就说形态，
        // 说不出再报应用构成。成员行没有形态，直接报应用名。
        func appendComposition() {
            let composition = item.appComposition
            if composition.isEmpty {
                let names = item.apps.prefix(3).map(\.name)
                if !names.isEmpty {
                    parts.append(names.joined(separator: "、") + (item.apps.count > 3 ? " 等" : ""))
                }
            } else {
                parts.append(composition)
            }
        }
        if isRun {
            if let phrase = FragmentRunShape.classify(item).phrase {
                parts.append(phrase)
            } else {
                appendComposition()
            }
        } else if isChild {
            appendComposition()
        } else {
            parts.append(item.evidenceLine.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let source = sourceLabel { parts.append(source) }
        let title = displayTitle
        return parts
            .filter { !$0.isEmpty && !title.localizedStandardContains($0) }
            .joined(separator: " · ")
    }

    /// 这一行站在哪条证据上。空串表示没有额外来源可说。
    private var sourceLabel: String? {
        if let place = item.annotation?.normalized.placeName, !place.isEmpty { return "地点 · \(place)" }
        if let activity = item.annotation?.normalized.activityLabel, !activity.isEmpty { return "活动 · \(activity)" }
        if isGap {
            // 设计规范要求"未知数据绝不显示为 0"。同样是灰色空档，
            // "这段时间没有采集到任何前台片段"和"有片段但被记录规则排除"
            // 是两件事：前者是真的没数据，后者是数据存在却没进统计。
            return item.sessions.isEmpty ? nil : "有片段未纳入统计"
        }
        if item.kind == .capture || isRun || isChild { return nil }
        // 活动：应用名。标题已经写了应用名时会被去重掉。
        let names = item.apps.prefix(2).map(\.name)
        return names.isEmpty ? nil : names.joined(separator: "、")
    }

    private var nodeColor: Color {
        if isGap { return AppTheme.neutral }
        if item.kind == .capture { return Color.ink.opacity(0.55) }
        return AppTheme.categoryTint(item.category)
    }

    /// 悬停是中性水洗，选中是 accent 淡底 + 左侧实色条。
    /// 两档必须一眼分得开：只差透明度的话，鼠标扫过和点下去长得一样。
    private var rowFill: Color {
        if isSelected { return AppTheme.accentSoft }
        if isHovered { return Color.ink.opacity(0.05) }
        return .clear
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 0) {
                    timeColumn
                    nodeColumn
                    content
                    durationColumn
                }
                .padding(.horizontal, density.spacing(AppSpacing.sm))
                .background(alignment: .topLeading) { spineBackground }
                .background(rowFill, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
                .overlay(alignment: .leading) { selectionRule }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($inspectorSourceFocusID, equals: focusID)
            .onKeyPress(.return) { onSelect(); return .handled }
            .onKeyPress(.space) { onSelect(); return .handled }
            .contextMenu { contextMenu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)

            trailingControl
        }
        .onHover { hover in isHovered = hover }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.standard), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isExpandedRun)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button(isSelected ? "收起详情" : "查看详情", action: onSelect)
        if isRun {
            Button(isExpandedRun ? "收起碎片" : "展开 \(item.fragments.count) 段碎片", action: onToggleRun)
        }
        if isGap {
            Button("写一句快记", action: onWriteNote)
        }
        if !item.summary.isEmpty {
            Button("复制证据摘要") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.summary, forType: .string)
            }
        }
        // 证据锚点：这一行的原始记录引用。AI 结论里的依据引用的就是同一个
        // 命名空间，复制出来即可与结论里的 `<!-- evidence: … -->` 对上。
        if let ref = item.evidenceRef {
            Button("复制证据引用") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ref, forType: .string)
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.kind == .capture ? "快记" : (isGap ? "空档" : "活动")]
        parts.append(ActivityFormatter.timeRange(item.start, item.end))
        parts.append(displayTitle)
        if isRun { parts.append("\(item.fragments.count) 段碎片，\(isExpandedRun ? "已展开" : "已折叠")") }
        if span > 0 { parts.append("持续 \(ActivityFormatter.time(span))") }
        if !detailLine.isEmpty { parts.append(detailLine) }
        if item.needsReview { parts.append("待确认") }
        return parts.joined(separator: "，")
    }

    // MARK: Columns

    private var timeColumn: some View {
        VStack(alignment: .trailing, spacing: density.spacing(1)) {
            Text(item.start.formatted(date: .omitted, time: .shortened))
                .font(AppTypography.numeric())
                .foregroundStyle(isGap ? Color.tertiaryInk : Color.ink)
            if span > 0 {
                Text(item.end.formatted(date: .omitted, time: .shortened))
                    .font(AppTypography.metadata().monospacedDigit())
                    .foregroundStyle(Color.tertiaryInk)
            }
        }
        .frame(width: TimelineRowMetrics.timeColumn, alignment: .trailing)
        .padding(.top, density.spacing(TimelineRowMetrics.topInset))
    }

    /// The node sits in the row's column grid; the line behind it comes from
    /// `spineLine`, so a row only has to draw its own dot.
    private var nodeColumn: some View {
        node
            .frame(width: TimelineRowMetrics.spineColumn)
            .background {
                if isSelected {
                    Circle()
                        .fill(AppTheme.accent.opacity(0.14))
                        .frame(width: 25, height: 25)
                        .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.55), lineWidth: 1))
                }
            }
            .padding(.top, density.spacing(TimelineRowMetrics.topInset) - 1)
    }

    /// The connector, behind the node so the dot always stays readable.
    ///
    /// It repeats the row's own column grid instead of offsetting by a computed x:
    /// the line is centred inside the same spine column that centres the node, so the
    /// two cannot drift apart when a column width changes. Because it is a
    /// background it also takes the row's measured height, which is what makes the
    /// segments meet across rows. Trimmed at the first and last row so the series
    /// has two clear ends.
    private var spineBackground: some View {
        let nodeGap = density.spacing(TimelineRowMetrics.topInset) + 4
        return HStack(spacing: 0) {
            Color.clear.frame(width: TimelineRowMetrics.timeColumn)
            VStack(spacing: 0) {
                spineSegment(height: nodeGap, draws: !isFirst)
                spineSegment(height: nil, draws: !isLast)
            }
            .frame(width: TimelineRowMetrics.spineColumn)
            Color.clear.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func spineSegment(height: CGFloat?, draws: Bool) -> some View {
        VerticalSpine()
            .stroke(
                draws ? spineLineColor : .clear,
                style: StrokeStyle(
                    lineWidth: Self.spineWidth,
                    lineCap: .butt,
                    dash: isDashedSpine ? Self.spineDash : []
                )
            )
            .frame(width: Self.spineWidth)
            .frame(height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
    }

    private static let spineWidth: CGFloat = 1.5
    private static let spineDash: [CGFloat] = [2.5, 3.5]

    /// 脊柱的颜色与虚实分三档：有记录是 accent 实线；碎片带与它的成员是 accent
    /// 虚线（同一条线，只是"这一截由很多小段拼起来"）；空档是中性虚线。
    ///
    /// 旧值 `accent@0.30` 在浅色下只有 1.37:1 —— 设计文档写着"连续脊柱"，
    /// 像素里其实什么都没有。现在用 `Color.timelineSpine`：浅色最低一套配色
    /// 也有 2.2:1，读得出来，又明显轻于实心节点。
    private var spineLineColor: Color {
        isGap ? Color.strongSeparator : Color.timelineSpine
    }

    @ViewBuilder
    private var node: some View {
        if isGap {
            Circle()
                .fill(Color.surface)
                .frame(width: 19, height: 19)
                .overlay(Circle().strokeBorder(AppTheme.neutral.opacity(0.6), lineWidth: 1.2))
        } else if isChild {
            // 展开后的一条成员：更小、更淡，但仍然是"有记录"的实心点。
            Circle()
                .fill(Color.timelineSpine)
                .frame(width: 8, height: 8)
        } else if isRun {
            // 碎片带的双点表示多段收在一起；外环沿用整条时间线的标记尺寸。
            Circle()
                .fill(Color.surface)
                .frame(width: 19, height: 19)
                .overlay(Circle().strokeBorder(Color.timelineSpine, lineWidth: 1.3))
                .overlay {
                    HStack(spacing: 2) {
                        Circle().fill(AppTheme.accent).frame(width: 4, height: 4)
                        Circle().fill(AppTheme.accent).frame(width: 4, height: 4)
                    }
                }
        } else if item.kind == .capture {
            RoundedRectangle(cornerRadius: AppRadius.marker, style: .continuous)
                .fill(Color.surface)
                .frame(width: 18, height: 18)
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.marker, style: .continuous)
                        .strokeBorder(AppTheme.warning.opacity(0.75), lineWidth: 1.2)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.warning)
                        .frame(width: 7, height: 7)
                }
        } else {
            Circle()
                .fill(Color.surface)
                .frame(width: 19, height: 19)
                .overlay(Circle().strokeBorder(Color.timelineSpine, lineWidth: 1.2))
                .overlay(Circle().fill(nodeColor).frame(width: 10, height: 10))
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                Text(displayTitle)
                    .font(isChild ? AppTypography.secondary().weight(.medium) : AppTypography.rowTitle().weight(.semibold))
                    .foregroundStyle(isGap ? Color.secondaryInk : Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !isGap, Self.labelledCategories.contains(item.category) {
                    categoryChip
                }
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.warning)
                        .accessibilityLabel("已收藏")
                }
                if item.needsReview {
                    StatusBadge("待确认", tone: .attention)
                }
                Spacer(minLength: 0)
            }

            if !detailLine.isEmpty {
                Text(detailLine)
                    .font(isChild ? AppTypography.metadata() : AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(isChild ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, density.spacing(TimelineRowMetrics.topInset))
        .padding(.bottom, density.spacing(isChild ? AppSpacing.xs : AppSpacing.sm))
        .padding(.leading, isChild ? density.spacing(TimelineRowMetrics.childIndent) : 0)
        .padding(.trailing, density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryChip: some View {
        Text(item.category)
            .font(AppTypography.micro().weight(.medium))
            .foregroundStyle(AppTheme.categoryTint(item.category))
            .padding(.horizontal, density.spacing(6))
            .padding(.vertical, density.spacing(1))
            .background(Color.chip, in: Capsule())
            .fixedSize()
    }

    private var durationColumn: some View {
        Text(span > 0 ? ActivityFormatter.time(span) : "")
            .font(AppTypography.numeric())
            .foregroundStyle(isGap ? Color.tertiaryInk : Color.secondaryInk)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: TimelineRowMetrics.durationColumn, alignment: .trailing)
            .padding(.top, density.spacing(TimelineRowMetrics.topInset))
    }

    /// 行的尾列。碎片带在这里放常显的展开箭头（它是个容器，折叠状态必须看得见）；
    /// 普通行放"打开详情"的箭头，只在鼠标扫过或选中时出现——每一行都常亮一个
    /// 箭头是纯噪音，行本身已经可以点。
    @ViewBuilder
    private var trailingControl: some View {
        if isRun {
            Button(action: onToggleRun) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondaryInk)
                    .rotationEffect(.degrees(isExpandedRun ? 0 : -90))
                    .frame(width: TimelineRowMetrics.controlColumn, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpandedRun ? "收起 \(item.fragments.count) 段碎片" : "展开 \(item.fragments.count) 段碎片")
            .accessibilityLabel(isExpandedRun ? "收起碎片" : "展开碎片")
            .padding(.top, density.spacing(TimelineRowMetrics.topInset) - 3)
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tertiaryInk)
                .frame(width: TimelineRowMetrics.controlColumn, height: 22)
                .opacity(isHovered || isSelected ? 1 : 0)
                .padding(.top, density.spacing(TimelineRowMetrics.topInset) - 3)
                .accessibilityHidden(true)
        }
    }

    private var selectionRule: some View {
        Capsule()
            .fill(isSelected ? AppTheme.accent : .clear)
            .frame(width: 2.5)
            .padding(.vertical, density.spacing(AppSpacing.md))
            .padding(.leading, density.spacing(1))
    }
}

/// 一条竖线。`Rectangle` 描不出虚线，`stroke` 也只能描外框，所以这里有一个只
/// 画中轴线的形状，虚线由 `StrokeStyle` 的 dash 控制。
private struct VerticalSpine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - Now row

private struct TimelineNowRow: View {
    @Environment(\.riverDensity) private var density
    let session: ActivitySession

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: density.spacing(1)) {
                Text("现在")
                    .font(AppTypography.numeric().weight(.bold))
                    .foregroundStyle(AppTheme.accent)
                Text(session.start.formatted(date: .omitted, time: .shortened))
                    .font(AppTypography.metadata().monospacedDigit())
                    .foregroundStyle(Color.tertiaryInk)
            }
            .frame(width: TimelineRowMetrics.timeColumn, alignment: .trailing)
            .padding(.top, density.spacing(TimelineRowMetrics.topInset))

            // 双环：静态的"正在记录"，不是一直呼吸的灯。
            // 一个 1.1 秒一圈、永不停止的脉冲在列表底部持续重绘，除了耗电
            // 和把视线钉在边上没有别的作用。
            Circle()
                .fill(AppTheme.accent)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.25), lineWidth: 3))
                .frame(width: TimelineRowMetrics.spineColumn)
                .padding(.top, density.spacing(TimelineRowMetrics.topInset) - 1.5)

            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Text(session.appName)
                        .font(AppTypography.rowTitle().weight(.semibold))
                        .foregroundStyle(Color.ink)
                    StatusBadge("正在记录", tone: .positive)
                    Spacer(minLength: 0)
                }
                if let title = session.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                        .lineLimit(1)
                }
                Text("已持续 \(ActivityFormatter.time(Date().timeIntervalSince(session.start)))")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
            }
            .padding(.top, density.spacing(TimelineRowMetrics.topInset))
            .padding(.bottom, density.spacing(AppSpacing.sm))
            .padding(.trailing, density.spacing(AppSpacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: TimelineRowMetrics.controlColumn, height: 1)
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .background(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: TimelineRowMetrics.timeColumn)
                VerticalSpine()
                    .stroke(
                        Color.timelineSpine,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .butt)
                    )
                    .frame(width: 1.5)
                    .frame(height: density.spacing(TimelineRowMetrics.topInset) + 4)
                    .frame(width: TimelineRowMetrics.spineColumn)
                Color.clear.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, density.spacing(AppSpacing.sm))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在记录，\(session.appName)，已持续 \(ActivityFormatter.time(Date().timeIntervalSince(session.start)))")
    }
}
