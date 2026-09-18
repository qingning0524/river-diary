import SwiftUI

/// Today is the home: a quiet timeline of what happened today.
struct TodayRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @Binding var selectedDate: Date
    var onSelectTimelineItem: (ActivityTimelineItem) -> Void
    var onAskEvidence: (String, [DiaryEntry], [QuickCapture]) -> Void
    var onShowCapture: () -> Void

    private var entry: DiaryEntry { store.entry(for: selectedDate) }
    private var captures: [QuickCapture] { store.captures(for: entry) }

    private var timeline: ActivityTimeline {
        ActivityTimelineEngine.build(
            for: selectedDate,
            sessions: activity.liveSessions(for: selectedDate),
            captures: captures,
            annotations: store.timelineAnnotations
        )
    }

    private var recordedToday: TimeInterval {
        timeline.totalDuration
    }

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var nowSession: ActivitySession? { isToday ? activity.activeSession : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            timelineList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("A PAGE OF YOUR LIFE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(Color.riverAmethyst)
                Text("Today")
                    .font(.editorial(30, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(subheadline)
                    .font(.ui(11))
                    .foregroundStyle(Color.secondaryInk)
            }
            Spacer()
            dayNavigation
            Button(action: onShowCapture) {
                Label("写一句", systemImage: "square.and.pencil")
                    .font(.ui(12, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var subheadline: String {
        let dateText = selectedDate.formatted(.dateTime.month().day())
        if isToday {
            if recordedToday > 0 {
                return "\(dateText) · River has been recording for \(ActivityFormatter.time(recordedToday))."
            }
            return "\(dateText) · River is recording. Your timeline will appear here as today unfolds."
        }
        return "\(dateText) · \(selectedDate.formatted(.dateTime.weekday(.wide)))"
    }

    private var dayNavigation: some View {
        HStack(spacing: 6) {
            Button(action: { moveDay(-1) }) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Button(action: { selectedDate = Date() }) {
                Text("今天")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isToday ? Color.secondary : Color.riverAmethyst)

            Button(action: { moveDay(1) }) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(isToday)
        }
        .font(.system(size: 13))
    }

    private func moveDay(_ offset: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: selectedDate)) {
            selectedDate = day
        }
    }

    // MARK: Timeline

    private var timelineList: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                // Continuous timeline line.
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 1)
                    .padding(.leading, 96)
                    .padding(.top, 14)

                LazyVStack(alignment: .leading, spacing: 0) {
                    if let now = nowSession {
                        NowRow(session: now)
                    }
                    if timeline.items.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(timeline.items.enumerated()), id: \.element.id) { _, item in
                            EpisodeRow(item: item, isSelected: false)
                                .contentShape(Rectangle())
                                .onTapGesture { onSelectTimelineItem(item) }
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isToday ? "River is recording." : "这一天还没有记录。")
                .font(.system(size: 14, weight: .medium))
            Text(isToday ? "Your timeline will appear here as today unfolds." : "使用你身边的应用后，片段会按时间出现。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 96)
        .padding(.vertical, 30)
    }
}

// MARK: - Episode row

struct EpisodeRow: View {
    let item: ActivityTimelineItem
    let isSelected: Bool
    @State private var isHovering = false

    private var clock: String {
        item.start.formatted(date: .omitted, time: .shortened)
    }

    private var markerColor: Color {
        switch item.kind {
        case .capture: Color.accentColor
        case .gap: Color.secondary.opacity(0.5)
        case .activity: item.isFavorite ? Color.orange : Color.accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(clock)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
                .padding(.top, 5)

            Circle()
                .fill(markerColor)
                .frame(width: 9, height: 9)
                .padding(.top, 7)

            content
                .padding(.bottom, 26)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
        .background(
            isHovering ? Color.primary.opacity(0.03) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { hover in isHovering = hover }
    }

    @ViewBuilder
    private var content: some View {
        if item.kind == .gap {
            Text(item.title)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .italic()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.editorial(15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(item.summary)
                    .font(.ui(12))
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(2)
                if !item.apps.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(item.apps.prefix(3), id: \.name) { app in
                            Text("\(app.name)")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.08), in: Capsule())
                        }
                        if item.duration > 0 {
                            Text(ActivityFormatter.time(item.duration))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }
}

// MARK: - Now row

struct NowRow: View {
    let session: ActivitySession

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("NOW")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, alignment: .trailing)
                .padding(.top, 5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.appName)
                    .font(.system(size: 15, weight: .semibold, design: .serif))
                if let title = session.windowTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(ActivityFormatter.time(Date().timeIntervalSince(session.start)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .padding(.bottom, 20)
    }
}
