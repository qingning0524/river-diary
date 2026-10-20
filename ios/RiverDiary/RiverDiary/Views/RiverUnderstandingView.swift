import RiverDiaryCore
import SwiftUI
import UIKit

private struct RiverConversationMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, river }
    var id = UUID()
    let role: Role
    let text: String
    let evidenceEventIDs: [UUID]
    let evidenceMemoryIDs: [UUID]
    var retryQuestion: String? = nil
    /// Only the model path writes failure bubbles; local answers always resolve.
    var failureDetail: String? = nil

    var isFailure: Bool { failureDetail != nil }
}

struct RiverUnderstandingView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.riverUsesSharedHeader) private var usesSharedHeader
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var drafts: RiverLocalDraftStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var conversationThreads: [String: [RiverConversationMessage]] = [:]
    @State private var dayDrafts: [String: String] = [:]
    @State private var draft = ""
    @State private var draftDay: String?
    @State private var respondingDays: Set<String> = []
    @State private var showingSettings = false
    @State private var timelineRefreshToken = 0
    @FocusState private var inputFocused: Bool

    private var date: Date { coordinator.selectedDate }
    private var conversationDay: String { RiverIOSProjection.dayKey(date) }
    private var messages: [RiverConversationMessage] { conversationThreads[conversationDay] ?? [] }
    private var isResponding: Bool { respondingDays.contains(conversationDay) }
    private var database: RiverLocalDatabase? { node.database }
    private var rows: [IOSActivityRow] {
        let _ = timelineRefreshToken
        guard let database else { return [] }
        return RiverIOSProjection.timelineRows(database: database, date: date)
    }
    private var observedRows: [IOSActivityRow] { rows.filter { $0.kind != .riverInsight } }
    private var memories: [RiverSharedStateRecord] {
        (database?.sharedUserRecords ?? [])
            .filter { $0.kind == .memory && $0.status != "deleted" }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
    private var currentJournal: RiverJournalEntryContent? {
        database?.sharedUserRecords.first {
            $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == RiverIOSProjection.dayKey(date)
        }?.journalEntryContent
    }
    private var hasCurrentJournal: Bool {
        !(currentJournal?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    private var dayAnalysis: RiverDayAnalysisSnapshot {
        RiverDayAnalysisSnapshot.load(database: database, date: date)
    }
    private var usesModel: Bool {
        guard node.aiStore?.canAskRiver == true else { return false }
        return !allowedRows.isEmpty || !allowedMemories.isEmpty || !allowedPlaces.isEmpty
            || !allowedHabitAnswers.isEmpty || allowedJournal != nil
    }
    private var confirmedPlaces: [RiverPlace] { database?.places.filter(\.isUserConfirmed) ?? [] }
    private var answeredHabitCards: [RiverSharedStateRecord] {
        (database?.sharedUserRecords ?? []).filter {
            $0.kind == .habitCard && ["answered", "skipped"].contains($0.status)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var pending: [RiverSharedStateRecord] {
        (database?.sharedUserRecords ?? []).filter {
            ($0.kind == .pendingConfirmation && $0.status == "pending")
                || ($0.kind == .habitCard && ["bundled", "shown"].contains($0.status))
        }.sorted { $0.createdAt < $1.createdAt }
    }
    var body: some View {
        VStack(spacing: 0) {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: theme.sectionSpacing) {
                    if usesSharedHeader { RiverScrollingPageHeading(tab: .river) }
                    else { RiverSystemSignature() }
                    if !usesSharedHeader { riverHero }
                    if database == nil {
                        RiverIOSDatabaseUnavailablePanel(message: node.initializationError) { node.retryOpen() }
                    }
                    if database != nil {
                    if usesSharedHeader {
                        companionCard
                        if !pending.isEmpty { confirmationEntry }
                    } else if messages.isEmpty {
                        sourceContext
                        confirmationEntry
                        chatIntro
                        if let overview = dayAnalysis.overview, !overview.isEmpty {
                            savedUnderstanding(overview)
                        }
                    } else {
                        Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                            .font(.subheadline).foregroundStyle(theme.secondaryInk)
                            .accessibilityIdentifier("river.chat.context.date")
                        confirmationEntry
                    }
                    ForEach(messages) { message in
                        conversationBubble(message)
                            .id(message.id)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
                    }
                    if isResponding {
                        HStack(spacing: 9) {
                            ProgressView()
                            Text("River 正在整理可用资料…")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryInk)
                        }
                        .padding(.vertical, 6)
                        .id("river-thinking")
                    }
                    }
                }
                .riverPageEntrance()
                .animation(reduceMotion ? nil : .riverReveal, value: messages.count)
                .padding(.horizontal, theme.pageGutter)
                .padding(.top, 16)
                .padding(.bottom, theme.sectionSpacing)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.canvas)
            .onChange(of: messages.count) { _, _ in
                guard let lastID = messages.last?.id else { return }
                withAnimation(reduceMotion ? nil : .riverReveal) { scrollProxy.scrollTo(lastID, anchor: .bottom) }
            }
        }
        chatComposer.padding(.bottom, usesSharedHeader && !inputFocused ? 8 : 0)
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) { SettingsView() }
        // Transient keyboard hide notifications can occur during layout/input-mode
        // changes. Keep editing focus with FocusState and explicit Done/Send actions.
        .onChange(of: inputFocused) { _, focused in coordinator.riverComposerFocused = focused }
        .onAppear {
            restoreDraft(for: date); refreshTimeline(for: date)
            restoreConversationIfNeeded()
        }
        .onChange(of: draft) { _, text in
            if let key = draftDay { drafts.update(text, for: key, kind: .question) }
        }
        .onDisappear {
            persistConversation(conversationDay)
            if let key = draftDay { dayDrafts[key] = draft; drafts.update(draft, for: key, kind: .question) }
            drafts.flush(); inputFocused = false; coordinator.riverComposerFocused = false
        }
        .onChange(of: coordinator.selectedDate) { _, newDate in
            if let previousDay = draftDay { persistConversation(previousDay) }
            restoreDraft(for: newDate); refreshTimeline(for: newDate)
            restoreConversationIfNeeded()
        }
        .onChange(of: node.stateRevision) { _, _ in refreshTimeline(for: date) }
    }

    private var companionCard: some View {
        RiverIOSPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    RiverIconChip(symbol: "water.waves", size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Calendar.current.isDateInToday(date) ? "River 今日智能伴随" : "River 当日智能伴随").font(.headline)
                        Text(usesModel ? "按你的授权，理解生活记忆" : "随身搭子 · 本机记忆检索").font(.caption2).foregroundStyle(theme.secondaryInk)
                    }
                    Spacer(minLength: 0)
                    Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 32, height: 44) }
                        .accessibilityLabel("AI 设置与资料范围").accessibilityIdentifier("river.chat.configure")
                }
                Text(dayAnalysis.overview ?? (observedRows.isEmpty ? "嗨，我是 River。生活线索会自动留下，我会帮你整理成日记。想了解什么，随时问我。" : "嗨，我是 River。已经为你连起这一天的 \(observedRows.count) 段生活线索，也记得你确认过的地点与习惯。想回顾什么，随时问我。"))
                    .font(.subheadline).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).riverNeumorphic(inset: true, radius: 18)
                HStack(spacing: 8) {
                    Label("\(observedRows.count) 段生活线索", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(theme.success)
                    Spacer(minLength: 0)
                    Label("\(memories.count) 条记忆", systemImage: "leaf").foregroundStyle(.purple)
                }.font(.caption2.weight(.medium))
                Rectangle().fill(theme.separator.opacity(0.6)).frame(height: 1)
                HStack { Label("你可以试着这样问我", systemImage: "lightbulb").font(.caption.weight(.medium)).foregroundStyle(theme.secondaryInk); Spacer(); Text("点击填入").font(.caption2).foregroundStyle(theme.secondaryInk) }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { questionChip("这一天的专注时光？", symbol: "book"); questionChip("River 记住了哪些习惯？", symbol: "leaf") }
                    VStack(spacing: 10) { questionChip("这一天的专注时光？", symbol: "book"); questionChip("River 记住了哪些习惯？", symbol: "leaf") }
                }
                Text(sourceScope).font(.system(size: 10)).foregroundStyle(theme.secondaryInk)
                    .accessibilityIdentifier("river.chat.context")
            }
        }
    }
    private func questionChip(_ question: String, symbol: String) -> some View {
        Button { draft = question; inputFocused = true } label: {
            Label(question, systemImage: symbol).font(.caption).foregroundStyle(theme.ink)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 44).riverNeumorphic(radius: 18)
        }.riverTactile().accessibilityHint("填入后可编辑并发送")
    }

    private func restoreConversationIfNeeded() {
        guard conversationThreads[conversationDay] == nil else { return }
        if let saved: [RiverConversationMessage] = drafts.conversation(for: conversationDay, as: [RiverConversationMessage].self) {
            conversationThreads[conversationDay] = saved
        }
    }

    private func persistConversation(_ day: String) {
        guard let thread = conversationThreads[day], !thread.isEmpty else { return }
        drafts.saveConversation(Array(thread.suffix(50)), for: day)
    }

    private func restoreDraft(for date: Date) {
        let key = RiverIOSProjection.dayKey(date)
        guard draftDay != key else { return }
        if let old = draftDay {
            dayDrafts[old] = draft
            drafts.update(draft, for: old, kind: .question); drafts.flush()
        }
        draftDay = key
        draft = dayDrafts[key] ?? drafts.text(for: key, kind: .question) ?? ""
    }

    private var riverHero: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("River").font(theme.titleFont).foregroundStyle(theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("让经历成为理解")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
            Button { inputFocused = false; showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: theme.tapTarget, height: theme.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(theme.accentText)
            .accessibilityLabel("River 设置与资料范围")
            .accessibilityIdentifier("river.chat.settings")
        }
        .accessibilityElement(children: .contain)
    }

    private func refreshTimeline(for date: Date) {
        database?.refreshTimeline(for: date)
        timelineRefreshToken &+= 1
    }

    private var sourceContext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(theme.ink)
                    .accessibilityIdentifier("river.chat.context.date")
                Spacer(minLength: 0)
                Button("查看记录") { coordinator.openFootprints(day: date) }
                    .font(.caption.weight(.medium)).foregroundStyle(theme.accentText)
                    .frame(minHeight: theme.tapTarget)
            }
            Text(observedRows.isEmpty && !hasCurrentJournal
                 ? "这一天还没有记录，可以先记下一件事。"
                 : "\(observedRows.count) 条活动记录" + (hasCurrentJournal ? " · 1 篇日记" : ""))
                .font(.subheadline).foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label(usesModel ? "按授权范围回答" : "本机资料检索", systemImage: usesModel ? "sparkle" : "internaldrive")
                        .font(.caption.weight(.medium)).foregroundStyle(theme.accentText)
                    Spacer(minLength: 0)
                    if node.aiStore?.canAskRiver != true {
                        Button("设置 AI") { showingSettings = true }
                            .font(.caption.weight(.semibold)).foregroundStyle(theme.accentText)
                            .frame(minHeight: theme.tapTarget)
                            .accessibilityLabel("设置 AI 连接与资料范围")
                            .accessibilityIdentifier("river.chat.configure")
                    }
                }
                Text(sourceScope)
                    .font(.caption).foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(theme.riverSurface, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("river.chat.context")
    }

    private var sourceScope: String {
        guard usesModel, let ai = node.aiStore else {
            return "查找所选一天的记录，以及本机已有的地点、习惯和长期记忆。"
        }
        var scope = ["当天活动"]
        if ai.includeManualText { scope.append("日记") }
        if ai.includePlaces { scope.append("地点") }
        if ai.includeHealth { scope.append("健康") }
        if ai.includePhotoObservations || ai.allowsPhotoAI { scope.append("照片记录") }
        if ai.includeSharedMemories { scope.append("长期记忆与习惯") }
        return "回答资料：" + scope.joined(separator: "、")
    }

    private var chatIntro: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("从这里开始")
                .font(theme.sectionFont).foregroundStyle(theme.ink)
                .padding(.bottom, 12).accessibilityAddTraits(.isHeader)
            suggestedQuestion("这一天记录了什么？", detail: "回看所选一天", symbol: "clock")
            suggestedQuestion("我的日记写了什么？", detail: "读自己的文字", symbol: "text.book.closed")
            suggestedQuestion("River 记住了什么？", detail: "查找已有记忆", symbol: "bookmark")
        }
    }

    private var confirmationEntry: some View {
        Button { coordinator.openConfirmations() } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 18)).foregroundStyle(theme.accentText)
                Text(pending.isEmpty ? "确认与纠正" : "有 \(pending.count) 条理解需要你核对")
                    .font(.subheadline.weight(.medium)).foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryInk)
            }
            .frame(minHeight: theme.tapTarget)
            .padding(.vertical, pending.isEmpty ? 0 : 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("地点、事实与习惯确认，\(pending.count) 条待确认内容")
        .accessibilityIdentifier("river.confirmations.open")
    }

    private func savedUnderstanding(_ overview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已有的理解").font(theme.sectionFont).accessibilityAddTraits(.isHeader)
            Text(overview).font(.body).lineSpacing(5)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
            Button("查看这一天的依据") { coordinator.openFootprints(day: date) }
                .font(.subheadline).frame(minHeight: theme.tapTarget)
        }
        .foregroundStyle(theme.ink)
    }

    private func suggestedQuestion(_ question: String, detail: String, symbol: String) -> some View {
        Button {
            RiverHaptics.selection()
            draft = question
            inputFocused = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18)).foregroundStyle(theme.accentText)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(question).font(.subheadline.weight(.medium)).foregroundStyle(theme.ink)
                    Text(detail).font(.caption).foregroundStyle(theme.secondaryInk)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.left")
                    .font(.caption).foregroundStyle(theme.secondaryInk)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: theme.tapTarget, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
        }
        .buttonStyle(.plain).accessibilityLabel(question).accessibilityHint("填入问题后，你可以编辑并发送")
    }

    private func conversationBubble(_ message: RiverConversationMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            HStack(spacing: 6) {
                if message.role == .river {
                    Image(systemName: "water.waves.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accentText)
                        .frame(width: 20, height: 20)
                        .background(theme.accentSoft, in: Circle())
                }
                Text(message.role == .user ? "你" : "River")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.secondaryInk)
            }
            if message.isFailure {
                failureBubble(message)
            } else {
                Text(message.text)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == .user ? theme.palette.onAccent : theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(17)
                    .background(message.role == .user ? theme.accent : .clear, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .riverNeumorphic(radius: 22)
                    .overlay {
                        if message.role == .river {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(theme.separator.opacity(0.7), lineWidth: theme.borderWidth)
                        }
                    }
            }
            if !message.evidenceEventIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相关时间线记录")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryInk)
                    ForEach(evidenceRows(for: message)) { row in
                        if let id = row.routeEventID ?? row.eventIDs.first {
                            Button {
                                coordinator.openTimeline(eventID: id, date: date)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle().fill(theme.success).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.title).font(.subheadline.weight(.medium)).foregroundStyle(theme.ink)
                                        Text(row.timeLabel ?? row.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(theme.secondaryInk)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if let duration = row.duration, duration.isFinite, duration > 0 { Text(RiverDayReadingMath.timeText(seconds: duration)).font(.caption.weight(.semibold)).foregroundStyle(theme.accentText) }
                                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(theme.secondaryInk)
                                }.padding(14).riverNeumorphic(radius: 17)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.evidenceMemoryIDs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("相关长期记忆")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.secondaryInk)
                    ForEach(message.evidenceMemoryIDs, id: \.self) { id in
                        if let memory = memories.first(where: { $0.id == id }) {
                            Button {
                                coordinator.openMemory(id)
                            } label: {
                                Label(RiverIOSProjection.memoryText(memory, key: "title") ?? "打开记忆依据", systemImage: "arrow.up.right")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let question = message.retryQuestion {
                Button {
                    RiverHaptics.soft()
                    draft = question
                    inputFocused = true
                } label: {
                    Label("重新编辑这个问题", systemImage: "pencil.line")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accentText)
                .accessibilityIdentifier("river.chat.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }

    private func evidenceRows(for message: RiverConversationMessage) -> [IOSActivityRow] {
        let eventIDs = Set(message.evidenceEventIDs)
        return observedRows.filter { !eventIDs.isDisjoint(with: $0.eventIDs) }
    }

    /// A failed answer never masquerades as prose: it keeps the question,
    /// names the failure, and hands back the retry affordance.
    private func failureBubble(_ message: RiverConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这次没有成功生成回答", systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.danger)
            Text(message.text.replacingOccurrences(of: "\n\n\(message.failureDetail ?? "")", with: ""))
                .font(.subheadline)
                .foregroundStyle(theme.ink)
            if let detail = message.failureDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.dangerSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.danger.opacity(0.3), lineWidth: 0.8)
        }
    }

    private var chatComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(usesModel ? "所选一天 · AI 回答" : "所选一天 · 本机检索")
                    .font(.caption).foregroundStyle(theme.secondaryInk)
                Spacer()
                if inputFocused {
                    Button("完成") { inputFocused = false }.font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel("完成")
                        .accessibilityIdentifier("river.chat.dismissKeyboard")
                }
            }
        HStack(alignment: .bottom, spacing: 10) {
            TextField("问问这一天，或找一段记忆…", text: $draft, axis: .vertical)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 4))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { Task { await sendQuestion() } }
                .font(.body).foregroundStyle(theme.ink)
                .frame(minHeight: 44)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .riverNeumorphic(inset: true, radius: 14)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(inputFocused ? theme.accent : theme.separator, lineWidth: inputFocused ? 1.5 : 1))
                .accessibilityLabel("问 River").accessibilityIdentifier("river.chat.input")
                .disabled(node.database == nil)
            Button {
                Task { await sendQuestion() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(theme.accent, in: Circle())
                    .frame(width: theme.tapTarget, height: theme.tapTarget)
                    .contentShape(Rectangle())
            }
            .riverTactile()
            .disabled(node.database == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding)
            .accessibilityLabel("发送问题").accessibilityIdentifier("river.chat.send")
        }
        }
        .padding(.horizontal, theme.pageGutter)
        .padding(.vertical, 8)
        .background(theme.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("river.chat.composer")
    }

    private func sendQuestion() async {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }
        let answerDay = conversationDay
        draft = ""
        dayDrafts[answerDay] = ""
        drafts.remove(for: answerDay, kind: .question)
        inputFocused = false
        conversationThreads[answerDay, default: []].append(RiverConversationMessage(role: .user, text: question, evidenceEventIDs: [], evidenceMemoryIDs: []))
        // Store the sent question before a network wait can outlive the app.
        persistConversation(answerDay)
        respondingDays.insert(answerDay)
        defer {
            respondingDays.remove(answerDay)
            persistConversation(answerDay)
        }

        let remoteRows = allowedRows
        let remoteMemories = allowedMemories
        let remotePlaces = allowedPlaces
        let remoteHabitAnswers = allowedHabitAnswers
        let remoteJournal = allowedJournal
        let localSources = relevantRows(for: question, from: observedRows)
        let remoteSources = relevantRows(for: question, from: remoteRows)
        let canReferenceMemory = questionUsesMemory(question)
        let remoteMemoryIDs = canReferenceMemory ? Array(remoteMemories.prefix(5).map(\.id)) : []
        let localMemoryIDs = canReferenceMemory ? Array(memories.prefix(5).map(\.id)) : []
        let context = contextText(rows: remoteRows, memories: remoteMemories,
                                  places: remotePlaces, habitAnswers: remoteHabitAnswers, journal: remoteJournal)
        if let ai = node.aiStore, ai.canAskRiver, !context.isEmpty {
            do {
                let answer = try await ai.ask(question: question, context: context)
                conversationThreads[answerDay, default: []].append(RiverConversationMessage(role: .river, text: answer,
                                                         evidenceEventIDs: Array(remoteSources.flatMap(\.eventIDs).prefix(8)),
                                                         evidenceMemoryIDs: remoteMemoryIDs))
            } catch {
                conversationThreads[answerDay, default: []].append(RiverConversationMessage(
                    role: .river,
                    text: "你输入的问题仍在本机；可以重试，或直接打开下面的原始资料。",
                    evidenceEventIDs: Array(remoteSources.flatMap(\.eventIDs).prefix(8)),
                    evidenceMemoryIDs: remoteMemoryIDs, retryQuestion: question,
                    failureDetail: error.localizedDescription
                ))
            }
        } else {
            let response = localReply(question: question, rows: observedRows, memories: memories,
                                      places: confirmedPlaces, habitAnswers: answeredHabitCards,
                                      journal: currentJournal, sources: localSources)
            conversationThreads[answerDay, default: []].append(RiverConversationMessage(role: .river, text: response,
                                                     evidenceEventIDs: Array(localSources.flatMap(\.eventIDs).prefix(8)),
                                                     evidenceMemoryIDs: localMemoryIDs))
        }
    }

    private var allowedRows: [IOSActivityRow] {
        guard let ai = node.aiStore else { return rows }
        return rows.filter { row in
            guard row.kind != .riverInsight else { return false }
            switch row.kind {
            case .place: return ai.includePlaces
            case .health: return ai.includeHealth
            case .note: return ai.includeManualText
            case .photo: return ai.includePhotoObservations || ai.allowsPhotoAI
            default: return true
            }
        }
    }

    private var allowedMemories: [RiverSharedStateRecord] {
        node.aiStore?.includeSharedMemories == true ? memories : []
    }

    private var allowedPlaces: [RiverPlace] {
        node.aiStore?.includePlaces == true ? confirmedPlaces : []
    }

    private var allowedHabitAnswers: [RiverSharedStateRecord] {
        node.aiStore?.includeSharedMemories == true ? answeredHabitCards : []
    }

    private var allowedJournal: RiverJournalEntryContent? {
        guard node.aiStore?.includeManualText == true else { return nil }
        return currentJournal
    }

    private func contextText(rows: [IOSActivityRow], memories: [RiverSharedStateRecord],
                             places: [RiverPlace], habitAnswers: [RiverSharedStateRecord],
                             journal: RiverJournalEntryContent?) -> String {
        let eventLines = rows.prefix(40).map { row in
            "\(row.date.formatted(date: .abbreviated, time: .omitted)) · \(row.timeLabel ?? row.date.formatted(date: .omitted, time: .shortened)) · \(row.title) · \(row.detail) · \(row.isInferred ? "时间为估算" : row.sourceLabel)"
        }
        let memoryLines = memories.prefix(30).map { record in
            let confirmation = record.status == "confirmed" || (database?.memoryConfirmation(for: record.id)?.confirmed == true)
            let title = RiverIOSProjection.memoryText(record, key: "title") ?? "长期记忆"
            let body = RiverIOSProjection.memoryText(record, key: "body") ?? ""
            return "\(confirmation ? "用户已确认" : "River 的暂定理解") · \(title)：\(body)"
        }
        let placeLines = places.prefix(20).map { "用户已确认的地点 · \($0.displayName) · \($0.semanticType ?? "地点")" }
        let habitLines = habitAnswers.prefix(20).compactMap { record -> String? in
            let payload = jsonObject(record.payloadJSON)
            let question = payload["question"] as? String ?? ""
            let answer = payload["answerScopeText"] as? String ?? ""
            guard !answer.isEmpty else { return nil }
            return "用户对习惯线索的回答 · \(question)：\(answer)"
        }
        let journalLines = journal.map { ["用户手写日记 \($0.dayKey) · \($0.body)"] } ?? []
        return (eventLines + memoryLines + placeLines + habitLines + journalLines).joined(separator: "\n")
    }

    private func relevantRows(for question: String, from candidates: [IOSActivityRow]) -> [IOSActivityRow] {
        let lowered = question.lowercased()
        if ["今天", "这一天", "昨天", "刚才", "timeline", "活动"].contains(where: lowered.contains) {
            return Array(candidates.suffix(5))
        }
        let matches = candidates.filter { row in
            [row.title, row.detail, row.sourceLabel].contains { value in
                let normalized = value.lowercased()
                return normalized.count > 1 && (lowered.contains(normalized) || normalized.contains(lowered))
            }
        }
        return Array(matches.prefix(5))
    }

    private func localReply(question: String, rows: [IOSActivityRow], memories: [RiverSharedStateRecord],
                            places: [RiverPlace], habitAnswers: [RiverSharedStateRecord],
                            journal: RiverJournalEntryContent?,
                            sources: [IOSActivityRow]) -> String {
        let lowered = question.lowercased()
        if ["今天", "这一天", "昨天", "刚才", "活动", "做了什么"].contains(where: lowered.contains) {
            guard !rows.isEmpty || journal != nil else { return "我在所选日期没有找到可查看的活动记录。未记录的时间段无法据此判断。" }
            let items = rows.suffix(6).map {
                "• \($0.date.formatted(date: .omitted, time: .shortened)) · \($0.title)\($0.isInferred ? "（时间为估算）" : "")"
            }
            let automaticLine = items.isEmpty ? "当天没有自动活动线索。" : items.joined(separator: "\n")
            let journalLine = journal.map { "\n手写日记：\($0.body)" } ?? ""
            return "本机找到这些真实记录：\n\(automaticLine)\(journalLine)\n\n它们说明记录了什么；未记录的时段我无法判断。"
        }
        if lowered.contains("日记") || lowered.contains("写了") || lowered.contains("写下") {
            guard let journal else { return "所选日期没有找到手写日记记录。" }
            return "你在 \(journal.dayKey) 写下：\n\(journal.body)"
        }
        if lowered.contains("地点") || lowered.contains("去过") || lowered.contains("哪里") {
            if !places.isEmpty {
                let items = places.prefix(5).map { "• \($0.displayName)（\($0.visitCount) 次到访记录）" }
                return "你确认过的地点记录有：\n\(items.joined(separator: "\n"))\n\n我不会仅根据地点名称推断你在那里的活动。"
            }
            return "目前没有可引用的已确认地点记录。"
        }
        if lowered.contains("习惯") {
            let answers = habitAnswers.prefix(5).compactMap { record -> String? in
                guard let answer = jsonObject(record.payloadJSON)["answerScopeText"] as? String else { return nil }
                return "• \(answer)"
            }
            if !answers.isEmpty { return "你之前对习惯线索的回答包括：\n\(answers.joined(separator: "\n"))\n\n这些是你的原话或选择，不代表新的 AI 判断。" }
        }
        if lowered.contains("记住") || lowered.contains("记忆") || lowered.contains("喜欢") || lowered.contains("项目") {
            guard !memories.isEmpty else { return "目前没有可引用的共享长期记忆，所以我还不知道这一点。你可以在 Me 查看现有记录，或在设置里明确选择是否把记忆用于 River 对话。" }
            let items = memories.prefix(5).map {
                let title = RiverIOSProjection.memoryText($0, key: "title") ?? "长期记忆"
                let body = RiverIOSProjection.memoryText($0, key: "body") ?? ""
                return "• \(title)：\(body)（\($0.status == "confirmed" ? "你已确认" : "暂定理解")）"
            }
            return "本机共享记忆中有这些内容：\n\(items.joined(separator: "\n"))\n\n如果理解有误，可以在 Me 中打开记录并更正或删除。"
        }
        if !sources.isEmpty {
            let list = sources.map { "• \($0.date.formatted(date: .omitted, time: .shortened)) · \($0.title)" }.joined(separator: "\n")
            return "我找到与你的问题相关的记录：\n\(list)\n\n这些是记录本身；它们的含义还需要更多上下文。"
        }
        return "我还不能从当前可用资料中可靠回答。你可以查看 Timeline 和 Me 中保存的依据；River 不会把推测说成事实。"
    }

    private func questionUsesMemory(_ question: String) -> Bool {
        ["记住", "记忆", "习惯", "喜欢", "项目", "地点", "去过", "哪里"].contains { question.contains($0) }
    }

    private func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
