import AppKit
import SwiftUI

/// The evidence timeline: time, observation and source stay in fixed columns so
/// the eye can scan one column at a time.
///
/// Rows carry no vertical padding of their own — the padding lives inside each
/// column — so that the spine drawn by every row meets the next row's spine and
/// the day reads as one continuous line instead of a dashed series of dots.
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

    var body: some View {
        Group {
            if isScrollable {
                ScrollView { timelineContent }
            } else {
                timelineContent
            }
        }
        .riverScrollIndicators()
    }

    @ViewBuilder
    private var timelineContent: some View {
        // 懒加载：一天可能有数百个融合节点，非懒容器会把整天的行一次性物化。
        LazyVStack(alignment: .leading, spacing: 0) {
            if items.isEmpty && nowSession == nil {
                EmptyStateView(
                    title: "这一天还没有记录。",
                    message: "使用身边的应用后，带来源的事实会在这里出现。",
                    symbol: "clock"
                )
                .padding(.vertical, density.spacing(AppSpacing.lg))
            } else {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let focusID = "\(focusScope):\(item.id)"
                    TimelineRow(
                        item: item,
                        isSelected: selectedItemID == item.id,
                        isFirst: index == 0,
                        isLast: index == items.count - 1 && nowSession == nil,
                        focusID: focusID,
                        inspectorSourceFocusID: $inspectorSourceFocusID,
                        onSelect: {
                            inspectorSourceFocusID = focusID
                            onSelect(item, focusID)
                        }
                    )
                    .id(item.id)
                }
            }

            if let nowSession {
                TimelineNowRow(session: nowSession)
            }
        }
        .padding(.bottom, density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Where the row's first text line starts, so the node can align with it.
    static let topInset: CGFloat = 13
}

private struct TimelineRow: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let item: ActivityTimelineItem
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    let focusID: String
    @FocusState.Binding var inspectorSourceFocusID: String?
    let onSelect: () -> Void

    @State private var isHovered = false

    private var isGap: Bool { item.kind == .gap }

    /// Gaps have no sessions, so their length is the span itself.
    private var span: TimeInterval {
        max(item.duration, item.end.timeIntervalSince(item.start))
    }

    private var displayTitle: String {
        if let custom = item.annotation?.normalized.title, !custom.isEmpty { return custom }
        if let capture = item.capture { return capture.text }
        if isGap { return "没有记录的时间" }
        return item.apps.prefix(2).map(\.name).joined(separator: "、")
    }

    private var summaryText: String {
        // The title already names the apps, so drop the engine's "app · " prefix.
        var text = item.summary
        for app in item.apps {
            let prefix = "\(app.name) · "
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        }
        return text
    }

    private var sourceLabel: String {
        if let place = item.annotation?.normalized.placeName, !place.isEmpty { return "地点 · \(place)" }
        if let activity = item.annotation?.normalized.activityLabel, !activity.isEmpty { return "活动 · \(activity)" }
        if item.kind == .capture { return "手动记录" }
        if isGap { return "原始时间空档" }
        if item.sessions.count == 1 { return item.sessions[0].appName }
        return "\(item.sessions.count) 个原始片段"
    }

    private var needsReview: Bool {
        guard item.annotation?.isReviewed != true else { return false }
        return isGap || item.sessions.contains {
            ($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var nodeColor: Color {
        if isGap { return AppTheme.neutral }
        if item.kind == .capture { return Color.ink.opacity(0.55) }
        return AppTheme.categoryTint(item.category)
    }

    private var rowFill: Color {
        if isSelected { return reduceTransparency ? AppTheme.accentSoft : Color.ink.opacity(0.055) }
        if isHovered { return reduceTransparency ? Color.chip : Color.ink.opacity(0.025) }
        return .clear
    }

    var body: some View {
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
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: 2.5)
                        .padding(.vertical, density.spacing(AppSpacing.md))
                        .padding(.leading, density.spacing(1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($inspectorSourceFocusID, equals: focusID)
        .onKeyPress(.return) { onSelect(); return .handled }
        .onKeyPress(.space) { onSelect(); return .handled }
        .onHover { hover in isHovered = hover }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.standard), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .contextMenu {
            Button(isSelected ? "收起详情" : "查看详情", action: onSelect)
            if !item.summary.isEmpty {
                Button("复制证据摘要") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.summary, forType: .string)
                }
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.kind == .capture ? "快记" : (isGap ? "空档" : "活动")]
        parts.append(ActivityFormatter.timeRange(item.start, item.end))
        parts.append(displayTitle)
        if span > 0 { parts.append("持续 \(ActivityFormatter.time(span))") }
        parts.append("来源 \(sourceLabel)")
        if needsReview { parts.append("待确认") }
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
                Rectangle()
                    .fill(isFirst ? Color.clear : spineLineColor)
                    .frame(height: nodeGap)
                Rectangle()
                    .fill(isLast ? Color.clear : spineLineColor)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 1.5)
            .frame(width: TimelineRowMetrics.spineColumn)
            Color.clear.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var spineLineColor: Color {
        isGap ? Color.separator : AppTheme.accent.opacity(0.3)
    }

    @ViewBuilder
    private var node: some View {
        if isGap {
            Circle()
                .fill(Color.surface)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(AppTheme.neutral.opacity(0.6), lineWidth: 1.2))
        } else if item.kind == .capture {
            RoundedRectangle(cornerRadius: AppRadius.marker, style: .continuous)
                .fill(nodeColor)
                .frame(width: 9, height: 9)
        } else {
            Circle()
                .fill(nodeColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.surface, lineWidth: 1.5))
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
            HStack(alignment: .firstTextBaseline, spacing: density.spacing(AppSpacing.sm)) {
                Text(displayTitle)
                    .font(AppTypography.rowTitle().weight(.semibold))
                    .foregroundStyle(isGap ? Color.secondaryInk : Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !isGap && item.kind != .capture {
                    categoryChip
                }
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.warning)
                        .accessibilityLabel("已收藏")
                }
                if needsReview {
                    StatusBadge("待确认", tone: .attention)
                }
                Spacer(minLength: 0)
            }

            Text(summaryText)
                .font(AppTypography.secondary())
                .foregroundStyle(Color.secondaryInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: density.spacing(AppSpacing.xs)) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.tertiaryInk)
                Text(sourceLabel)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
                    .lineLimit(1)
            }
            .padding(.top, density.spacing(AppSpacing.xxs))
        }
        .padding(.top, density.spacing(TimelineRowMetrics.topInset))
        .padding(.trailing, density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var categoryChip: some View {
        Text(item.category)
            .font(AppTypography.micro().weight(.medium))
            .foregroundStyle(AppTheme.categoryTint(item.category))
            .padding(.horizontal, density.spacing(6))
            .padding(.vertical, density.spacing(1))
            .background(AppTheme.categoryTint(item.category).opacity(0.12), in: Capsule())
            .fixedSize()
    }

    private var durationColumn: some View {
        HStack(spacing: density.spacing(6)) {
            if span > 0 {
                Text(ActivityFormatter.time(span))
                    .font(AppTypography.numeric())
                    .foregroundStyle(isGap ? Color.tertiaryInk : Color.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.tertiaryInk)
        }
        .frame(width: TimelineRowMetrics.durationColumn, alignment: .trailing)
        .padding(.top, density.spacing(TimelineRowMetrics.topInset))
    }
}

// MARK: - Now row

private struct TimelineNowRow: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let session: ActivitySession

    @State private var pulse = false

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

            Circle()
                .fill(AppTheme.accent)
                .frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(AppTheme.accent.opacity(0.25), lineWidth: 3))
                .scaleEffect(pulse ? 1.12 : 0.94)
                .frame(width: TimelineRowMetrics.spineColumn)
                .padding(.top, density.spacing(TimelineRowMetrics.topInset) - 1.5)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                }

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
                    .foregroundStyle(Color.tertiaryInk)
                    .padding(.top, density.spacing(AppSpacing.xxs))
            }
            .padding(.top, density.spacing(TimelineRowMetrics.topInset))
            .padding(.trailing, density.spacing(AppSpacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, density.spacing(AppSpacing.sm))
        .background(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: TimelineRowMetrics.timeColumn)
                Rectangle()
                    .fill(AppTheme.accent.opacity(0.3))
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
