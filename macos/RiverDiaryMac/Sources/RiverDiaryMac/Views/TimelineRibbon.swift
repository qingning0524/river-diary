import SwiftUI

/// The whole day in one band.
///
/// A row list answers "what happened, in order". It cannot answer "where in the
/// day is the recorded evidence, and where are the holes" — that needs the day
/// laid out once. This band is that single glance: a fixed 00:00–24:00 axis so
/// days are comparable, recorded segments in the one accent, and empty space
/// where nothing was recorded. It is deliberately not a chart: no axis grid
/// drama, no per-category rainbow, no decoration.
///
/// 时间线页把它钉在页头当作定位尺用：悬停出现十字与时刻，拖动直接跳到那一刻
/// 所在的行（`onScrub`）。统计卡片里的那一份只读，不接手势。
struct RiverDayRibbon: View {
    @Environment(\.riverDensity) private var density
    let date: Date
    let items: [ActivityTimelineItem]
    /// Pass the current moment only when the ribbon shows today; draws a "now" tick.
    var now: Date?
    /// 拖动时间带：连续回调拖动到的时刻。为 nil 时整条带不接管手势。
    var onScrub: ((Date) -> Void)?
    /// 松手：这一次拖动最终落在的时刻。页面用它选中那一行。
    var onScrubCommit: ((Date) -> Void)?

    /// Height of the day band. Exposed so layout tests can address the track
    /// without duplicating the number.
    static let trackHeight: CGFloat = 42
    /// Height of the hour-label axis below the track. Fixed: see `hourAxis`.
    static let axisHeight: CGFloat = 14
    /// Hour ticks every six hours: enough to place yourself, not a grid.
    private static let ticks = [0, 6, 12, 18, 24]
    /// VoiceOver summary runs per render; don't allocate a formatter each time.
    private static let accessibilityTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 鼠标在带上的横向比例（0–1）。悬停与拖动共用一条十字线。
    @State private var hoverFraction: CGFloat?
    @State private var dragFraction: CGFloat?

    private var activeFraction: CGFloat? { dragFraction ?? hoverFraction }

    var body: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .fill(Color.editor)

                    hourGuides(width: proxy.size.width)

                    ForEach(segments(in: proxy.size.width), id: \.id) { segment in
                        RoundedRectangle(cornerRadius: AppRadius.marker, style: .continuous)
                            .fill(segment.fill)
                            .frame(width: segment.width, height: segment.height)
                            .offset(x: segment.x, y: segment.y)
                    }

                    if let nowX = nowOffset(in: proxy.size.width) {
                        nowMark(x: nowX)
                    }

                    if let fraction = activeFraction {
                        crosshair(fraction: fraction, width: proxy.size.width)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverFraction = clampFraction(location.x / max(proxy.size.width, 1))
                    case .ended:
                        hoverFraction = nil
                    }
                }
                .gesture(scrubGesture(width: proxy.size.width), isEnabled: onScrub != nil)
            }
            .frame(height: Self.trackHeight)
            .accessibilityElement()
            .accessibilityLabel("一天的时间带")
            .accessibilityValue(accessibilitySummary)

            hourAxis
        }
    }

    // MARK: Interaction

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = clampFraction(value.location.x / max(width, 1))
                dragFraction = fraction
                onScrub?(moment(at: fraction))
            }
            .onEnded { value in
                let fraction = clampFraction(value.location.x / max(width, 1))
                dragFraction = nil
                hoverFraction = fraction
                onScrubCommit?(moment(at: fraction))
            }
    }

    private func clampFraction(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    private func moment(at fraction: CGFloat) -> Date {
        Calendar.current.startOfDay(for: date).addingTimeInterval(TimeInterval(fraction) * 86_400)
    }

    /// 悬停/拖动时的十字：一条竖线加一个时刻。没有它，这条带只是一张图；
    /// 有了它，用户能读出"这一段是几点"。
    private func crosshair(fraction: CGFloat, width: CGFloat) -> some View {
        let x = width * fraction
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(dragFraction == nil ? Color.secondaryInk.opacity(0.45) : AppTheme.accent)
                .frame(width: dragFraction == nil ? 1 : 1.5, height: Self.trackHeight)
                .offset(x: min(max(x, 0), max(width - 1.5, 0)))

            Text(Self.accessibilityTimeFormatter.string(from: moment(at: fraction)))
                .font(AppTypography.micro().monospacedDigit().weight(.medium))
                .foregroundStyle(Color.ctaText)
                .padding(.horizontal, density.spacing(5))
                .padding(.vertical, density.spacing(2))
                .background(Color.ink.opacity(0.82), in: Capsule())
                .fixedSize()
                .offset(x: min(max(x - 22, 2), max(width - 46, 0)), y: 3)
        }
        .allowsHitTesting(false)
    }

    // MARK: Axis

    private func hourGuides(width: CGFloat) -> some View {
        ForEach(Self.ticks, id: \.self) { hour in
            let x = width * CGFloat(hour) / 24
            Rectangle()
                .fill(Color.strongSeparator.opacity(0.7))
                .frame(width: 1, height: Self.trackHeight)
                .offset(x: min(max(x, 0), max(width - 1, 0)))
        }
    }

    /// Fixed-width labels so the axis reads as a ruler rather than as floating text.
    ///
    /// 这里**必须**是固定高度而不是 `minHeight`：`GeometryReader` 在两个方向上都是
    /// 贪心的，只给下限等于不设上限。这条带原本躺在会滚动的面板里，ScrollView 用
    /// "理想高度"提案，贪心看不出来；钉进页头之后，窗口把真实高度（几百 pt）提案给
    /// 页头，刻度区就把提案整个吃掉——页面从日带往下被推出去两百多 pt，只剩一片空白。
    private var hourAxis: some View {
        GeometryReader { proxy in
            ForEach(Self.ticks, id: \.self) { hour in
                let x = proxy.size.width * CGFloat(hour) / 24
                Text(hour == 24 ? "24" : String(format: "%02d", hour))
                    .font(AppTypography.micro().monospacedDigit())
                    .foregroundStyle(Color.tertiaryInk)
                    .frame(width: 34, alignment: .center)
                    .offset(x: min(max(x - 17, 0), max(proxy.size.width - 34, 0)))
            }
        }
        .frame(height: Self.axisHeight)
    }

    // MARK: Segments

    private struct Segment: Identifiable {
        let id: String
        let x: CGFloat
        let width: CGFloat
        let height: CGFloat
        let y: CGFloat
        let fill: Color
    }

    private func dayStart(_ calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    private func fraction(of moment: Date, calendar: Calendar) -> CGFloat {
        let seconds = moment.timeIntervalSince(dayStart(calendar))
        return CGFloat(min(max(seconds / 86_400, 0), 1))
    }

    /// 高度就是这件事的分量：一段实心专注占满，普通活动矮一档，来回切屏的
    /// 碎片再矮一档（一大片矮块读作"这段时间一直在切"，而不是"这段时间在专注"），
    /// 快记是一枚墨色标记。颜色分不开的东西，高度分得开。
    private func segments(in width: CGFloat) -> [Segment] {
        let calendar = Calendar.current
        var result: [Segment] = []

        for item in items where item.kind != .gap {
            let startFraction = fraction(of: item.start, calendar: calendar)
            // A capture has no duration; give it a tick wide enough to see.
            let endFraction = max(fraction(of: item.end, calendar: calendar), startFraction)
            let x = width * startFraction
            let rawWidth = width * (endFraction - startFraction)
            let isCapture = item.kind == .capture
            let segmentWidth = isCapture ? 3 : max(rawWidth, 2.5)
            let height = height(for: item)

            result.append(
                Segment(
                    id: item.id,
                    x: min(x, max(width - segmentWidth, 0)),
                    width: segmentWidth,
                    height: height,
                    y: (Self.trackHeight - height) / 2,
                    fill: fill(for: item)
                )
            )
        }
        return result
    }

    private func height(for item: ActivityTimelineItem) -> CGFloat {
        if item.kind == .capture { return Self.trackHeight - 10 }
        if item.kind == .gap { return 0 }
        if ActivityClassifier.isFocus(item.category) { return Self.trackHeight - 12 }
        // 不到 3 分钟的切屏：矮一档，让"碎片"在整天的尺度上也读得出来。
        return ActivityTimelineEngine.isFoldable(item) ? Self.trackHeight - 26 : Self.trackHeight - 19
    }

    /// Focused work reads at full strength, everything else recedes, and a written
    /// note is ink rather than activity.
    private func fill(for item: ActivityTimelineItem) -> Color {
        if item.kind == .capture { return Color.ink.opacity(0.72) }
        if item.kind == .gap { return Color.clear }
        if ActivityClassifier.isFocus(item.category) { return AppTheme.accent }
        return AppTheme.accent.opacity(ActivityTimelineEngine.isFoldable(item) ? 0.34 : 0.5)
    }

    /// 现在针带标签。一根没有说明的竖线只是一道划痕。
    private func nowMark(x: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(AppTheme.accent)
                .frame(width: 1.5, height: Self.trackHeight)
                .offset(x: x)

            Text("现在")
                .font(AppTypography.micro().weight(.semibold))
                .foregroundStyle(Color.ctaText)
                .padding(.horizontal, density.spacing(5))
                .padding(.vertical, density.spacing(1))
                .background(AppTheme.accent, in: Capsule())
                .fixedSize()
                .offset(x: x - 16, y: Self.trackHeight - 14)
        }
        .allowsHitTesting(false)
    }

    private func nowOffset(in width: CGFloat) -> CGFloat? {
        guard let now, Calendar.current.isDate(now, inSameDayAs: date) else { return nil }
        return width * fraction(of: now, calendar: .current)
    }

    private var accessibilitySummary: String {
        let recorded = items.filter { $0.kind != .gap }
        guard !recorded.isEmpty else { return "这一天还没有记录的时间带" }
        let first = recorded.map(\.start).min() ?? date
        let last = recorded.map(\.end).max() ?? date
        let total = recorded.reduce(0.0) { $0 + max($1.end.timeIntervalSince($1.start), $1.duration) }
        let focus = recorded.filter { ActivityClassifier.isFocus($0.category) }
            .reduce(0.0) { $0 + max($1.end.timeIntervalSince($1.start), $1.duration) }
        let formatter = Self.accessibilityTimeFormatter
        let focusText = focus > 0 ? "，其中专注 \(ActivityFormatter.time(focus))" : ""
        return "\(formatter.string(from: first)) 到 \(formatter.string(from: last)) 之间共记录 \(ActivityFormatter.time(total))\(focusText)，其余时间没有记录"
    }
}
