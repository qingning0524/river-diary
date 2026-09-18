import AppKit
import SwiftUI

// MARK: - New River shell (Personal Memory OS)

enum RiverDestination: String, Hashable, CaseIterable, Identifiable {
    case today
    case memory
    case ask
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .memory: "Memory"
        case .ask: "Ask"
        case .settings: "Settings"
        }
    }

    var shortcutNumber: Int { Array(RiverDestination.allCases).firstIndex(of: self)! + 1 }

    var symbol: String {
        switch self {
        case .today: "book.closed"
        case .memory: "archivebox"
        case .ask: "questionmark.circle"
        case .settings: "gearshape"
        }
    }
}

enum InspectorContent: Identifiable {
    case episode(ActivityTimelineItem)
    case evidence(title: String, entries: [DiaryEntry], captures: [QuickCapture])

    var id: String {
        switch self {
        case .episode(let item): "episode-\(item.id)"
        case .evidence(let title, _, _): "evidence-\(title)"
        }
    }
}

struct RiverShellView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var destination: RiverDestination = .today
    @State private var selectedDate = Date()
    @State private var inspectorContent: InspectorContent?
    @State private var showsCapture = false
    @State private var askQuery = "What have I been working on this week?"
    @AppStorage("appearance.prefersDark") private var isDimmed = false
    @AppStorage("privacy.appLockEnabled") private var appLockEnabled = false
    @State private var isLocked = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 208, max: 240)
        } detail: {
            content
                .ignoresSafeArea()
                .inspector(isPresented: inspectorBinding) {
                    InspectorPanel(content: inspectorContent, store: store)
                        .frame(minWidth: 300, idealWidth: 344, maxWidth: 420)
                }
                .sheet(isPresented: $showsCapture) {
                    QuickNoteSheet(store: store, date: selectedDate)
                }
                .onExitCommand {
                    if inspectorContent != nil { inspectorContent = nil }
                }
        }
        .preferredColorScheme(isDimmed ? .dark : .light)
        .overlay {
            if appLockEnabled && isLocked {
                AppLockGate(isLocked: isLocked, message: "River 已锁定。") {
                    AppLock.unlock { success, _ in isLocked = !success }
                }
            }
        }
        .onAppear {
            ingestion.attach(to: store, activity: activity, ai: ai)
            // No forced AI gate: River is usable without a model connection.
            if ai.hasVerifiedConnection {
                ingestion.start()
            }
            if appLockEnabled { isLocked = true }
        }
        .onDisappear {
            ingestion.stop()
        }
        .onChange(of: destination) { oldValue, newValue in
            if oldValue != newValue {
                inspectorContent = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.checkExternalSnapshotChanged()
            if appLockEnabled && !isLocked { isLocked = true }
        }
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { inspectorContent != nil },
            set: { show in if !show { inspectorContent = nil } }
        )
    }

    private func openAsk(_ query: String) {
        askQuery = query
        destination = .ask
    }

    // MARK: Sidebar


    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                brandMark
                Text("River")
                    .font(.editorial(19, weight: .semibold))
                    .foregroundStyle(Color.ink)
            }
            .padding(.horizontal, 14)
            .padding(.top, 22)
            .padding(.bottom, 26)

            sidebarLabel("留在当下")
            sidebarButton(.today)

            sidebarLabel("回头看看").padding(.top, 20)
            sidebarButton(.memory)
            sidebarButton(.ask)

            Rectangle()
                .fill(Color.separator)
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            sidebarButton(.settings)

            Spacer(minLength: 12)

            Button {
                showsCapture = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text("写一句")
                        .font(.ui(12, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Color.secondaryInk)
                .padding(.horizontal, 13)
                .frame(height: 32)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            HStack(spacing: 7) {
                Circle()
                    .fill(activity.isTracking ? Color(hex: "#2C8158") : Color.secondaryInk.opacity(0.45))
                    .frame(width: 6, height: 6)
                Text(activity.isTracking ? "Recording" : "Recording paused")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondaryInk)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.sidebarSurface)
    }

    private var brandMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.riverAmethyst)
            Image(systemName: "leaf.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 30, height: 30)
    }

    private func sidebarLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(Color.secondaryInk.opacity(0.7))
            .padding(.leading, 14)
            .padding(.bottom, 6)
            .padding(.top, 2)
    }

    private func sidebarButton(_ item: RiverDestination) -> some View {
        let selected = destination == item
        return Button {
            destination = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .frame(width: 18)
                Text(item.title)
                    .font(.ui(13, weight: selected ? .semibold : .regular))
                Spacer()
                if selected {
                    Circle()
                        .fill(Color.riverAmethyst)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(selected ? Color.ink : Color.secondaryInk)
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(selected ? Color.strongSurface : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.separator : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .keyboardShortcut(KeyEquivalent(Character("\(item.shortcutNumber)")), modifiers: .command)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .today:
            TodayRedesignView(
                store: store,
                activity: activity,
                ingestion: ingestion,
                selectedDate: $selectedDate,
                onSelectTimelineItem: { item in
                    inspectorContent = .episode(item)
                },
                onShowCapture: { showsCapture = true },
                onOpenAsk: openAsk,
                onOpenSettings: { destination = .settings }
            )
        case .memory:
            MemoryRedesignView(
                store: store,
                activity: activity,
                onSelectDate: { date in
                    selectedDate = date
                    destination = .today
                }
            )
        case .ask:
            AskRedesignView(
                store: store,
                activity: activity,
                query: $askQuery,
                savedQueries: store.savedQueries,
                onShowEvidence: { title, entries, captures in
                    inspectorContent = .evidence(title: title, entries: entries, captures: captures)
                }
            )
        case .settings:
            SettingsRedesignView(
                store: store,
                activity: activity,
                ai: ai,
                ingestion: ingestion
            )
        }
    }
}

// MARK: - Quick note sheet

struct QuickNoteSheet: View {
    @ObservedObject var store: DiaryStore
    let date: Date
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("写一句")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $text)
                .font(.system(size: 14))
                .frame(minWidth: 380, minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("留下这句") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    store.addQuickCapture(trimmed, for: date)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
