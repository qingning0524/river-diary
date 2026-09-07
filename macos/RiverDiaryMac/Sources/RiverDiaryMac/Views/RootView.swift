import SwiftUI

enum NavigationSection: String, CaseIterable, Identifiable {
    case record, timeline, memory, control

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: "记录"
        case .timeline: "时间"
        case .memory: "记忆"
        case .control: "控制"
        }
    }

    var destinations: [NavigationDestination] {
        switch self {
        case .record: [.today]
        case .timeline: [.river, .rhythm, .activity, .dataExplorer]
        case .memory: [.aiAnalysis, .memorySearch, .memoryInsight, .memoryNotes]
        case .control: [.privacy]
        }
    }
}

enum NavigationDestination: String, CaseIterable, Identifiable {
    case today
    case river
    case rhythm
    case activity
    case dataExplorer
    case aiAnalysis
    case memorySearch
    case memoryInsight
    case memoryNotes
    case privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "主页"
        case .river: "河流"
        case .rhythm: "节律"
        case .activity: "足迹"
        case .dataExplorer: "数据库"
        case .aiAnalysis: "AI 分析"
        case .memorySearch: "回忆搜索"
        case .memoryInsight: "状态"
        case .memoryNotes: "随笔"
        case .privacy: "设置"
        }
    }

    var icon: String {
        switch self {
        case .today: "sparkles"
        case .river: "drop.fill"
        case .rhythm: "chart.dots.scatter"
        case .activity: "waveform.path.ecg"
        case .dataExplorer: "externaldrive"
        case .aiAnalysis: "sparkles.rectangle.stack"
        case .memorySearch: "magnifyingglass"
        case .memoryInsight: "brain.head.profile"
        case .memoryNotes: "note.text"
        case .privacy: "lock.shield"
        }
    }

    var memorySection: MemorySection? {
        switch self {
        case .memorySearch: .search
        case .memoryInsight: .insight
        case .memoryNotes: .notes
        default: nil
        }
    }
}

struct NavigationDateCard: View {
    @Binding var selection: Date
    @State private var showsCalendar = false

    private var isToday: Bool { Calendar.current.isDateInToday(selection) }
    private var isTomorrow: Bool { Calendar.current.isDate(selection, inSameDayAs: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()) }
    private var latestSelectableDate: Date { Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date() }
    private var dateText: String {
        let weekday = selection.formatted(.dateTime.weekday(.abbreviated))
        let day = selection.formatted(.dateTime.month().day())
        return isToday ? "今天 · \(day)" : "\(day) \(weekday)"
    }

    var body: some View {
        HStack(spacing: 5) {
            arrowButton(direction: -1)

            Button {
                showsCalendar.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.ctaText)

                    Text(dateText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    if !isToday {
                        Text("统一")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCalendar, arrowEdge: .bottom) {
                DatePicker(
                    "统一选择日期",
                    selection: $selection,
                    in: ...latestSelectableDate,
                    displayedComponents: [.date]
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(12)
            }

            arrowButton(direction: 1)

            if !isToday {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = Date() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondaryInk)
                        .frame(width: 26, height: 32)
                        .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("回今天")
            }
        }
    }

    private func arrowButton(direction: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                selection = Calendar.current.date(byAdding: .day, value: direction, to: selection) ?? selection
            }
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 24, height: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(direction > 0 && isTomorrow)
        .keyboardShortcut(direction < 0 ? .leftArrow : .rightArrow, modifiers: .command)
        .help(direction < 0 ? "前一天" : "后一天")
    }
}

struct RootView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var destination: NavigationDestination = .today
    @State private var memorySection: MemorySection = .search
    @State private var selectedDate = Date()
    @AppStorage("appearance.prefersDark") private var isDimmed = false
    @State private var hoveredDestination: NavigationDestination?
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @State private var lockMessage = ""

    var body: some View {
        ZStack {
            VisualBackground()

            HStack(alignment: .top, spacing: 20) {
                sidebar
                    .frame(width: AppLayout.sidebarWidth, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 16) {
                    contentTopBar

                    Group {
                        if let error = store.loadError {
                            errorView(error)
                        } else {
                            selectedView
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(AppLayout.outerPadding)
        }
        .preferredColorScheme(isDimmed ? .dark : .light)
        .animation(.easeOut(duration: 0.22), value: destination)
        .animation(.easeOut(duration: 0.22), value: isDimmed)
        .overlay {
            if appLockEnabled && isLocked {
                AppLockGate(isLocked: isLocked, message: lockMessage) {
                    unlockApp()
                }
            }
        }
        .onAppear {
            if appLockEnabled { isLocked = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalSnapshotChanged()
            if appLockEnabled && isLocked == false {
                isLocked = true
            }
        }
    }

    private func unlockApp() {
        AppLock.unlock { success, message in
            isLocked = !success
            lockMessage = message
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            brand

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(NavigationSection.allCases.filter { $0 != .control }) { section in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 6)

                            ForEach(section.destinations) { item in
                                navigationButton(item)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            navigationButton(.privacy)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 22, x: 0, y: 14)
    }

    private var contentTopBar: some View {
        HStack(spacing: 14) {
            NavigationDateCard(selection: $selectedDate)
                .frame(maxWidth: 368, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                statusPill("采集", ingestion.enabled ? ingestion.captureTimeLabel() : "关闭", ready: ingestion.enabled)
                statusPill("足迹", activity.isTracking ? "开启" : "关闭", ready: activity.isTracking)
                statusPill("AI", ai.analysisReady ? "就绪" : ai.isEnabled ? "未连" : "关闭", ready: ai.analysisReady)
            }

            themeButton
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.ctaText)
                .frame(width: 32, height: 32)
                .background(Color.ctaBackground, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("River Diary")
                    .font(.system(size: 14, weight: .semibold))
                Text("生活节律")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var themeButton: some View {
        Button {
            isDimmed.toggle()
        } label: {
            Image(systemName: isDimmed ? "sun.max" : "moon")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 32, height: 32)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(isDimmed ? "切换到浅色" : "切换到深色")
    }

    private func navigationButton(_ item: NavigationDestination) -> some View {
        let isSelected = destination == item
        let isHovered = hoveredDestination == item

        return Button {
            if let memory = item.memorySection {
                memorySection = memory
            }
            destination = item
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.ctaText : Color.secondaryInk)
                    .frame(width: 24, height: 24)
                    .background(isSelected ? Color.ctaBackground : Color.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(item.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge = badge(for: item) {
                    Text(badge)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.chip, in: Capsule())
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.strongSurface)
                        .shadow(color: .black.opacity(0.06), radius: 10, y: 4)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.chip)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.15)) {
                if isHovered {
                    hoveredDestination = item
                } else if hoveredDestination == item {
                    hoveredDestination = nil
                }
            }
        }
        .keyboardShortcut(KeyEquivalent(Character("\(index(of: item) + 1)")), modifiers: .command)
    }

    private func badge(for item: NavigationDestination) -> String? {
        switch item {
        case .today:
            return store.autoDraftPaused ? "暂停" : nil
        case .activity:
            return activity.isTracking ? nil : "关"
        case .memoryNotes:
            let count = store.quickCaptures.values.reduce(0) { $0 + $1.count }
            return count > 0 ? "\(min(count, 99))" : nil
        default:
            return nil
        }
    }

    private func statusPill(_ title: String, _ value: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
        }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.border, lineWidth: 1))
            .fixedSize()
    }

    private func navigationStatus(_ title: String, _ value: String, ready: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ready ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                .frame(width: 5, height: 5)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
        }
    }

    private var sourceReady: Bool {
        store.externalSourceURL != nil && store.externalSourceError == nil
    }

    private func index(of item: NavigationDestination) -> Int {
        NavigationDestination.allCases.firstIndex(of: item) ?? 0
    }

    @ViewBuilder
    private var selectedView: some View {
        switch destination {
        case .today:
            TodayView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate)
        case .river:
            RiverView(entries: store.entries, selectedDate: selectedDate, ai: ai)
        case .rhythm:
            RhythmView(store: store, activity: activity, anchorDate: $selectedDate)
        case .activity:
            ActivityView(
                activity: activity,
                selectedDate: $selectedDate,
                ai: ai,
                entries: store.entries,
                quickCaptures: store.quickCaptures[DiaryEntry.dateFormatter.string(from: selectedDate)] ?? []
            )
        case .dataExplorer:
            DataExplorerView(ingestion: ingestion, selectedDate: $selectedDate)
        case .aiAnalysis:
            AIAnalysisView(store: store, activity: activity, ai: ai, anchorDate: $selectedDate)
        case .memorySearch, .memoryInsight, .memoryNotes:
            MemoryView(
                ai: ai,
                entries: store.entries,
                quickCaptures: store.quickCaptures.values.flatMap(\.self),
                section: $memorySection
            ) { date in
                selectedDate = date
                destination = .today
            }
        case .privacy:
            PrivacyView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        }
    }

    private func errorView(_ message: String) -> some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("数据加载失败", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 560)
    }
}
