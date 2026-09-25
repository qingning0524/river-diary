import SwiftUI

/// The whole day in one band.
///
/// A row list answers "what happened, in order". It cannot answer "where in the
/// day is the recorded evidence, and where are the holes" — that needs the day
/// laid out once. This band is that single glance: a fixed 00:00–24:00 axis so
/// days are comparable, recorded segments in the one accent, and empty space
/// where nothing was recorded. It is deliberately not a chart: no axis grid
/// drama, no per-category rainbow, no decoration.
struct RiverDayRibbon: View {
    @Environment(\.riverDensity) private var density
    let date: Date
    let items: [ActivityTimelineItem]
    /// Pass the current moment only when the ribbon shows today; draws a "now" tick.
    var now: Date?

    /// Height of the day band. Exposed so layout tests can address the track
    /// without duplicating the number.
    static let trackHeight: CGFloat = 38
    /// Hour ticks every six hours: enough to place yourself, not a grid.
    private static let ticks = [0, 6, 12, 18, 24]

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
                        Rectangle()
                            .fill(AppTheme.accent)
                            .frame(width: 1.5)
                            .offset(x: nowX, y: 0)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
            }
            .frame(height: Self.trackHeight)
            .accessibilityElement()
            .accessibilityLabel("一天的时间带")
            .accessibilityValue(accessibilitySummary)

            hourAxis
        }
    }

    // MARK: Axis

    private func hourGuides(width: CGFloat) -> some View {
        ForEach(Self.ticks, id: \.self) { hour in
            let x = width * CGFloat(hour) / 24
            Rectangle()
                .fill(Color.separator)
                .frame(width: 1)
                .offset(x: min(max(x, 0), width - 1))
        }
    }

    /// Fixed-width labels so the axis reads as a ruler rather than as floating text.
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
        .frame(height: 12)
    }

    // MARK: Segments

    private struct Segment {
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
            let clampedX = min(x, max(width - segmentWidth, 0))
            let height: CGFloat = isCapture ? Self.trackHeight - 12 : Self.trackHeight - 20

            result.append(
                Segment(
                    id: item.id,
                    x: clampedX,
                    width: segmentWidth,
                    height: height,
                    y: (Self.trackHeight - height) / 2,
                    fill: fill(for: item)
                )
            )
        }
        return result
    }

    /// Focused work reads at full strength, everything else recedes, and a written
    /// note is ink rather than activity.
    private func fill(for item: ActivityTimelineItem) -> Color {
        switch item.kind {
        case .capture: Color.ink.opacity(0.55)
        case .gap: .clear
        case .activity: ActivityClassifier.isFocus(item.category) ? AppTheme.accent : AppTheme.accent.opacity(0.42)
        }
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
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: first)) 到 \(formatter.string(from: last)) 之间共记录 \(ActivityFormatter.time(total))，其余时间没有记录"
    }
}
