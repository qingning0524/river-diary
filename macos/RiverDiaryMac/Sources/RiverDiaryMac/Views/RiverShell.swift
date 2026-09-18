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
                .navigationSplitViewColumnWidth(min: 158, ideal: 182, max: 216)
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
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showsCapture = true
                        } label: {
                            Label("写一句", systemImage: "square.and.pencil")
                        }
                        .keyboardShortcut("n", modifiers: .command)
                    }
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
            HStack(spacing: 7) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("River")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 18)

            sidebarSection("RIVER")
            sidebarItem(.today)

            sidebarSection("MEMORY").padding(.top, 12)
            sidebarItem(.memory)
            sidebarItem(.ask)

            Rectangle()
                .fill(Color.separator)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            sidebarSection("SYSTEM")
            sidebarItem(.settings)

            Spacer(minLength: 8)

            Button {
                showsCapture = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12))
                    Text("写一句")
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("记录一句（⌘N）")

            HStack(spacing: 6) {
                Circle()
                    .fill(activity.isTracking ? Color(hex: "#2C8158") : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(activity.isTracking ? "Recording" : "Recording paused")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .padding(.bottom, 3)
    }

    private func sidebarItem(_ item: RiverDestination) -> some View {
        let selected = destination == item
        return Button {
            destination = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
