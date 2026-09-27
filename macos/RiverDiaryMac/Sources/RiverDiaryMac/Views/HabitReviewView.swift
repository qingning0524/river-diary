import SwiftUI

// MARK: - 习惯回顾页
//
// 跨天习惯由 AI 基于已持久化的全天时间线理解生成自然交流；
// 卡片展示观察与来源，始终提供自由输入，模型生成的快捷回复仅作提示。
// 用户明确确认规则后才保存；宽窗右侧展开来源，规则可在本页撤销。

struct HabitReviewView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var habit: HabitReviewStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore = AIAssistantStore()
    var onOpenTimeline: () -> Void = {}
    /// 离屏渲染（ImageRenderer）不触发 onAppear，入场动画会把初态的透明内容拍下来；
    /// 渲染测试传 false 直接取最终状态。
    var animatesEntrance = true

    @State private var evidenceCardID: UUID?

    /// 依据栏出现的最小内容宽度（主列 + 间距 + 栏宽）。
    private let railWidth: CGFloat = 280

    @ViewBuilder
    private func entrance<Content: View>(_ content: Content, index: Int) -> some View {
        if animatesEntrance {
            content.riverAppear(index: index)
        } else {
            content
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let showsRail = geometry.size.width >= 980 + railWidth + AppSpacing.panelGap
            RiverPage(maxWidth: showsRail ? 980 + railWidth + AppSpacing.panelGap : AppLayout.contentMaxWidth) {
                PageHeader(
                    "习惯回顾",
                    context: "我会结合每天的记录，慢慢学会怎样更懂你。"
                ) {
                    HabitCadenceMenu(store: habit, showsChevron: true)
                }

                HStack(alignment: .top, spacing: density.spacing(AppSpacing.panelGap)) {
                    mainColumn(showsRail: showsRail)
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                    if showsRail {
                        entrance(railColumn.frame(width: railWidth, alignment: .topLeading), index: 2)
                    }
                }
            }
        }
        .task {
            await habit.evaluateWithAIIfNeeded(ai: ai, allowManualGeneration: true)
            habit.markBatchShownIfFirstOpen()
        }
    }

    // MARK: 主列

    @ViewBuilder
    private func mainColumn(showsRail: Bool) -> some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
            if let batch = habit.currentBatch, !habit.pendingCards.isEmpty {
                overviewPanel(batch)
            }
            if !rememberedRules.isEmpty || !legacyRules.isEmpty {
                rememberedHabitsPanel
            }
            if habit.pendingCards.isEmpty {
                emptyStatePanel
            }

            ForEach(Array(displayedCards.enumerated()), id: \.element.id) { index, card in
                entrance(
                    HabitReviewCardView(
                        card: card,
                        positionText: positionText(for: card, index: index),
                        showsInlineEvidence: evidenceCardID == card.id,
                        isResponding: habit.respondingCardIDs.contains(card.id),
                        errorText: habit.lastError,
                        onSendMessage: { message in
                            Task { await habit.sendMessage(message, to: card, using: ai) }
                        },
                        onAcceptRuleSuggestion: {
                            if let current = habit.cards.first(where: { $0.id == card.id }) {
                                habit.acceptRuleSuggestion(for: current)
                            }
                        },
                        onUndo: {
                            if let current = habit.cards.first(where: { $0.id == card.id }) {
                                habit.undoAnswer(current)
                            }
                        },
                        onToggleEvidence: {
                            withAnimation(.easeOut(duration: AppMotion.quick)) {
                                evidenceCardID = evidenceCardID == card.id ? nil : card.id
                            }
                        },
                        onOpenTimeline: onOpenTimeline
                    ),
                    index: min(index + 1, 3)
                )
            }

            footerNote
            if !showsRail {
                HabitRhythmPanel(store: habit)
            }
        }
    }

    private var rememberedRules: [HabitPersonalRule] {
        habit.rules.filter { $0.status == .active && $0.origin == .userConfirmed && $0.naturalLanguageRule != nil }
            .sorted { $0.validFrom > $1.validFrom }
    }

    private var legacyRules: [HabitPersonalRule] {
        habit.rules.filter { $0.status == .active && $0.origin == .userConfirmed && $0.naturalLanguageRule == nil }
            .sorted { $0.validFrom > $1.validFrom }
    }

    /// 展示顺序：待答的在前（第 1 题 / 共 n 题），已处理的按原位收在后面。
    private var displayedCards: [HabitReviewCard] {
        guard let batch = habit.currentBatch else { return [] }
        let ids = Set(batch.cardIDs)
        let batchCards = habit.cards.filter { ids.contains($0.id) && $0.status != .expired }
        let pending = batchCards.filter(\.isPending)
        let settled = batchCards.filter { !$0.isPending }
        return pending + settled
    }

    private func positionText(for card: HabitReviewCard, index: Int) -> String? {
        guard card.isPending, let batch = habit.currentBatch else { return nil }
        let ids = Set(batch.cardIDs)
        let pending = habit.cards.filter { ids.contains($0.id) && $0.isPending }
        guard let position = pending.firstIndex(where: { $0.id == card.id }) else { return nil }
        return "第 \(position + 1) 个观察 / 共 \(pending.count) 个"
    }

    private func overviewPanel(_ batch: HabitReviewBatch) -> some View {
        let pendingCount = habit.pendingCards.count
        // 已答/过期都只统计本批次的卡：habit.cards 是全部历史，
        // 旧批次的过期卡不该稀释本批的进度。
        let batchCardIDs = Set(batch.cardIDs)
        let batchCards = habit.cards.filter { batchCardIDs.contains($0.id) }
        let answeredCount = max(0, batchCards.count { !$0.isPending })
        let title = answeredCount > 0 ? "还有 \(pendingCount) 件我想和你聊聊" : batch.introTitle
        return RiverPanel(padding: AppSpacing.panelPadding) {
            HStack(alignment: .center, spacing: density.spacing(AppSpacing.md)) {
                RiverIconWell(systemImage: "sparkles", tint: AppTheme.accent, size: 36)
                VStack(alignment: .leading, spacing: density.spacing(3)) {
                    Text(title)
                        .font(AppTypography.sectionTitle())
                        .foregroundStyle(Color.ink)
                    Text(batch.introDetail)
                        .font(AppTypography.label())
                        .foregroundStyle(Color.secondaryInk)
                }
                Spacer(minLength: density.spacing(AppSpacing.sm))
                Text("可以慢慢聊")
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
            }
        }
        .modifier(HabitPanelEntrance(animates: animatesEntrance))
    }

    private var emptyStatePanel: some View {
        RiverPanel(padding: AppSpacing.panelPadding) {
            VStack(alignment: .leading, spacing: density.spacing(10)) {
                EmptyStateView(
                    title: ai.analysisReady ? "我还没有发现值得打扰你的新问题" : "连接模型后，我可以更懂你的日常",
                    message: emptyStateMessage,
                    symbol: "sparkles"
                )
            }
        }
        .modifier(HabitPanelEntrance(animates: animatesEntrance))
    }

    private var emptyStateMessage: String {
        if !ai.analysisReady {
            return "接入 AI 后，我会结合时间线和你确认过的习惯，理解每天发生的事；有真正值得确认的模式时再来和你聊。"
        }
        if let error = habit.lastError { return error }
        if let next = habit.nextReviewText {
            return "我会继续留意新的活动脉络，不重复问已经熟悉的情境。下一次回顾在 \(next)。"
        }
        return "我会继续理解每天的活动；出现值得记住的新模式时，再和你聊。"
    }

    private var rememberedHabitsPanel: some View {
        RiverPanel(title: "我记住的你", systemImage: "heart.text.square", detail: "这些理解会帮助我整理以后相似的日子", accent: AppTheme.accent) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                ForEach(Array(rememberedRules.prefix(4))) { rule in
                    HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(AppTheme.accent)
                            .padding(.top, 3)
                        Text(rule.naturalLanguageRule ?? rule.scopeText)
                            .font(AppTypography.secondary())
                            .foregroundStyle(Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: density.spacing(AppSpacing.xs))
                        Button("不再记") { habit.retireRule(rule) }
                            .buttonStyle(.plain)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                }
                if !legacyRules.isEmpty {
                    if !rememberedRules.isEmpty { RiverRule(color: Color.border.opacity(0.6)) }
                    Text("旧版按应用确认的归类只作参考，我不会单凭应用名判断用途。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                    ForEach(Array(legacyRules.prefix(4))) { rule in
                        HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                            Text("\(rule.conditionAppName) → \(rule.conclusionCategory)")
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.tertiaryInk)
                            Spacer(minLength: density.spacing(AppSpacing.xs))
                            Button("停用") { habit.retireRule(rule) }
                                .buttonStyle(.plain)
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.tertiaryInk)
                        }
                    }
                }
            }
        }
    }

    private var footerNote: some View {
        Text("我会基于真实记录分享观察；你可以自由补充或纠正，已记住的内容也可以撤销。")
            .font(AppTypography.metadata())
            .foregroundStyle(Color.tertiaryInk)
    }

    // MARK: 右栏

    @ViewBuilder
    private var railColumn: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
            if let card = habit.pendingCards.first {
                HabitEvidencePanel(card: card, onOpenTimeline: onOpenTimeline)
            }
            HabitRhythmPanel(store: habit)
        }
    }
}

// MARK: - 问题卡

struct HabitReviewCardView: View {
    @Environment(\.riverDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let card: HabitReviewCard
    var positionText: String?
    var showsInlineEvidence: Bool
    var isResponding = false
    var errorText: String?
    var onSendMessage: (String) -> Void
    var onAcceptRuleSuggestion: () -> Void
    var onUndo: () -> Void
    var onToggleEvidence: () -> Void
    var onOpenTimeline: () -> Void
    @State private var customText = ""

    var body: some View {
        RiverPanel {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                headerRow
                questionBlock
                exampleWell

                if card.isPending {
                    conversationBlock
                    if let suggestion = card.ruleSuggestion, !suggestion.isEmpty {
                        ruleSuggestionBlock(suggestion)
                    }
                    evidenceFooter
                    if showsInlineEvidence {
                        evidenceList
                            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .move(edge: .top)))
                    }
                } else {
                    if !(card.conversation ?? []).isEmpty {
                        conversationTranscript
                    }
                    answeredBlock
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: density.spacing(AppSpacing.sm)) {
            Text(card.kind.badgeText)
                .font(AppTypography.micro().weight(.semibold))
                .foregroundStyle(AppTheme.accent)
                .padding(.horizontal, density.spacing(AppSpacing.sm + 2))
                .padding(.vertical, density.spacing(4))
                .background(AppTheme.accentSoft, in: Capsule())
            Spacer(minLength: density.spacing(AppSpacing.sm))
            if let positionText {
                Text(positionText)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.tertiaryInk)
            }
        }
    }

    private var questionBlock: some View {
        VStack(alignment: .leading, spacing: density.spacing(5)) {
            Text(card.question)
                .font(AppTypography.sheetTitle())
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.lead)
                .font(AppTypography.label())
                .foregroundStyle(Color.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// “AI 整理的例子”：浅底上一行 2–3 个不同日期的紧凑例子。
    @ViewBuilder
    private var exampleWell: some View {
        let contextExamples = card.contextExamples ?? []
        if !contextExamples.isEmpty {
            VStack(alignment: .leading, spacing: density.spacing(6)) {
                Text("我参考了这些日子")
                    .font(AppTypography.micro().weight(.semibold))
                    .foregroundStyle(Color.tertiaryInk)
                ForEach(contextExamples) { example in
                    HStack(alignment: .top, spacing: density.spacing(AppSpacing.sm)) {
                        Text(example.dateText)
                            .font(AppTypography.metadata().monospacedDigit())
                            .foregroundStyle(Color.secondaryInk)
                            .frame(width: 42, alignment: .leading)
                        VStack(alignment: .leading, spacing: density.spacing(2)) {
                            Text([example.timeText, example.title].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(AppTypography.label().weight(.semibold))
                                .foregroundStyle(Color.ink)
                            Text(example.summary)
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(density.spacing(AppSpacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: density.spacing(6)) {
                Text("AI 整理的例子")
                    .font(AppTypography.micro().weight(.semibold))
                    .foregroundStyle(Color.tertiaryInk)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(card.examples.enumerated()), id: \.element.id) { index, example in
                        HabitExampleCell(example: example)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if index < card.examples.count - 1 {
                            Divider()
                                .frame(height: 34)
                        }
                    }
                }
            }
            .padding(density.spacing(AppSpacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        }
    }

    private var conversationBlock: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            conversationTranscript

            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                TextField("用你自己的话告诉我……", text: $customText, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.plain)
                    .font(AppTypography.secondary())
                    .padding(density.spacing(AppSpacing.sm))
                    .background(Color.editor, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
                    .onSubmit(sendCustomText)
                    .accessibilityLabel("用自己的话补充或纠正 AI 的理解")
                HStack {
                    Text("你可以补充、纠正，也可以解释这段时间的例外。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                    Spacer()
                    Button(isResponding ? "正在理解…" : "发送") { sendCustomText() }
                        .primaryCTA()
                        .disabled(isResponding || customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let suggestions = card.suggestedReplies ?? []
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: density.spacing(4)) {
                    Text("也可以从这些说法开始")
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.tertiaryInk)
                    ChipFlow(spacing: AppSpacing.xs) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { item in
                            Button(item.element) {
                                onSendMessage(item.element)
                            }
                            .buttonStyle(.plain)
                            .font(AppTypography.metadata())
                            .foregroundStyle(Color.secondaryInk)
                            .padding(.horizontal, density.spacing(AppSpacing.sm))
                            .padding(.vertical, density.spacing(6))
                            .background(Color.chip, in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private var conversationTranscript: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
            ForEach(card.conversation ?? []) { turn in
                HStack {
                    if turn.role == .assistant { Spacer(minLength: 30) }
                    Text(turn.text)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.ink)
                        .padding(density.spacing(AppSpacing.sm))
                        .background(
                            turn.role == .user ? AppTheme.accentSoft : Color.chip,
                            in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        )
                    if turn.role == .user { Spacer(minLength: 30) }
                }
            }
        }
    }

    private func sendCustomText() {
        let message = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isResponding else { return }
        onSendMessage(message)
        customText = ""
    }

    private func ruleSuggestionBlock(_ suggestion: String) -> some View {
        RiverPanel(padding: AppSpacing.panelPadding) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                Text("我可以这样记住")
                    .font(AppTypography.label().weight(.semibold))
                    .foregroundStyle(Color.secondaryInk)
                Text(suggestion)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("记住这点") { onAcceptRuleSuggestion() }
                        .primaryCTA()
                    Text("只在你确认后，才会用于以后类似情境。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                }
            }
        }
    }

    private var evidenceFooter: some View {
        HStack(alignment: .center) {
            Button {
                onToggleEvidence()
            } label: {
                Text(showsInlineEvidence ? "收起依据" : "查看全部依据 ↗")
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.accent)
            }
            .buttonStyle(.plain)
            Spacer(minLength: density.spacing(AppSpacing.sm))
            Text("回答会用于改进后续理解 · 可撤销")
                .font(AppTypography.metadata())
                .foregroundStyle(Color.tertiaryInk)
        }
    }

    /// 已回答状态：原位收起，保留问题与结果，撤销就在同一行。
    private var answeredBlock: some View {
        HStack(alignment: .center, spacing: density.spacing(AppSpacing.sm)) {
            Image(systemName: card.answerKind == .skip ? "clock.arrow.circlepath" : "checkmark.circle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(card.answerKind == .skip ? AppTheme.neutral : AppTheme.ok)
            VStack(alignment: .leading, spacing: density.spacing(2)) {
                Text(card.answerKind == .skip ? "已记下，暂时不打扰" : (card.answerKind == .longTermRule ? "我会记住这条习惯" : "这段交流已整理"))
                    .font(AppTypography.rowTitle())
                    .foregroundStyle(Color.ink)
                if let scope = card.answerScopeText {
                    Text(scope)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
            }
            Spacer(minLength: density.spacing(AppSpacing.sm))
            Button("撤销", action: onUndo)
                .buttonStyle(.plain)
                .font(AppTypography.metadata())
                .foregroundStyle(AppTheme.accent)
                .accessibilityLabel("撤销这条回答")
        }
        .padding(density.spacing(AppSpacing.md))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private var evidenceList: some View {
        HabitEvidenceSections(sections: card.evidence, onOpenTimeline: onOpenTimeline)
            .padding(.top, density.spacing(AppSpacing.xxs))
    }
}

/// 一个例子的紧凑单元：日期 · 时长，地点 · 应用。
struct HabitExampleCell: View {
    @Environment(\.riverDensity) private var density
    let example: HabitExample

    var body: some View {
        HStack(alignment: .center, spacing: density.spacing(AppSpacing.sm)) {
            Image(systemName: ActivityClassifier.symbol(for: example.appName))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 22, height: 22)
                .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: density.spacing(1)) {
                Text("\(example.dateText) · \(example.durationText)")
                    .font(AppTypography.label().weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text("\(example.placeSummary) · \(example.appName)")
                    .font(AppTypography.micro())
                    .foregroundStyle(Color.secondaryInk)
                    .lineLimit(1)
            }
        }
        .padding(.trailing, density.spacing(AppSpacing.md))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 依据

/// 依据各节：地点 → 活动 → 仍不确定。
struct HabitEvidenceSections: View {
    @Environment(\.riverDensity) private var density
    let sections: [HabitEvidenceSection]
    var onOpenTimeline: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: density.spacing(3)) {
                    Text(section.title)
                        .font(AppTypography.label().weight(.semibold))
                        .foregroundStyle(Color.secondaryInk)
                    Text(section.headline)
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(section.footnote)
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                }
                .padding(.vertical, density.spacing(AppSpacing.sm + 2))
                if index < sections.count - 1 {
                    RiverRule(color: Color.border.opacity(0.6))
                }
            }
            Button("到时间线查看这些记录 ↗", action: onOpenTimeline)
                .buttonStyle(.plain)
                .font(AppTypography.metadata())
                .foregroundStyle(AppTheme.accent)
                .padding(.top, density.spacing(AppSpacing.sm))
        }
    }
}

/// 宽窗右栏的依据面板。
struct HabitEvidencePanel: View {
    @Environment(\.riverDensity) private var density
    let card: HabitReviewCard
    var onOpenTimeline: () -> Void

    var body: some View {
        RiverPanel(padding: AppSpacing.panelPadding) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.md)) {
                HStack(alignment: .center, spacing: density.spacing(AppSpacing.sm)) {
                    RiverIconWell(systemImage: "magnifyingglass", tint: AppTheme.accent, size: 32)
                    Text("这条问题的依据")
                        .font(AppTypography.sectionTitle())
                        .foregroundStyle(Color.ink)
                }
                RiverRule(color: Color.border.opacity(0.6))
                HabitEvidenceSections(sections: card.evidence, onOpenTimeline: onOpenTimeline)
            }
        }
    }
}

// MARK: - 节奏

/// 回顾节奏菜单：页头胶囊与节奏面板共用一份选项。
struct HabitCadenceMenu: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: HabitReviewStore
    var showsChevron = false

    var body: some View {
        Menu {
            Section("回顾节奏") {
                ForEach(HabitReviewCadence.allCases) { option in
                    Button {
                        store.setCadence(option)
                    } label: {
                        if option == store.cadence {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }
            Section("提醒时间") {
                ForEach(HabitReviewTimePreset.allCases) { preset in
                    Button {
                        store.setTimePreset(preset)
                    } label: {
                        if preset == store.timePreset {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            }
        } label: {
            if showsChevron {
                HStack(spacing: density.spacing(AppSpacing.sm)) {
                    Text("回顾节奏 · \(cadenceLine)")
                        .font(AppTypography.label().weight(.semibold))
                        .foregroundStyle(Color.secondaryInk)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.tertiaryInk)
                }
                .padding(.horizontal, density.spacing(AppSpacing.md))
                .frame(minHeight: density.spacing(34))
                .background(Color.surface, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                        .strokeBorder(Color.border, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
            } else {
                Text("更改频率 ↗")
                    .font(AppTypography.metadata())
                    .foregroundStyle(AppTheme.accent)
                    .contentShape(Rectangle())
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(showsChevron ? .hidden : .visible)
        .fixedSize()
        .accessibilityLabel("更改回顾节奏，当前\(cadenceLine)")
    }

    private var cadenceLine: String {
        switch store.cadence {
        case .weekly: "每周日 \(shortTime)"
        case .everyThreeDays: "每 3 天 \(shortTime)"
        case .monthly: "每月末 \(shortTime)"
        case .smart: "智能积累"
        case .manual: "仅手动"
        }
    }

    private var shortTime: String {
        Self.clockText(for: store.timePreset)
    }

    static func clockText(for preset: HabitReviewTimePreset) -> String {
        switch preset {
        case .morning: "9:00"
        case .afternoon: "14:00"
        case .evening: "20:00"
        }
    }
}

/// 节奏面板（右栏或窄窗底部）。
struct HabitRhythmPanel: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: HabitReviewStore

    var body: some View {
        RiverPanel(padding: AppSpacing.panelPadding) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.sm)) {
                HStack(alignment: .center, spacing: density.spacing(AppSpacing.sm)) {
                    RiverIconWell(systemImage: "clock", tint: AppTheme.accent, size: 32)
                    Text("你的回顾节奏")
                        .font(AppTypography.sectionTitle())
                        .foregroundStyle(Color.ink)
                }
                Text("\(cadenceLine) · 有问题才出现")
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.ink)
                Text(store.cadence.alternatives)
                    .font(AppTypography.metadata())
                    .foregroundStyle(Color.secondaryInk)
                if let next = store.nextReviewText {
                    Text("下一次：\(next)")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.tertiaryInk)
                }
                HabitCadenceMenu(store: store)
                    .padding(.top, density.spacing(AppSpacing.xxs))
            }
        }
    }

    private var cadenceLine: String {
        switch store.cadence {
        case .weekly: "每周日 \(shortTime)"
        case .everyThreeDays: "每 3 天 \(shortTime)"
        case .monthly: "每月末 \(shortTime)"
        case .smart: "智能积累"
        case .manual: "仅手动"
        }
    }

    private var shortTime: String {
        switch store.timePreset {
        case .morning: "9:00"
        case .afternoon: "14:00"
        case .evening: "20:00"
        }
    }
}

/// 面板入场动画的统一开关（离屏渲染传 false，直接取最终状态）。
private struct HabitPanelEntrance: ViewModifier {
    var animates: Bool

    func body(content: Content) -> some View {
        if animates {
            content.riverAppear(index: 0)
        } else {
            content
        }
    }
}
