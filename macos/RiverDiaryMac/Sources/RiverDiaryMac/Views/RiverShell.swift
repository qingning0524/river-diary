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

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "water.waves")
                    .font(.system(size: 20, weight: .light))
                Text("River")
                    .font(.system(size: 17, weight: .medium, design: .serif))
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 28)

            VStack(spacing: 2) {
                sidebarButton(.today)
                sidebarButton(.memory)
                sidebarButton(.ask)
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            sidebarButton(.settings)

            Spacer(minLength: 12)

            Button {
                showsCapture = true
            } label: {
                Label("写一句", systemImage: "square.and.pencil")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Circle()
                    .fill(activity.isTracking ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(activity.isTracking ? "Recording" : "Recording paused")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func sidebarButton(_ item: RiverDestination) -> some View {
        let selected = destination == item
        return Button {
            destination = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                selectedDate: $selectedDate,
                onSelectTimelineItem: { item in
                    inspectorContent = .episode(item)
                },
                onAskEvidence: { title, entries, captures in
                    inspectorContent = .evidence(title: title, entries: entries, captures: captures)
                    destination = .ask
                },
                onShowCapture: { showsCapture = true }
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
