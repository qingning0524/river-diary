import SwiftUI

/// Today is the home: a quiet timeline of what happened today,
/// with real "continue working / pending / status" entry points.
struct TodayRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    @Binding var selectedDate: Date
    var onSelectTimelineItem: (ActivityTimelineItem) -> Void
    var onShowCapture: () -> Void
    var onOpenAsk: (String) -> Void
    var onOpenSettings: () -> Void

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

    private var focusToday: TimeInterval {
        activity.dayStats(entries: store.entries, date: selectedDate).focusTotal
    }

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }
    private var nowSession: ActivitySession? { isToday ? activity.activeSession : nil }
    @State private var selectedItemID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            overviewStrip
            if !store.savedQueries.isEmpty {
                continueRow
                Divider().padding(.horizontal, 24)
            }
            timelineList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            PageTitle(title: "Today", subtitle: subheadline)
            Spacer()
            dayNavigation
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            .keyboardShortcut(.leftArrow, modifiers: .command)

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
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .font(.system(size: 13))
    }

    private func moveDay(_ offset: Int) {
        if let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: selectedDate)) {
            selectedDate = day
        }
    }

    // MARK: Overview (real data, keeps the timeline first-class)

    private var overviewStrip: some View {
        HStack(spacing: 14) {
            meta("已记录", ActivityFormatter.time(recordedToday))
            dot
            Button {
                onShowCapture()
            } label: {
                HStack(spacing: 4) {
                    Text("快记").foregroundStyle(.secondary)
                    Text("\(captures.count)").fontWeight(.medium).foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            dot
            meta("专注", ActivityFormatter.time(focusToday))
            if !store.savedQueries.isEmpty, let first = store.savedQueries.first {
                dot
                Button {
                    onOpenAsk(first.query)
                } label: {
                    Label("继续: \(first.name)", systemImage: "arrow.turn.up.forward")
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 10)
            ingestionStatus
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var dot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func meta(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).foregroundStyle(.primary)
        }
    }

    private var ingestionStatus: some View {
        let level: StatusDot.Level
        let label: String
        if let error = ingestion.lastError, !error.isEmpty {
            level = .error
            label = "采集有问题"
        } else if ingestion.isRunning {
            level = .running
            label = "正在采集"
        } else if ingestion.lastIngestedAt != nil {
            level = .ok
            label = "已采集"
        } else {
            level = .idle
            label = "未采集"
        }
        return StatusDot(level: level, label: label) { onOpenSettings() }
    }

    private var continueRow: some View {
        HStack(spacing: 8) {
            Text("CONTINUE")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.secondaryInk.opacity(0.9))
            ForEach(Array(store.savedQueries.prefix(4))) { query in
                Button {
                    onOpenAsk(query.query)
                } label: {
                    Label(query.name, systemImage: "arrow.turn.up.forward")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.secondaryInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(query.rangeLabel)
            }
            Spacer()
            if store.savedQueries.count > 4 {
                Text("+\(store.savedQueries.count - 4)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        EmptyStateView(
                            title: isToday ? "River is recording." : "这一天还没有记录。",
                            message: isToday
                                ? "Your timeline will appear here as today unfolds."
                                : "使用你身边的应用后，片段会按时间出现。",
                            actionTitle: isToday ? "写一句" : nil,
                            action: isToday ? { onShowCapture() } : nil
                        )
                        .padding(.leading, 80)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(Array(timeline.items.enumerated()), id: \.element.id) { _, item in
                            EpisodeRow(item: item, isSelected: selectedItemID == item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedItemID = item.id
                                    onSelectTimelineItem(item)
                                }
                        }
                        .animation(.easeOut(duration: 0.16), value: selectedItemID)
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.top, 14)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
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

    private var backgroundFill: Color {
        if isSelected { return Color.riverAmethyst.opacity(0.08) }
        return isHovering ? Color.primary.opacity(0.03) : Color.clear
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
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 5)

            Circle()
                .fill(markerColor)
                .frame(width: 9, height: 9)
                .padding(.top, 7)

            content
                .padding(.bottom, 14)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.riverAmethyst.opacity(0.32) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button(isSelected ? "收起详情" : "查看详情") {
                // Selection is handled by onTap in the parent. ContextMenu keeps a
                // reliable path for keyboard / trackpad users without losing feedback.
            }
            .disabled(true)
        }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.16), value: isSelected)
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
                    .font(.system(size: 14, weight: .semibold))
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
                .frame(width: 40, alignment: .trailing)
                .padding(.top, 5)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.appName)
                    .font(.system(size: 14, weight: .semibold))
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
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.bottom, 20)
    }
}
