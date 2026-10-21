import SwiftUI

struct HealthWorkspaceView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    @ObservedObject var location: LocationSourceStore
    let entry: DiaryEntry
    var onOpenSources: () -> Void
    @State private var moodDraft: MoodScoreDraft
    @State private var moodError: String?
    @State private var showsHealthDetails = false

    init(
        store: DiaryStore,
        activity: ActivityStore,
        ingestion: DataIngestionStore,
        location: LocationSourceStore,
        entry: DiaryEntry,
        onOpenSources: @escaping () -> Void
    ) {
        self.store = store
        self.activity = activity
        self.ingestion = ingestion
        self.location = location
        self.entry = entry
        self.onOpenSources = onOpenSources
        _moodDraft = State(initialValue: MoodScoreDraft(persistedValue: entry.metrics?.mood.map { Int($0.rounded()) }))
    }

    private var stats: FusedDayStats {
        activity.dayStats(entries: [entry], date: entry.entryDate ?? Date())
    }

    var body: some View {
        RiverPage {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                PageHeader("健康", context: entry.shortDate) {
                    Button("查看数据源", action: onOpenSources)
                        .buttonStyle(.plain)
                        .smallAction()
                }
                .riverAppear(index: 0)

                if entry.health == nil {
                    RiverPanel(title: "健康摘要", systemImage: "heart", accent: AppTheme.accent) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("健康数据默认只留在 iPhone 本机，不进入跨设备复制。这里只显示你手动导入或旧版已有的摘要；你也可以先记录自己的心情。")
                                .font(AppTypography.secondary()).foregroundStyle(Color.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("管理数据来源", action: onOpenSources).secondaryCTA()
                        }
                    }
                } else {
                RiverPanel(title: "今日状态", systemImage: "heart.text.square", accent: AppTheme.accent, tint: AppTheme.accent) {
                    HStack(spacing: 0) {
                        HealthMetric(title: "睡眠", value: entry.health?.resolvedSleepHours.map { "\($0.formatted(.number.precision(.fractionLength(1))))h" } ?? "未知", detail: "缺失不按零计算")
                        HealthMetric(title: "步数", value: entry.health?.steps.map(String.init) ?? "未知", detail: "设备测量")
                        HealthMetric(title: "活动", value: entry.health?.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "未知", detail: "设备测量")
                        HealthMetric(title: "心情", value: entry.metrics?.mood.map { "\(Int($0.rounded()))" } ?? "未知", detail: "用户记录")
                    }
                }
                .riverAppear(index: 1)
                }


                moodEditor
                    .riverAppear(index: 2)

                DisclosureGroup("数据来源与明细", isExpanded: $showsHealthDetails) {
                    VStack(spacing: AppSpacing.panelGap) {
                SourceHealthPanel(
                    items: SourceHealthBuilder.make(
                        pipelineEnabled: ingestion.enabled,
                        pipelineRunning: ingestion.isRunning,
                        pipelineError: ingestion.lastError,
                        lastIngestedAt: ingestion.lastIngestedAt,
                        lastStatus: ingestion.lastStatus,
                        liveTracking: activity.isTracking,
                        liveSessionCount: activity.sessions.count,
                        healthAvailable: entry.health != nil,
                        locationState: location.statusState,
                        locationDetail: location.statusDetail
                    ),
                    onOpenSettings: onOpenSources
                )
                .riverAppear(index: 3)

                RiverPanel(title: "证据明细", systemImage: "list.bullet.rectangle", accent: AppTheme.accent) {
                    VStack(spacing: 0) {
                        healthEvidenceRow("睡眠", value: sleepValue, source: sleepSource)
                        healthEvidenceRow("步数", value: entry.health?.steps.map(String.init) ?? "未知", source: entry.health?.steps == nil ? "未同步" : "iOS Health")
                        healthEvidenceRow("活动热量", value: entry.health?.activeEnergyKcal.map { "\(Int($0)) kcal" } ?? "未知", source: entry.health?.activeEnergyKcal == nil ? "未同步" : "iOS Health")
                        healthEvidenceRow("心情", value: entry.metrics?.mood.map { "\(Int($0.rounded())) / 100" } ?? "未知", source: entry.metrics?.mood == nil ? "未记录" : "日记记录", showsDivider: false)
                    }
                }
                .riverAppear(index: 4)

                RiverPanel(title: "边界", systemImage: "info.circle", accent: AppTheme.warning) {
                    SettingsFootnote(text: "健康数据只描述已采集的测量和用户主动记录，不生成医学判断。AI 解释不可用时，原始测量仍然保留。")
                }
                .riverAppear(index: 5)
                    }.padding(.top, 14)
                }.font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)

            }
        }
        .onChange(of: entry.date) { _, _ in
            moodDraft = MoodScoreDraft(persistedValue: entry.metrics?.mood.map { Int($0.rounded()) })
            moodError = nil
        }
        .onChange(of: entry.metrics?.mood) { _, newValue in
            moodDraft.synchronizePersistedValue(newValue.map { Int($0.rounded()) })
        }
        .onKeyPress(.escape) {
            guard moodDraft.isEditing else { return .ignored }
            resetMoodDraft()
            return .handled
        }
    }

    private var moodEditor: some View {
        RiverPanel(title: "心情记录", systemImage: "face.smiling", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(9)) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(moodDraft.isAwaitingSelection ? "选择心情评分" : moodDraft.value.map { "主观评分 · \($0) / 100" } ?? "还没有心情评分")
                            .font(AppTypography.sectionTitle())
                            .foregroundStyle(Color.ink)
                        Text("仅记录你的主观感受，不用于医学判断。")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                    }
                    Spacer()
                    if moodDraft.persistedValue == nil && !moodDraft.isEditing {
                        Button("记录心情") {
                            moodDraft.beginRecording()
                            moodError = nil
                        }
                        .primaryCTA()
                    }
                }

                if moodDraft.showsEditor {
                    Slider(value: moodBinding, in: 0...100, step: 1, onEditingChanged: { isEditing in
                        if isEditing { moodDraft.confirmCurrentValue() }
                    })
                        .accessibilityLabel("主观心情评分")
                        .accessibilityValue(moodDraft.isAwaitingSelection
                            ? "尚未选择，初始位置 \(Int(moodDraft.sliderValue)) 分"
                            : "\(moodDraft.value ?? Int(moodDraft.sliderValue)) 分")

                    HStack {
                        Text("0 · 低").font(AppTypography.metadata()).foregroundStyle(Color.tertiaryInk)
                        Spacer()
                        Text("100 · 高").font(AppTypography.metadata()).foregroundStyle(Color.tertiaryInk)
                    }

                    if moodDraft.isAwaitingSelection {
                        Text("默认位置仅供参考；调整或确认滑块后才能保存。")
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                    }

                    if moodDraft.isEditing {
                        HStack {
                            Button("取消") { resetMoodDraft() }
                                .buttonStyle(.plain)
                                .smallAction()
                                .keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("保存评分", action: saveMood)
                                .primaryCTA()
                                .disabled(!moodDraft.canSave)
                        }
                    }
                }

                if let moodError {
                    Text(moodError)
                        .font(AppTypography.metadata())
                        .foregroundStyle(AppTheme.error)
                }
            }
        }
    }

    private var moodBinding: Binding<Double> {
        Binding(
            get: { moodDraft.sliderValue },
            set: { value in
                moodDraft.select(value)
                moodError = nil
            }
        )
    }

    private func resetMoodDraft() {
        moodDraft.cancel()
        moodError = nil
    }

    private func saveMood() {
        guard moodDraft.canSave, let score = moodDraft.value else { return }
        do {
            try store.saveWriting(entry: entry, text: store.overview(for: entry), mood: score)
            moodDraft.markSaved()
            moodError = nil
        } catch {
            moodError = "评分保存失败：\(UserFacingError.message(for: error))"
        }
    }

    private var sleepValue: String {
        entry.health?.resolvedSleepHours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) 小时" } ?? "未知"
    }

    private var sleepSource: String {
        entry.health?.resolvedSleepHours == nil ? "未同步" : "iOS Health"
    }

    private func healthEvidenceRow(_ title: String, value: String, source: String, showsDivider: Bool = true) -> some View {
        RiverValueRow(
            title: title,
            value: value,
            detail: source,
            valueTint: source == "未同步" || source == "未记录" ? Color.secondaryInk : AppTheme.accent,
            showsDivider: showsDivider
        )
    }
}

struct MoodScoreDraft: Equatable {
    private(set) var value: Int?
    private(set) var persistedValue: Int?
    private(set) var isEditing = false
    private(set) var hasExplicitSelection = false

    var sliderValue: Double { Double(value ?? 50) }
    var showsEditor: Bool { value != nil || isEditing }
    var isAwaitingSelection: Bool { isEditing && persistedValue == nil && !hasExplicitSelection }
    var canSave: Bool { isEditing && hasExplicitSelection && value != nil && value != persistedValue }

    init(persistedValue: Int?) {
        self.value = persistedValue
        self.persistedValue = persistedValue
    }

    mutating func beginRecording() {
        guard persistedValue == nil else { return }
        value = 50
        isEditing = true
        hasExplicitSelection = false
    }

    mutating func confirmCurrentValue() {
        guard isEditing || value != nil else { return }
        isEditing = true
        hasExplicitSelection = true
    }

    mutating func select(_ value: Double) {
        self.value = min(100, max(0, Int(value.rounded())))
        isEditing = true
        hasExplicitSelection = true
    }

    mutating func cancel() {
        value = persistedValue
        isEditing = false
        hasExplicitSelection = false
    }

    mutating func markSaved() {
        guard canSave else { return }
        persistedValue = value
        isEditing = false
        hasExplicitSelection = false
    }

    mutating func synchronizePersistedValue(_ newValue: Int?) {
        guard !isEditing else { return }
        value = newValue
        persistedValue = newValue
        hasExplicitSelection = false
    }
}

private struct HealthMetric: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        RiverStat(title: title, value: value, detail: detail, valueFont: AppTypography.metricSmall())
    }
}
