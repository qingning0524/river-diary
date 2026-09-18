import SwiftUI

struct RootView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @StateObject private var editor = JournalEditorStore()

    @State private var destination: AppDestination = .today
    @State private var timeSection: TimeSection = .activity
    @State private var memorySection: MemorySection = .archive
    @State private var systemSection: SystemSection = .controls
    @State private var selectedDate = Date()
    @State private var showsCapture = false
    @State private var showsCommands = false
    @AppStorage("appearance.prefersDark") private var isDimmed = false
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false
    @State private var lockMessage = ""
    @State private var showsRequiredAISetup = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: AppLayout.sidebarWidth)
            Rectangle().fill(Color.separator).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                Divider().overlay(Color.separator)
                Group {
                    if let error = store.loadError {
                        ContentUnavailableView("日记暂时无法读取", systemImage: "exclamationmark.folder", description: Text(error))
                    } else { selectedView }
                }
                .frame(maxWidth: AppLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .background(Color.workspace)
        .preferredColorScheme(isDimmed ? .dark : .light)
        .sheet(isPresented: $showsRequiredAISetup, onDismiss: {
            if ai.hasVerifiedConnection {
                ingestion.start()
            }
        }) {
            AIRequiredSetupView(ai: ai) {
                showsRequiredAISetup = false
            }
            .interactiveDismissDisabled(!ai.hasVerifiedConnection)
        }
        .sheet(isPresented: $showsCapture) { WorkspaceCaptureSheet(store: store, date: selectedDate) }
        .sheet(isPresented: $showsCommands) {
            WorkspaceCommandPalette { command in
                switch command {
                case .destination(let value): destination = value
                case .today: openDiary(Date())
                case .capture: showsCapture = true
                case .date(let date): openDiary(date)
                }
            }
        }
        .overlay {
            if appLockEnabled && isLocked {
                AppLockGate(isLocked: isLocked, message: lockMessage) {
                    AppLock.unlock { success, message in isLocked = !success; lockMessage = message }
                }
            }
        }
        .onAppear {
            ingestion.attach(to: store, activity: activity, ai: ai)
            showsRequiredAISetup = !ai.hasVerifiedConnection
            if ai.hasVerifiedConnection {
                ingestion.start()
            }
            if appLockEnabled { isLocked = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalSnapshotChanged()
            if appLockEnabled && !isLocked { isLocked = true }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "water.waves").font(.system(size: 25, weight: .light)).foregroundStyle(Color.riverAmethyst)
                VStack(alignment: .leading, spacing: 3) {
                    Text("河流").font(.system(size: 21, weight: .medium, design: .serif))
                    Text("RIVER DIARY").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.top, 24).padding(.bottom, 32)
            sidebarLabel("留在当下")
            navigationButton(.today)
            navigationButton(.time)
            sidebarLabel("回头看看").padding(.top, 24)
            navigationButton(.memory)
            navigationButton(.insight)

            let recent = store.entries.filter { !$0.displayOverview.isEmpty }.suffix(3).reversed()
            if !recent.isEmpty {
                sidebarLabel("最近写下").padding(.top, 30)
                ForEach(Array(recent)) { entry in
                    Button { if let date = entry.entryDate { openDiary(date) } } label: {
                        HStack(spacing: 8) {
                            Text(entry.shortDate).font(.system(size: 10, design: .monospaced)).frame(width: 47, alignment: .leading)
                            Text(entry.displayOverview).font(.system(size: 11)).lineLimit(1)
                        }
                        .foregroundStyle(Color.secondaryInk).padding(.horizontal, 13).padding(.vertical, 8)
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 18)
            Button { showsCapture = true } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("记录一句")
                    Spacer()
                    Text("⇧⌘N").font(.system(size: 10)).opacity(0.55)
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ctaText)
                .padding(12).background(Color.ctaBackground, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).keyboardShortcut("n", modifiers: [.command, .shift])
            .padding(.horizontal, 8).padding(.bottom, 20)
            navigationButton(.system)
            HStack(spacing: 6) {
                Circle().fill(activity.isTracking ? Color.green.opacity(0.7) : Color.secondaryInk.opacity(0.4)).frame(width: 5, height: 5)
                Text(activity.isTracking ? "生活正在被记录" : "实时记录已暂停")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background(Color.sidebarSurface)
    }

    private func sidebarLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            .padding(.leading, 14).padding(.bottom, 8)
    }

    private func navigationButton(_ item: AppDestination) -> some View {
        let selected = destination == item
        return Button { destination = item } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon).font(.system(size: 15, weight: .regular)).frame(width: 20)
                Text(item.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if selected { Circle().fill(Color.riverAmethyst).frame(width: 5, height: 5) }
            }
            .foregroundStyle(selected ? Color.ink : Color.secondaryInk)
            .padding(.horizontal, 13).frame(height: 41)
            .background(selected ? Color.strongSurface : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.separator : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain).padding(.vertical, 2)
        .keyboardShortcut(KeyEquivalent(Character("\(item.shortcutNumber)")), modifiers: .command)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(destination.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondaryInk)
            if destination == .today || destination == .insight || (destination == .time && timeSection != .activity) || (destination == .system && systemSection == .data) {
                Rectangle().fill(Color.separator).frame(width: 1, height: 16)
                NavigationDateCard(selection: $selectedDate).frame(maxWidth: 320)
            }
            Spacer()
            Button { showsCommands = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("前往…")
                    Text("⌘K").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).keyboardShortcut("k", modifiers: .command)
            Button { isDimmed.toggle() } label: {
                Image(systemName: isDimmed ? "sun.max" : "moon")
                    .font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 28, height: 28)
            }.buttonStyle(.plain).help(isDimmed ? "切换浅色" : "切换深色")
        }
        .padding(.horizontal, 26).frame(height: 54)
    }

    @ViewBuilder private var selectedView: some View {
        switch destination {
        case .today:
            TodayView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate, editor: editor) {
                timeSection = .activity; destination = .time
            }
        case .time:
            TimeFlowView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate, section: $timeSection, openDiary: { destination = .today })
        case .memory:
            MemoryFlowView(ai: ai, entries: store.entries, quickCaptures: store.quickCaptures.values.flatMap(\.self), assignedCaptures: store.quickCaptures, section: $memorySection, openDate: openDiary)
        case .insight:
            InsightFlowView(store: store, activity: activity, ai: ai, selectedDate: $selectedDate)
        case .system:
            SystemFlowView(store: store, activity: activity, ai: ai, ingestion: ingestion, selectedDate: $selectedDate, section: $systemSection)
        }
    }

    private func openDiary(_ date: Date) { selectedDate = date; destination = .today }
}
