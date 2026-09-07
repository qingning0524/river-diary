import SwiftUI

struct RhythmPulseCard: View {
    let pulse: RhythmPulse
    var trend: Int?
    @State private var revealed = false

    var body: some View {
        SoftCard(padding: 26) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    ZStack {
                        Circle()
                            .stroke(Color.border, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: revealed ? max(0.02, Double(pulse.score) / 100) : 0)
                            .stroke(Color(hex: pulse.tone.color), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.65), value: revealed)
                    }
                    .frame(width: 104, height: 104)
                    .overlay {
                        Circle()
                            .stroke(Color(hex: pulse.tone.color).opacity(0.12), lineWidth: 12)
                            .frame(width: 118, height: 118)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("\(pulse.score)")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("脉搏")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            StatusBadge(pulse.tone.label, tone: pulse.score >= 68 ? .positive : .neutral)
                            if let trend {
                                Label("\(trend > 0 ? "+" : "")\(trend)", systemImage: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(trend >= 0 ? Color(hex: "#2C8158") : Color(hex: "#B26B00"))
                            }
                        }

                        Text(pulse.headline)
                            .font(.title3.weight(.semibold))
                        Text(pulse.narrative)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                EqualWidthRow(spacing: 12) {
                    pulseMetric("专注", "\(pulse.focusMinutes)分", "scope")
                    pulseMetric("活跃", "\(pulse.activeMinutes)分", "figure.walk")
                    pulseMetric("情绪", "\(pulse.mood)", "heart")
                    pulseMetric("碎片", "\(pulse.fragmentation)", "arrow.triangle.branch")
                }
            }
        }
        .onAppear {
            revealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                revealed = true
            }
        }
        .onChange(of: pulse.id) {
            revealed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                revealed = true
            }
        }
    }

    private func pulseMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: pulse.tone.color))
                .frame(width: 24, height: 24)
                .background(Color(hex: pulse.tone.color).opacity(0.10), in: Circle())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }
}

struct TodayFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    @Binding var calmMode: Bool

    @State private var draft = AIDraft(
        headline: "正在整理", narrative: "", category: "随想", tags: [],
        mood: 70, energy: 65, focus: 70, output: 65, confidence: 0,
        confidenceFactors: [], evidence: [], signals: [], care: .none, isEmpty: true
    )
    @State private var editedDraft = ""
    @State private var isEditing = false
    @State private var mood: Double = 70
    @State private var energy: Double = 65
    @State private var focus: Double = 70
    @State private var output: Double = 65
    @State private var quickCaptureText = ""

    private var entry: DiaryEntry {
        store.entry(for: selectedDate)
    }

    private var pulse: RhythmPulse {
        RhythmPulseEngine.pulse(date: selectedDate, store: store, activity: activity)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                RhythmPulseCard(pulse: pulse)

                if calmMode {
                    Text("安静模式：今天只需要看见脉搏、草稿和一句新记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    calmDraftCard
                    quickCaptureRow
                } else {
                    TodayView(
                        store: store,
                        activity: activity,
                        ai: ai,
                        selectedDate: $selectedDate,
                        showsHeader: false
                    )
                    .background(.clear)
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .onAppear(perform: loadCalmDraft)
        .onChange(of: selectedDate) { loadCalmDraft() }
        .onChange(of: activity.sessions.count) { loadCalmDraft() }
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(isToday ? "今天" : selectedDate.formatted(.dateTime.month().day().weekday()))
                    .font(.system(size: 38, weight: .bold, design: .serif))
                Text("把这一天拢成一页，先看见脉搏，再决定要不要展开。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                calmMode.toggle()
            } label: {
                Label(calmMode ? "完整视图" : "安静模式", systemImage: calmMode ? "rectangle.expand.vertical" : "leaf.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: "#4E8CFF"))
        }
        .padding(.vertical, 2)
    }

    private var calmDraftCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color.ctaText)
                    Text("今日草稿")
                        .font(.headline)
                    Spacer()
                    if isEditing {
                        Button("取消") { isEditing = false } .buttonStyle(.plain).smallAction()
                    } else {
                        Button("编辑") { isEditing = true } .buttonStyle(.plain).smallAction()
                    }
                }

                Text(draft.headline)
                    .font(.system(size: 21, weight: .semibold, design: .serif))

                if isEditing {
                    TextEditor(text: $editedDraft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 158)
                        .padding(12)
                        .background(Color.editor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Text(editedDraft.isEmpty ? "这一天还没有草稿。可以先从一句话开始。" : editedDraft)
                        .font(.system(size: 18, design: .serif))
                        .lineSpacing(8)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .padding(16)
                        .background(Color.editor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                HStack(spacing: 10) {
                    Label("证据 \(draft.confidence)%", systemImage: "checkmark.seal")
                    if !draft.evidence.isEmpty {
                        Label("\(draft.evidence.count) 类", systemImage: "square.stack.3d.up")
                    }
                    if draft.care != .none {
                        Label("需要留意", systemImage: "heart")
                    }
                    Spacer()
                    Text("自动整理")
                        .foregroundStyle(.secondary)
                    StatusBadge(store.autoDraftPaused || store.isAutoDraftTemporarilyPaused ? "暂停" : "开启", tone: store.autoDraftPaused || store.isAutoDraftTemporarilyPaused ? .attention : .positive)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                EqualWidthRow(spacing: 12) {
                    slider("情绪", $mood)
                    slider("精力", $energy)
                    slider("专注", $focus)
                    slider("产出", $output)
                }

                HStack {
                    if case .saved(let date) = store.saveState {
                        Text("已保存 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("存进今天") { save() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.ctaText)
                }
            }
        }
    }

    private var quickCaptureRow: some View {
        SoftCard(padding: 18) {
            HStack(spacing: 14) {
                Image(systemName: "bolt.badge.clock")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ctaText)
                    .frame(width: 34, height: 34)
                    .background(Color.ctaBackground, in: Circle())

                TextField("一句话，先放进河里", text: $quickCaptureText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .onSubmit(addQuickCapture)

                Button {
                    addQuickCapture()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ctaText)
                .disabled(quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("加入快记")
            }
        }
    }

    private var saveState: JournalSaveState { store.saveState }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))").font(.caption.weight(.semibold))
            }
            Slider(value: value, in: 0...100)
                .tint(Color(hex: "#4E8CFF"))
        }
        .padding(12)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func loadCalmDraft() {
        guard !isEditing else { return }
        let previous = store.entries.last { $0.date < entry.date }
        draft = AIDraftEngine.compose(
            entry: entry,
            previous: previous,
            quickCaptures: store.captures(for: entry),
            autoPaused: store.autoDraftPaused || store.isAutoDraftTemporarilyPaused,
            activitySessions: activity.liveSessions(for: selectedDate)
        )
        editedDraft = draft.narrative
        mood = Double(draft.mood)
        energy = Double(draft.energy)
        focus = Double(draft.focus)
        output = Double(draft.output)
    }

    private func save() {
        store.save(
            entry: entry,
            text: isEditing ? editedDraft : draft.narrative,
            mood: Int(mood),
            energy: Int(energy),
            focus: Int(focus),
            output: Int(output),
            category: draft.category,
            tags: draft.tags
        )
        isEditing = false
    }

    private func addQuickCapture() {
        let text = quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        store.addQuickCapture(text, for: selectedDate)
        quickCaptureText = ""
        loadCalmDraft()
    }
}

struct RhythmFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date

    @State private var mode: Mode = .pulse

    enum Mode: String, CaseIterable, Identifiable {
        case pulse, metrics, footprint

        var id: String { rawValue }
        var title: String {
            switch self {
            case .pulse: "脉搏"
            case .metrics: "指标"
            case .footprint: "足迹"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("视图", selection: $mode.animation(.easeOut(duration: 0.2))) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                if mode == .pulse {
                    pulseView
                } else if mode == .metrics {
                    RhythmView(store: store, activity: activity, anchorDate: $selectedDate)
                        .background(.clear)
                } else {
                    ActivityView(
                        activity: activity,
                        selectedDate: $selectedDate,
                        ai: ai,
                        entries: store.entries,
                        quickCaptures: store.quickCaptures[DiaryEntry.dateFormatter.string(from: selectedDate)] ?? []
                    )
                    .background(.clear)
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 34)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }

    private var pulseView: some View {
        VStack(alignment: .leading, spacing: 18) {
            let pulses = recentPulses
            RhythmPulseCard(pulse: pulses.last ?? RhythmPulseEngine.pulse(date: selectedDate, store: store, activity: activity))
            SoftCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("近七日脉搏")
                        .font(.headline)
                    ForEach(pulses) { pulse in
                        Button {
                            selectedDate = DiaryEntry.dateFormatter.date(from: pulse.dateKey) ?? selectedDate
                        } label: {
                            HStack(spacing: 10) {
                                Text(pulse.dateKey.suffix(5))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                ProgressBar(value: Double(pulse.score))
                                Text("\(pulse.score)")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 28, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var recentPulses: [RhythmPulse] {
        let calendar = Calendar.current
        return (0..<7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: selectedDate) else { return nil }
            return RhythmPulseEngine.pulse(date: date, store: store, activity: activity)
        }.reversed()
    }
}

struct MemoryFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date

    @State private var section: MemorySection = .search

    var body: some View {
        MemoryView(
            ai: ai,
            entries: store.entries,
            quickCaptures: store.quickCaptures.values.flatMap(\.self),
            section: $section
        ) { date in
            selectedDate = date
        }
    }
}

struct SettingsFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    var body: some View {
        PrivacyView(store: store, activity: activity, ai: ai, ingestion: ingestion)
            .background(.clear)
    }
}
