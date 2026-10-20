import RiverDiaryCore
import MapKit
import SwiftUI
import UIKit

private enum RiverPendingCard: Identifiable {
    case shared(RiverSharedStateRecord)
    case habit(RiverSharedStateRecord)

    var record: RiverSharedStateRecord {
        switch self {
        case .shared(let value), .habit(let value): value
        }
    }
    var id: UUID { record.id }
    var createdAt: Date { record.createdAt }
}

private struct RiverAnswerTarget: Identifiable {
    let record: RiverSharedStateRecord
    let isHabitCard: Bool
    var id: UUID { record.id }
}

struct RiverConfirmationsView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.riverUsesSharedHeader) private var usesSharedHeader
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var diary: DiaryStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCategory: ConfirmationCategory = .all
    private enum ConfirmationCategory: String, CaseIterable { case all = "全部", places = "地点", facts = "事实", habits = "习惯" }
    @State private var deferredQuestionIDs = Set<UUID>()
    @State private var detailTarget: RiverAnswerTarget?
    @State private var selectedPlaces: [UUID: RiverPlaceCandidate] = [:]
    @State private var answerTarget: RiverAnswerTarget?
    @State private var answerDrafts: [UUID: String] = [:]
    @State private var feedbackByID: [UUID: String] = [:]
    @State private var selectedAnswers: [UUID: String] = [:]
    @State private var customAnswers = Set<UUID>()
    @State private var longTermCustomAnswers = Set<UUID>()

    private var pending: [RiverPendingCard] {
        (node.database?.sharedUserRecords ?? []).compactMap { record in
            if record.kind == .pendingConfirmation && record.status == "pending" {
                return .shared(record)
            }
            if record.kind == .habitCard && ["bundled", "shown"].contains(record.status) { return .habit(record) }
            return nil
        }.sorted { $0.createdAt < $1.createdAt }
    }
    private var visiblePending: [RiverPendingCard] {
        pending.filter { item in
            guard !deferredQuestionIDs.contains(item.id) else { return false }
            switch selectedCategory {
            case .all: return true
            case .habits: return item.record.kind == .habitCard
            case .places: return item.record.pendingConfirmationContent?.targetType == "place"
            case .facts: return item.record.kind == .pendingConfirmation && item.record.pendingConfirmationContent?.targetType != "place"
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: theme.sectionSpacing) {
                if usesSharedHeader { RiverScrollingPageHeading(tab: .confirmations) }
                if !usesSharedHeader {
                Button { coordinator.returnToRiver() } label: {
                    Label("River", systemImage: "chevron.left")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.accentText)
                        .frame(minHeight: theme.tapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回 River")
                pageHeader
                }
                Picker("确认类别", selection: $selectedCategory) {
                    ForEach(ConfirmationCategory.allCases, id: \.self) { category in Text(category.rawValue).tag(category) }
                }.pickerStyle(.segmented).accessibilityIdentifier("river.confirmations.category")
                if node.database == nil {
                    RiverIOSDatabaseUnavailablePanel(message: node.initializationError) { node.retryOpen() }
                } else if !deferredQuestionIDs.isEmpty {
                    Button("显示稍后处理的 \(deferredQuestionIDs.count) 条") {
                        deferredQuestionIDs.removeAll()
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: theme.tapTarget)
                }
                if node.database == nil {
                    EmptyView()
                } else if visiblePending.isEmpty {
                    emptyQueue
                } else {
                    ForEach(visiblePending) { question in
                        switch question {
                        case .shared(let record): referenceCard(record, isHabit: false).transition(cardTransition)
                        case .habit(let record): referenceCard(record, isHabit: true).transition(cardTransition)
                        }
                    }
                }
                if let message = node.habitActionMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.subheadline).foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NavigationLink { RiverMemoryHomeView() } label: {
                    Label("历史确认与习惯 · 可重新修改", systemImage: "clock.arrow.circlepath")
                        .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .riverPageEntrance()
            .animation(reduceMotion ? nil : .riverSpring, value: visiblePending.map(\.id))
            .padding(.horizontal, theme.pageGutter)
            .padding(.top, 10)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 120 : 28)
        }
        .background(theme.canvas.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate) }
        .onChange(of: node.stateRevision) { _, _ in
            let stillPending = Set(pending.map(\.id))
            deferredQuestionIDs.formIntersection(stillPending)
        }
        .sheet(item: $detailTarget) { target in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if target.isHabitCard { habitQuestion(target.record) } else { sharedQuestion(target.record) }
                        if let feedback = feedbackByID[target.id] { Text(feedback).font(.callout).foregroundStyle(theme.secondaryInk) }
                    }.padding(theme.pageGutter)
                }.background(theme.canvas)
                    .safeAreaInset(edge: .bottom) {
                        decisionActions(target).padding(16).background(theme.surface)
                    }
                    .navigationTitle(target.isHabitCard ? "确认习惯" : target.record.pendingConfirmationContent?.targetType == "place" ? "确认地点" : "确认事实")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { detailTarget = nil } } }
                    .sheet(item: $answerTarget) { answer in
                        RiverNaturalAnswerSheet(title: answer.isHabitCard ? "纠正习惯" : "纠正内容", prompt: answer.isHabitCard ? habitPrompt(answer.record) : answer.record.pendingConfirmationContent?.question ?? "补充你的说明", text: draftBinding(for: answer.id), isHabitCard: answer.isHabitCard, feedback: feedbackByID[answer.id], onSubmit: { answerValue, save in self.answer(answer, text: answerValue, saveAsLongTermRule: save) })
                    }
            }.environment(\.riverTheme, theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var cardTransition: AnyTransition { reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)) }

    /// Keep the choice and its evidence together, as in the supplied interaction sample.
    private func referenceCard(_ record: RiverSharedStateRecord, isHabit: Bool) -> some View {
        let content = record.pendingConfirmationContent
        let isPlace = content?.targetType == "place"
        let target = RiverAnswerTarget(record: record, isHabitCard: isHabit)
        return RiverIOSPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    RiverIconChip(symbol: isHabit ? "leaf" : isPlace ? "mappin.and.ellipse" : "sparkles", size: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isHabit ? "River 发现的生活习惯" : content?.title ?? "待核对的生活片段").font(.subheadline.weight(.semibold))
                        Text(record.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(theme.secondaryInk)
                    }
                    Spacer(minLength: 0)
                    Text(isHabit ? "习惯线索" : isPlace ? "地点待确认" : "AI 暂定理解")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.warning)
                        .padding(7).riverNeumorphic(radius: 12)
                }
                if let detail = content?.detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(theme.secondaryInk).lineSpacing(3)
                }
                Text(isHabit ? habitPrompt(record) : content?.question ?? "这条线索符合你的经历吗？")
                    .font(.subheadline).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13).riverNeumorphic(inset: true, radius: 14)
                if isPlace {
                    ForEach(content?.choices ?? []) { choice in
                        referenceOption(title: choice.name, detail: choice.address ?? choice.suggestedKind ?? "候选地点", selected: selectedPlaces[record.id]?.id == choice.id) {
                            selectedPlaces[record.id] = choice; customAnswers.remove(record.id)
                        }
                    }
                } else if isHabit {
                    referenceOption(title: "是我的长期习惯", detail: "记住这个规律，用于理解之后的生活", selected: selectedAnswers[record.id] == "longTermRule") { selectedAnswers[record.id] = "longTermRule"; customAnswers.remove(record.id) }
                    referenceOption(title: "只确认这几次活动", detail: "保留事实，不延伸为长期习惯", selected: selectedAnswers[record.id] == "onlyTheseExamples") { selectedAnswers[record.id] = "onlyTheseExamples"; customAnswers.remove(record.id) }
                } else {
                    referenceOption(title: content?.candidate ?? "符合我的真实经历", detail: "确认这条理解，保留原始依据", selected: selectedAnswers[record.id] == "confirmed") { selectedAnswers[record.id] = "confirmed"; customAnswers.remove(record.id) }
                }
                Button {
                    if customAnswers.contains(record.id) { customAnswers.remove(record.id) }
                    else { customAnswers.insert(record.id) }
                } label: {
                    Label(isPlace ? "其他地点 · 自定义填写" : "补充或纠正这条理解", systemImage: "square.and.pencil")
                        .font(.caption).foregroundStyle(theme.secondaryInk).frame(maxWidth: .infinity, minHeight: 44)
                        .riverNeumorphic(inset: true, radius: 12)
                }.buttonStyle(.plain)
                if customAnswers.contains(record.id) {
                    TextField(isPlace ? "实际到访的地点" : "告诉 River 你当时在做什么…", text: draftBinding(for: record.id), axis: .vertical)
                        .font(.subheadline).lineLimit(2...5).padding(12).riverNeumorphic(inset: true, radius: 12)
                        .accessibilityIdentifier("river.confirmation.custom.\(record.id)")
                    if isHabit {
                        Toggle("把这次补充记为长期习惯", isOn: Binding(get: { longTermCustomAnswers.contains(record.id) }, set: { value in
                            if value { longTermCustomAnswers.insert(record.id) } else { longTermCustomAnswers.remove(record.id) }
                        })).font(.caption).tint(theme.accent)
                            .accessibilityIdentifier("river.confirmation.customLongTerm.\(record.id)")
                    }
                }
                HStack(spacing: 10) {
                    Button("跳过") {
                        if isHabit { answerHabit(record, decision: "skip") } else { resolve(record, as: .dismissed) }
                    }.riverQuiet()
                    Button(submitTitle(record, isHabit: isHabit)) {
                        if customAnswers.contains(record.id) { answer(target, text: answerDrafts[record.id, default: ""], saveAsLongTermRule: isHabit && longTermCustomAnswers.contains(record.id)) }
                        else if isHabit { answerHabit(record, decision: selectedAnswers[record.id] ?? "onlyTheseExamples") }
                        else if isPlace, let place = selectedPlaces[record.id] {
                            node.resolveSharedPendingConfirmation(record, as: .corrected, correction: place.name, selectedCandidateID: place.id); syncAfterDecision(record.id)
                        } else { resolve(record, as: .confirmed) }
                    }.riverPrimary().disabled(!canSubmit(record, isHabit: isHabit))
                        .accessibilityIdentifier("river.confirmation.submit.\(record.id)")
                }
                HStack {
                    Button { detailTarget = target } label: { Label("原始依据与更多选项", systemImage: "doc.text.magnifyingglass") }
                    Spacer(minLength: 0)
                    Button("稍后") { deferQuestion(record.id) }
                }.font(.caption).foregroundStyle(theme.secondaryInk).frame(minHeight: 44)
                if let feedback = feedbackByID[record.id] { Text(feedback).font(.caption).foregroundStyle(theme.warning) }
            }.foregroundStyle(theme.ink)
        }.accessibilityIdentifier("river.confirmation.\(record.id)")
    }

    private func submitTitle(_ record: RiverSharedStateRecord, isHabit: Bool) -> String {
        if customAnswers.contains(record.id) { return isHabit && longTermCustomAnswers.contains(record.id) ? "确认并记住" : "保存补充" }
        if isHabit && selectedAnswers[record.id] == "onlyTheseExamples" { return "确认这几次" }
        return isHabit ? "确认习惯" : "确认收录"
    }

    private func canSubmit(_ record: RiverSharedStateRecord, isHabit: Bool) -> Bool {
        if customAnswers.contains(record.id) { return !answerDrafts[record.id, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if record.pendingConfirmationContent?.targetType == "place" { return selectedPlaces[record.id] != nil }
        return selectedAnswers[record.id] != nil
    }

    private func referenceOption(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { RiverHaptics.selection(); withAnimation(reduceMotion ? nil : .riverTouch) { action() } } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(selected ? theme.accentText : theme.ink)
                    Text(detail).font(.caption2).foregroundStyle(theme.secondaryInk)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? theme.accentText : theme.secondaryInk)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }.padding(13).frame(minHeight: 60).riverNeumorphic(radius: 14, surfaceColor: selected ? theme.accentSoft : nil)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? theme.accent.opacity(0.4) : .clear, lineWidth: 1))
        }.riverTactile().accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func inboxRow(_ record: RiverSharedStateRecord, isHabit: Bool) -> some View {
        let kindName = isHabit ? "习惯" : record.pendingConfirmationContent?.targetType == "place" ? "地点" : "事实"
        let kindSymbol = isHabit ? "repeat" : record.pendingConfirmationContent?.targetType == "place" ? "mappin" : "doc.text"
        return Button { detailTarget = RiverAnswerTarget(record: record, isHabitCard: isHabit) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: kindSymbol).foregroundStyle(theme.accentText)
                    Text(kindName).font(.caption.weight(.semibold)).foregroundStyle(theme.accentText)
                    Spacer()
                    Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(theme.secondaryInk)
                }
                Text(isHabit ? habitPrompt(record) : record.pendingConfirmationContent?.question ?? "这条线索需要你的判断")
                    .font(theme.textFont(18, relativeTo: .body, weight: .medium))
                    .foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(evidenceSummary(record, isHabit: isHabit)).font(.caption).foregroundStyle(theme.secondaryInk)
                    Spacer()
                    Label("查看并回答", systemImage: "chevron.right")
                        .font(.caption.weight(.medium)).foregroundStyle(theme.accentText)
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous)
                        .strokeBorder(theme.separator.opacity(0.75), lineWidth: theme.borderWidth)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("river.confirmation.\(record.id)")
    }


    private var pageHeader: some View {
        RiverIOSPageHeader(title: "核对理解", subtitle: pending.isEmpty
                           ? "你的判断，让 River 更懂你。"
                           : "\(pending.count) 条待确认 · 先看依据，再做判断。")
    }

    private var emptyQueue: some View {
        RiverIOSPanel(padding: 24) {
            VStack(spacing: 14) {
                RiverIconChip(symbol: pending.isEmpty ? "checkmark.seal" : "leaf", tint: theme.success, size: 48)
                Text(pending.isEmpty ? "这一刻，都整理好了" : "这里暂时没有待确认的线索")
                    .font(.headline).foregroundStyle(theme.ink)
                Text(pending.isEmpty ? "日常记录会继续自动保存。遇到不能确定的理解，River 再来问你。" : "可以切换分类，或显示稍后处理的线索。")
                    .font(.subheadline).foregroundStyle(theme.secondaryInk).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
        }
    }

    private func evidenceSummary(_ record: RiverSharedStateRecord, isHabit: Bool) -> String {
        let count = isHabit
            ? (jsonObject(record.payloadJSON)["evidenceRefs"] as? [String] ?? []).count
            : (record.pendingConfirmationContent?.evidenceRefs ?? []).count
        return count == 0 ? "依据待补充" : "\(count) 条依据引用"
    }

    private func sharedQuestion(_ record: RiverSharedStateRecord) -> some View {
        let content = record.pendingConfirmationContent
        return VStack(alignment: .leading, spacing: 20) {
            Label("问题 · 尚未确认", systemImage: "questionmark.circle").font(.footnote).foregroundStyle(theme.secondaryInk)
            Text(content?.question ?? "这条记录的内容暂时无法读取。")
                .font(theme.textFont(24, relativeTo: .title2, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let detail = content?.detail, !detail.isEmpty { Text(detail).font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk) }
            if let candidate = content?.candidate, !candidate.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("River 的暂定理解").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryInk)
                    Text(candidate).font(.body).lineSpacing(4)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.riverSurface, in: RoundedRectangle(cornerRadius: theme.panelRadius, style: .continuous))
            }
            NavigationLink { confirmationEvidence(record) } label: {
                HStack {
                    Label("查看原始依据", systemImage: "doc.text.magnifyingglass")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption)
                }.font(.subheadline).frame(minHeight: theme.tapTarget)
            }.foregroundStyle(theme.accentText).accessibilityLabel("查看原始依据")
            if content?.targetType == "place", let placeID = content?.targetID, let place = node.database?.places.first(where: { $0.id == placeID }) {
                let center = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                Map(initialPosition: .region(MKCoordinateRegion(center: center, latitudinalMeters: max(place.radiusMeters * 4, 500), longitudinalMeters: max(place.radiusMeters * 4, 500)))) {
                    MapCircle(center: center, radius: max(place.radiusMeters, 30)).foregroundStyle(theme.accent.opacity(0.15))
                    Marker("位置范围", coordinate: center).tint(theme.accent)
                }.frame(height: 160).clipShape(RoundedRectangle(cornerRadius: theme.mapRadius + 4, style: .continuous)).allowsHitTesting(false).accessibilityHidden(true)
                Text("位置范围示意，不代表实际到访商户。").font(.footnote).foregroundStyle(theme.secondaryInk)
            }
            if content?.targetType == "place", let choices = content?.choices, !choices.isEmpty {
                ForEach(choices) { choice in
                    Button {
                        RiverHaptics.selection()
                        selectedPlaces[record.id] = choice
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selectedPlaces[record.id]?.id == choice.id ? "largecircle.fill.circle" : "circle").foregroundStyle(theme.accentText)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(choice.name).font(.body.weight(.medium))
                                if choice.distanceMeters.isFinite && choice.distanceMeters >= 0 && choice.distanceMeters < Double(Int.max) { Text("距定位点约 \(Int(choice.distanceMeters.rounded())) 米").font(.footnote).foregroundStyle(theme.secondaryInk) }
                                if let address = choice.address, !address.isEmpty { Text(address).font(.footnote).foregroundStyle(theme.secondaryInk) }
                                if let kind = choice.suggestedKind { Text(kind).font(.footnote).foregroundStyle(theme.secondaryInk) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(16).frame(minHeight: 64).background(theme.surface, in: RoundedRectangle(cornerRadius: theme.panelRadius - 2, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: theme.panelRadius - 2, style: .continuous).strokeBorder(selectedPlaces[record.id]?.id == choice.id ? theme.accent : theme.separator, lineWidth: selectedPlaces[record.id]?.id == choice.id ? 1.5 : 1))
                    }.buttonStyle(.plain).accessibilityIdentifier("river.confirmation.choice.\(choice.id)").accessibilityAddTraits(selectedPlaces[record.id]?.id == choice.id ? .isSelected : [])
                }
                Text("候选地点不代表实际到访；具体活动仍需其他记录支持。").font(.footnote).foregroundStyle(theme.secondaryInk)
            }
        }.foregroundStyle(theme.ink)
    }
    private func habitQuestion(_ record: RiverSharedStateRecord) -> some View {
        let object = jsonObject(record.payloadJSON)
        let examples = object["examples"] as? [[String: Any]] ?? []
        return VStack(alignment: .leading, spacing: 20) {
            Label("问题 · 尚未确认的习惯", systemImage: "repeat").font(.footnote).foregroundStyle(theme.secondaryInk)
            Text(habitPrompt(record)).font(theme.textFont(24, relativeTo: .title2, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if let lead = object["lead"] as? String, !lead.isEmpty { Text(lead).font(.body).lineSpacing(4).foregroundStyle(theme.secondaryInk) }
            Text("\(examples.count) 个活动例子 · 重复发生不一定是习惯").font(.callout).foregroundStyle(theme.secondaryInk)
            NavigationLink { confirmationEvidence(record) } label: { Label("查看活动依据", systemImage: "doc.text.magnifyingglass").font(.subheadline).frame(minHeight: 44) }
            Text("你可以确认长期习惯，也可以只确认这几次活动。原始记录会保留。").font(.body).lineSpacing(4)
        }.foregroundStyle(theme.ink)
    }
    @ViewBuilder private func decisionActions(_ target: RiverAnswerTarget) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你的判断").font(.caption.weight(.semibold)).foregroundStyle(theme.secondaryInk)
            if target.isHabitCard {
                decisionPair("确认习惯", "纠正描述", primary: {
                    RiverHaptics.success(); answerHabit(target.record, decision: "longTermRule")
                }, secondary: { presentAnswer(target.record, isHabit: true) })
                HStack {
                    Button("只确认例子") { RiverHaptics.soft(); answerHabit(target.record, decision: "onlyTheseExamples") }
                    Spacer()
                    Button("跳过") { RiverHaptics.soft(); answerHabit(target.record, decision: "skip") }
                    Spacer()
                    Button("稍后处理") { RiverHaptics.soft(); deferQuestion(target.id) }
                }.font(.subheadline).frame(minHeight: 44)
            } else if target.record.pendingConfirmationContent?.targetType == "place" {
                decisionPair("确认所选地点", "其他地点", enabled: selectedPlaces[target.id] != nil, primary: {
                        guard let choice = selectedPlaces[target.id] else { return }
                        RiverHaptics.success()
                        node.resolveSharedPendingConfirmation(target.record, as: .corrected, correction: choice.name, selectedCandidateID: choice.id); syncAfterDecision(target.id)
                }, secondary: { presentAnswer(target.record, isHabit: false) })
                HStack {
                    Button("都不是") { RiverHaptics.soft(); resolve(target.record, as: .rejected) }
                    Spacer()
                    Button("只是经过") { RiverHaptics.soft(); resolve(target.record, as: .dismissed) }
                    Spacer()
                    Button("稍后处理") { RiverHaptics.soft(); deferQuestion(target.id) }
                }.font(.subheadline).frame(minHeight: 44)
            } else {
                decisionPair("确认事实", "纠正内容", primary: {
                    RiverHaptics.success(); resolve(target.record, as: .confirmed)
                }, secondary: { presentAnswer(target.record, isHabit: false) })
                HStack {
                    Button("跳过这条") { RiverHaptics.soft(); resolve(target.record, as: .rejected) }
                    Spacer()
                    Button("稍后处理") { RiverHaptics.soft(); deferQuestion(target.id) }
                }.font(.subheadline).frame(minHeight: 44)
            }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private func decisionPair(_ first: String, _ second: String, enabled: Bool = true,
                                          primary: @escaping () -> Void, secondary: @escaping () -> Void) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                Button(first, action: primary).riverPrimary().disabled(!enabled)
                Button(second, action: secondary).riverQuiet()
            }
        } else {
            HStack(spacing: 12) {
                Button(first, action: primary).riverPrimary().disabled(!enabled)
                Button(second, action: secondary).riverQuiet()
            }
        }
    }

    private func confirmationEvidence(_ record: RiverSharedStateRecord) -> some View {
        RiverQuestionEvidenceView(questionID: record.id, onOpenEvent: { id, date in
            detailTarget = nil; coordinator.openTimeline(eventID: id, date: date)
        }, onOpenPlace: { id, date in detailTarget = nil; coordinator.openPlace(id, date: date) })
    }

    private func presentAnswer(_ record: RiverSharedStateRecord, isHabit: Bool) {
        answerTarget = RiverAnswerTarget(record: record, isHabitCard: isHabit)
    }

    private func resolve(_ record: RiverSharedStateRecord, as resolution: RiverPendingConfirmationResolution, correction: String? = nil) {
        node.resolveSharedPendingConfirmation(record, as: resolution, correction: correction)
        syncAfterDecision(record.id)
    }

    private func answerHabit(_ record: RiverSharedStateRecord, decision: String) {
        node.answerSharedHabitCard(record, decision: decision)
        syncAfterDecision(record.id)
    }

    private func answer(_ target: RiverAnswerTarget, text: String, saveAsLongTermRule: Bool) {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else { return }
        if target.isHabitCard {
            node.answerSharedHabitCard(target.record, naturalLanguage: reply, saveAsLongTermRule: saveAsLongTermRule)
        } else {
            node.resolveSharedPendingConfirmation(target.record, as: .corrected, correction: reply)
        }
        guard !pending.contains(where: { $0.id == target.id }) else {
            feedbackByID[target.id] = node.habitActionMessage ?? "回答尚未保存，请重试。"
            return
        }
        answerDrafts[target.id] = ""
        answerTarget = nil
        syncAfterDecision(target.id)
    }

    private func syncAfterDecision(_ id: UUID) {
        guard !pending.contains(where: { $0.id == id }) else {
            feedbackByID[id] = node.habitActionMessage ?? "决定尚未保存，请重试。"; return
        }
        detailTarget = nil
        feedbackByID[id] = drive.hasAccess
            ? "回答已保存在本机，正在等待加密状态同步核对。"
            : "回答已保存在本机；连接共享文件夹后会继续同步。"
        if drive.hasAccess {
            node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate)
        }
    }

    private func deferQuestion(_ id: UUID) {
        detailTarget = nil
        deferredQuestionIDs.insert(id)
        feedbackByID[id] = "已暂时收起；问题仍保存在待确认队列中。"
    }

    private func draftBinding(for id: UUID) -> Binding<String> {
        Binding(get: { answerDrafts[id, default: ""] }, set: { answerDrafts[id] = $0 })
    }

    private func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private func habitPrompt(_ record: RiverSharedStateRecord) -> String {
        jsonObject(record.payloadJSON)["question"] as? String ?? "补充你对这条习惯线索的理解。"
    }
}

private struct RiverNaturalAnswerSheet: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    let prompt: String
    @Binding var text: String
    let isHabitCard: Bool
    var feedback: String? = nil
    let onSubmit: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingDiscardConfirmation = false
    @State private var saveAsLongTermRule = false

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(prompt)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("按你的真实经历，补充或更正。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                if isHabitCard {
                    Toggle("把这句话保存为以后适用的习惯", isOn: $saveAsLongTermRule)
                        .font(.subheadline)
                    Text("勾选后，这句话才会用于理解以后的经历。")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
                if let feedback { Text(feedback).font(.callout).foregroundStyle(theme.warning) }
                TextEditor(text: $text)
                    .font(.body)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 220 : 170)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .accessibilityLabel("自定义回答")
                if !text.isEmpty {
                    Button("丢弃未提交回答", role: .destructive) { showingDiscardConfirmation = true }
                        .font(.subheadline)
                }
            }
            .padding(theme.pageGutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("提交回答") { onSubmit(text, isHabitCard && saveAsLongTermRule) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { hideKeyboard() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .confirmationDialog("丢弃未提交回答？", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("丢弃回答", role: .destructive) {
                text = ""
                dismiss()
            }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("关闭窗口会保留草稿；只有明确丢弃后才会清空。")
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
