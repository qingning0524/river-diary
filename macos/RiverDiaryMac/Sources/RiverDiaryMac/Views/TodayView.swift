import SwiftUI

struct TodayView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    var showsHeader: Bool = true

    @State private var draft: AIDraft = AIDraft(
        headline: "正在整理今天", narrative: "", category: "随想", tags: [],
        mood: 70, energy: 65, focus: 70, output: 65, confidence: 0,
        confidenceFactors: [], evidence: [], signals: [], care: .none, isEmpty: true
    )
    @State private var editedDraft = ""
    @State private var isEditing = false
    @State private var showsEvidence = false
    @State private var showsFineTune = false
    @State private var selectedTags: [String] = []
    @State private var selectedCategory = "随想"
    @State private var mood: Double = 70
    @State private var energy: Double = 65
    @State private var focus: Double = 70
    @State private var output: Double = 65
    @State private var quickCaptureText = ""
    @State private var quickCaptureTag: String?
    @State private var selectedMoodID: String?

    private var entry: DiaryEntry {
        store.entry(for: selectedDate)
    }

    private var previousEntry: DiaryEntry? {
        let dateString = DiaryEntry.dateFormatter.string(from: selectedDate)
        return store.entries.last { $0.date < dateString }
    }

    private var captures: [QuickCapture] {
        store.captures(for: entry)
    }

    private var overall: Int {
        Int((mood * 0.4 + output * 0.25 + focus * 0.2 + energy * 0.15).rounded())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeader {
                    header
                }
                moodStrip
                careCard
                draftCard
                if entry.hasMovementSignal || entry.hasStructuredSleepSignal || !entry.sleepSignals.isEmpty {
                    HStack(alignment: .top, spacing: 18) {
                        if entry.hasMovementSignal {
                            movementCard
                        }
                        if entry.hasStructuredSleepSignal || !entry.sleepSignals.isEmpty {
                            sleepCard
                        }
                    }
                }
                if entry.hasProjectSignals {
                    projectSignalsCard
                }
                HStack(alignment: .top, spacing: 18) {
                    quickCaptureCard
                    fineTuneCard
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 10)
            .padding(.bottom, 36)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .onAppear(perform: loadDraft)
        .onChange(of: selectedDate) {
            ai.clearTask(.dailyOverview)
            loadDraft()
        }
        .onChange(of: entry.id) {
            ai.clearTask(.dailyOverview)
            loadDraft()
        }
        .onChange(of: activity.sessions.count) {
            loadDraft()
        }
    }

    private func loadDraft() {
        guard !isEditing else { return }

        draft = AIDraftEngine.compose(
            entry: entry,
            previous: previousEntry,
            quickCaptures: store.captures(for: entry),
            autoPaused: store.autoDraftPaused || store.isAutoDraftTemporarilyPaused,
            activitySessions: activity.liveSessions(for: selectedDate)
        )
        editedDraft = draft.narrative
        selectedCategory = draft.category
        selectedTags = draft.tags
        mood = Double(draft.mood)
        energy = Double(draft.energy)
        focus = Double(draft.focus)
        output = Double(draft.output)
        isEditing = false
        showsEvidence = false
    }

    @ViewBuilder
    private var saveFeedback: some View {
        switch store.saveState {
        case .saving:
            Text("正在保存…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .saved(let date):
            Text("已保存 · \(date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(Color(hex: "#2C8158"))
        case .failed:
            Text("保存失败")
                .font(.caption2)
                .foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }

    private func saveDraft() {
        let text = isEditing ? editedDraft : draft.narrative
        store.save(
            entry: entry,
            text: text,
            mood: Int(mood),
            energy: Int(energy),
            focus: Int(focus),
            output: Int(output),
            category: selectedCategory,
            tags: selectedTags
        )
        isEditing = false
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var recentEntries: [DiaryEntry] {
        Array(store.entries.suffix(14))
    }

    @ViewBuilder
    private var moodStrip: some View {
        if recentEntries.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("最近 14 天的节律")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.secondaryInk)
                    Text("冷一点或暖一点，都只是此刻的形状。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                MoodAreaChart(entries: recentEntries, selectedID: $selectedMoodID)
                    .frame(height: 74)
            }
            .frame(maxWidth: 1280, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("River Diary")
                .font(.caption.weight(.semibold).smallCaps())
                .foregroundStyle(.secondary)
            Text(isToday ? "今天" : entry.shortDate)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text("日期由导航栏统一控制；你只管随手记，这里帮你把当天拢成一页。")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private var movementCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("身体活动", systemImage: "figure.walk.motion")
                        .font(.headline)
                    Spacer()
                    StatusBadge(
                        entry.hasMovementSignal ? "数据已同步" : "等待数据",
                        tone: entry.hasMovementSignal ? .positive : .neutral
                    )
                }

                if entry.hasMovementSignal {
                    EqualWidthRow(spacing: 10) {
                        if let steps = entry.health?.steps {
                            bodyMetric("步数", "\(steps)", "figure.walk")
                        }
                        if let distance = entry.health?.distanceKM {
                            bodyMetric("距离", String(format: "%.2f km", distance), "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        if let energy = entry.health?.activeEnergyKcal {
                            bodyMetric("活动热量", String(format: "%.1f kcal", energy), "flame.fill")
                        }
                    }
                } else {
                    Text("这一天还没有同步到步数、距离或活动热量。")
                        .font(.caption)
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sleepCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("睡眠", systemImage: "moon.zzz.fill")
                        .font(.headline)
                    Spacer()
                    StatusBadge(
                        entry.hasStructuredSleepSignal ? "结构化记录" : "文字线索",
                        tone: entry.hasStructuredSleepSignal ? .positive : .neutral
                    )
                }

                if let hours = entry.health?.resolvedSleepHours {
                    EqualWidthRow(spacing: 10) {
                        bodyMetric("睡眠时长", String(format: "%.1f 小时", hours), "bed.double.fill")
                        if let bed = entry.health?.bedAt {
                            bodyMetric("入睡", bed, "moon.zzz")
                        }
                        if let wake = entry.health?.wakeAt {
                            bodyMetric("醒来", wake, "sunrise")
                        }
                    }
                } else if let bed = entry.health?.bedAt, let wake = entry.health?.wakeAt {
                    Text("入睡 \(bed) · 醒来 \(wake)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                let signals = entry.sleepSignals
                if signals.isEmpty {
                    Text(entry.hasStructuredSleepSignal ? "健康记录已经显示在这里。" : "没有发现明显的睡眠线索，所以这里不会补写。")
                        .font(.caption)
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(signals.prefix(3)) { signal in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "text.quote")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(signal.text)
                                        .font(.caption)
                                        .lineSpacing(4)
                                    Text(signal.source)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func bodyMetric(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 26, height: 26)
                .background(Color.chip, in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private var careCard: some View {
        if draft.care != .none && !store.careAcknowledged(entry) {
            SoftCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: draft.care == .support ? "heart.circle.fill" : "leaf.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(draft.care == .support ? Color(hex: "#FF8FB3") : Color(hex: "#7CB342"))

                    VStack(alignment: .leading, spacing: 7) {
                        Text(CareAdvisor.title(for: draft.care)).font(.headline)
                        Text(CareAdvisor.message(for: draft.care))
                            .font(.caption).lineSpacing(5).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("知道了") { store.acknowledgeCare(entry) }
                        .buttonStyle(.plain).smallAction()
                }
            }
            .frame(maxWidth: 1280)
        }
    }

    private var draftCard: some View {
        SoftCard(padding: 32) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("本日概览", systemImage: "sparkles")
                            .font(.headline)
                        Text(draft.headline)
                            .font(.system(size: 29, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 7) {
                        saveFeedback
                        confidence
                        Toggle("自动整理", isOn: Binding(
                            get: { !(store.autoDraftPaused || store.isAutoDraftTemporarilyPaused) },
                            set: { enabled in
                                if enabled && store.isAutoDraftTemporarilyPaused {
                                    store.resumeAutoDraftPause()
                                } else {
                                    store.setAutoDraftPaused(!enabled)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .font(.caption)
                    }
                }

                if store.draftDismissed(entry) {
                    HStack {
                        Label("你选择了暂不整理。素材仍在本机保留。", systemImage: "moon.zzz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复草稿") { store.restoreDraft(for: entry) }
                            .buttonStyle(.plain).smallAction()
                    }
                    .padding(12)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 14))
                } else if isEditing {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("修改这一句").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextEditor(text: $editedDraft)
                            .font(.system(size: 14))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 112)
                            .padding(14)
                            .background(Color.editor, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
                    }
                } else {
                    Text(draft.narrative)
                        .font(.system(size: 18, weight: .medium))
                        .lineSpacing(9)
                        .foregroundStyle(Color.ink)
                }

                HStack(spacing: 7) {
                    ForEach(selectedTags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.chip, in: Capsule())
                    }
                    Text(selectedCategory)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.chip, in: Capsule())
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button { saveDraft() } label: {
                        Label(store.draftDismissed(entry) ? "恢复并保存" : "保存草稿", systemImage: "checkmark")
                    }
                    .buttonStyle(.plain).primaryCTA()
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.isEmpty && editedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button(isEditing ? "预览" : "改一句") {
                        if isEditing {
                            editedDraft = editedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            editedDraft = draft.narrative
                        }
                        isEditing.toggle()
                    }
                    .buttonStyle(.plain).secondaryCTA()

                    if store.draftDismissed(entry) {
                        Button("已暂不整理") {}
                            .buttonStyle(.plain).secondaryCTA()
                            .disabled(true)
                    } else {
                        Menu {
                            Button("今天先不整理") { store.dismissDraft(for: entry) }
                            Divider()
                            Button("让 AI 安静 1 天") { store.pauseAutoDraft(days: 1) }
                            Button("让 AI 安静 3 天") { store.pauseAutoDraft(days: 3) }
                            Button("让 AI 安静 7 天") { store.pauseAutoDraft(days: 7) }
                        } label: {
                            Label("今天不记", systemImage: "moon.zzz")
                        }
                        .buttonStyle(.plain).secondaryCTA()
                    }

                    Button(showsEvidence ? "隐藏依据" : "查看依据") {
                        showsEvidence.toggle()
                    }
                    .buttonStyle(.plain).secondaryCTA()
                }

                if showsEvidence {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(draft.evidence) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Circle().fill(Color.ink.opacity(0.2)).frame(width: 6, height: 6).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.title).font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(item.source).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(item.detail)
                                        .font(.caption).lineSpacing(4).foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.editor, in: RoundedRectangle(cornerRadius: 12))
                        }

                        if draft.evidence.isEmpty {
                            Text("这里先不列依据。如果你愿意，再多写一句也可以。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                AITaskCard(
                    ai: ai,
                    task: .dailyOverview,
                    buttonTitle: "AI 整理这一天",
                    emptyMessage: "AI 会读取当天日记、快记和实时片段，生成一段可编辑的本日概览。"
                ) {
                    Task { await ai.generateDailyOverview(entry: entry, quickCaptures: captures, activitySessions: activity.liveSessions(for: selectedDate)) }
                } trailing: {
                    if let answer = ai.state(for: .dailyOverview)?.answer {
                        Button("写入编辑框") {
                            editedDraft = answer
                            isEditing = true
                        }
                        .buttonStyle(.plain)
                        .smallAction(dark: true)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: draftBandColors,
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: 4)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .frame(maxWidth: 1280)
    }

    private var draftBandColors: [Color] {
        switch draft.mood {
        case ..<39: [Color(hex: "#7FB3FF"), Color(hex: "#A5C6FF")]
        case ..<63: [Color(hex: "#7F83FF"), Color(hex: "#9F9CFF")]
        default: [Color(hex: "#FF8FB3"), Color(hex: "#FFC5D7")]
        }
    }

    private var confidence: some View {
        HStack(spacing: 5) {
            Image(systemName: draft.confidence >= 72 ? "checkmark.seal.fill" : draft.confidence >= 45 ? "questionmark.circle.fill" : "exclamationmark.circle.fill")
            Text("参考度 \(draft.confidence)%")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(draft.confidence >= 72 ? Color(hex: "#2C8158") : draft.confidence >= 45 ? Color.secondaryInk : Color(hex: "#B26B00"))
        .help(draft.confidenceFactors.joined(separator: "\n"))
    }

    private var projectSignalsCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("当天自动记录", systemImage: "waveform.path.ecg")
                        .font(.headline)
                    Spacer()
                    StatusBadge(
                        entry.hasProjectSignals ? "来自项目数据" : "等待当天记录",
                        tone: entry.hasProjectSignals ? .positive : .neutral
                    )
                }

                if !entry.hasProjectSignals {
                    Text("今天还没有屏幕或运动数据。已有的日记文字仍会进入草稿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    EqualWidthRow(spacing: 10) {
                        if let minutes = entry.screenMinutes {
                            signal("屏幕", ActivityFormatter.time(Double(minutes) * 60), "display")
                        }
                        if let steps = entry.health?.steps {
                            signal("步数", "\(steps)", "figure.walk")
                        }
                        if let distance = entry.health?.distanceKM {
                            signal("距离", String(format: "%.2f km", distance), "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        if let energy = entry.health?.activeEnergyKcal {
                            signal("活动热量", String(format: "%.1f kcal", energy), "flame.fill")
                        }
                    }

                    if let apps = entry.screenApps, !apps.isEmpty {
                        let sortedApps = apps.sorted { ($0.minutes ?? 0) > ($1.minutes ?? 0) }
                        let maxMinutes = max(1, sortedApps.first?.minutes ?? 1)
                        VStack(alignment: .leading, spacing: 9) {
                            Text("屏幕应用 · 按时长排序")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(sortedApps.prefix(5), id: \.app) { app in
                                HStack(spacing: 10) {
                                    AppIconBadge(app: app.app, size: 26)
                                    Text(app.app)
                                        .font(.caption)
                                        .frame(width: 118, alignment: .leading)
                                    ProgressBar(value: max(0, Double(app.minutes ?? 0) / Double(maxMinutes) * 100))
                                    Text(app.minutes.map { ActivityFormatter.time(Double($0) * 60) } ?? app.time ?? "")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let sites = entry.browseSites, !sites.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("浏览足迹")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 7) {
                                ForEach(sites.sorted { ($0.visits ?? 0) > ($1.visits ?? 0) }.prefix(5), id: \.site) { site in
                                    HStack(spacing: 6) {
                                        SiteIconBadge(site: site.site, size: 20)
                                        Text("\(site.site) · \(site.visits ?? 0)")
                                            .font(.caption2)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(Color.chip, in: Capsule())
                                }
                            }
                        }
                    }

                    if entry.screenNote != nil || entry.browseNote != nil {
                        VStack(alignment: .leading, spacing: 7) {
                            if let note = entry.screenNote, !note.isEmpty {
                                observation(note)
                            }
                            if let note = entry.browseNote, !note.isEmpty {
                                observation(note)
                            }
                        }
                        .padding(13)
                        .background(Color.chip, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
        }
    }

    private func signal(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.secondaryInk)
                .frame(width: 26, height: 26)
                .background(Color.chip, in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 18))
    }

    private func observation(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(text)
                .font(.caption)
                .lineSpacing(5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickCaptureCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("菜单栏快记", systemImage: "tray.full")
                        .font(.headline)
                    Spacer()
                    Text("就写一句也行").font(.caption).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 10) {
                    TextField("就写一句也行；链接、待办、想法都可以", text: $quickCaptureText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .padding(13)
                        .background(Color.editor, in: RoundedRectangle(cornerRadius: 13))
                        .onSubmit(addQuickCapture)

                    Button("保留", action: addQuickCapture)
                        .buttonStyle(.plain).smallAction(dark: true)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(["想法", "待办", "链接", "身体"], id: \.self) { tag in
                            Button {
                                quickCaptureTag = quickCaptureTag == tag ? nil : tag
                            } label: {
                                Text(tag)
                                    .font(.caption.weight(quickCaptureTag == tag ? .semibold : .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                                    .background(quickCaptureTag == tag ? Color.ctaBackground : Color.chip, in: Capsule())
                                    .foregroundStyle(quickCaptureTag == tag ? Color.ctaText : Color.secondaryInk)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider().frame(height: 14)

                        Button("记一件事") { applyTemplate("我想记一件事：") }
                            .buttonStyle(.plain).smallAction()
                        Button("先睡一觉") { applyTemplate("刚才累了一下，先睡一觉。") }
                            .buttonStyle(.plain).smallAction()
                        Button("补昨天") {
                            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) ?? selectedDate
                            store.addQuickCapture(quickCaptureText, tag: quickCaptureTag, for: yesterday)
                            quickCaptureText = ""
                            quickCaptureTag = nil
                            loadDraft()
                        }
                            .buttonStyle(.plain).smallAction()
                            .disabled(quickCaptureText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)

                if captures.isEmpty {
                    Text("现在还没有快记。哪天只留一句话，也很好。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(captures) { capture in
                        let isPinned = capture.isPinned ?? false
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "quote.opening")
                                .font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(capture.text).font(.caption).lineSpacing(4)
                                HStack(spacing: 5) {
                                    if let tag = capture.tag {
                                        Text(tag)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.ctaBackground, in: Capsule())
                                            .foregroundStyle(Color.ctaText)
                                    }
                                    Text(capture.createdAt.formatted(date: .omitted, time: .shortened) + " · " + capture.source)
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button {
                                store.setQuickCapturePinned(capture, entry: entry, pinned: !isPinned)
                            } label: {
                                Image(systemName: isPinned ? "pin.fill" : "pin")
                                    .foregroundStyle(isPinned ? Color.ctaText : Color.secondary)
                            }
                            .buttonStyle(.plain).font(.caption2)
                            .help(isPinned ? "取消置顶" : "置顶这条快记")

                            Button {
                                store.removeQuickCapture(capture, entry: entry)
                                loadDraft()
                            } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).font(.caption2)
                        }
                        .padding(11)
                        .background(isPinned ? Color.ctaBackground.opacity(0.24) : Color.chip, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            if isPinned {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.ctaBackground.opacity(0.55), lineWidth: 1)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private func addQuickCapture() {
        store.addQuickCapture(quickCaptureText, tag: quickCaptureTag, for: selectedDate)
        quickCaptureText = ""
        quickCaptureTag = nil
        loadDraft()
    }

    private func applyTemplate(_ template: String) {
        if quickCaptureText.isEmpty {
            quickCaptureText = template
        } else if !quickCaptureText.hasPrefix(template) {
            quickCaptureText = template + quickCaptureText
        }
    }

    private var fineTuneCard: some View {
        SoftCard {
            DisclosureGroup(isExpanded: $showsFineTune) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) {
                        ForEach(["随想", "工作", "身心", "休息"], id: \.self) { item in
                            Button(item) { selectedCategory = item }
                                .font(.caption.weight(.medium))
                                .foregroundStyle(selectedCategory == item ? Color.ctaText : Color.secondaryInk)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(selectedCategory == item ? Color.ink : Color.chip, in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }

                    slider("心情", $mood)
                    slider("专注", $focus)
                    slider("产出", $output)
                    slider("精力", $energy)

                    ProgressBar(value: Double(overall))

                    Text("通常不用动。它若读得不太像你，就轻轻调一下。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.top, 14)
            } label: {
                HStack {
                    Label("整理不准时调整", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Text("可选").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
            Slider(value: value, in: 0...100).tint(Color.ink)
            Text("\(Int(value.wrappedValue))").font(.caption.weight(.semibold)).frame(width: 26, alignment: .trailing)
        }
    }
}
