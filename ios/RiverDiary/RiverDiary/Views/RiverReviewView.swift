import SwiftUI
import RiverDiaryCore

struct RiverReviewView: View {
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var diary: DiaryStore
    @State private var corrections: [UUID: String] = [:]

    private var pendingConfirmations: [RiverSharedStateRecord] {
        (node.database?.sharedUserRecords ?? [])
            .filter { $0.kind == .pendingConfirmation && $0.status == "pending" }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private var cards: [RiverSharedStateRecord] {
        node.database?.sharedUserRecords.filter { $0.kind == .habitCard } ?? []
    }

    private var rules: [RiverSharedStateRecord] {
        node.database?.sharedUserRecords.filter { $0.kind == .habitRule } ?? []
    }

    private var batches: [RiverSharedStateRecord] {
        node.database?.sharedUserRecords.filter { $0.kind == .habitBatch } ?? []
    }

    private var memories: [RiverSharedStateRecord] {
        node.database?.sharedUserRecords.filter { $0.kind == .memory } ?? []
    }

    private var sharedJournalEntries: [RiverSharedStateRecord] {
        (node.database?.sharedUserRecords ?? [])
            .filter { $0.kind == .journalEntry && $0.status == "current" }
            .sorted { $0.logicalKey > $1.logicalKey }
    }

    private var sharedMonthlyLetters: [RiverSharedStateRecord] {
        (node.database?.sharedUserRecords ?? [])
            .filter { $0.kind == .monthlyLetter && $0.status == "current" }
            .sorted { $0.logicalKey > $1.logicalKey }
    }

    private var sharedMonthlyLetterDrafts: [RiverSharedStateRecord] {
        (node.database?.sharedUserRecords ?? [])
            .filter { $0.kind == .monthlyLetterDraft && $0.status == "current" }
            .sorted { $0.logicalKey > $1.logicalKey }
    }

    private var sharedArtifacts: [RiverArtifactRevision] {
        ((try? node.database?.canonicalArtifactRevisions()) ?? [])
            .filter { $0.kind != .dailyReview && $0.kind != .memory }
            .sorted { $0.logicalKey < $1.logicalKey }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("需要你确认") {
                    if pendingConfirmations.isEmpty {
                        Text("目前没有地点候选需要确认。新的候选会在多次真实到访后出现。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(pendingConfirmations) { record in
                        pendingConfirmationRow(record)
                    }
                }

                Section("今日回顾") {
                    if let ai = node.aiStore, let review = ai.dailyReview {
                        Text(review).font(.callout).textSelection(.enabled)
                        Text(ai.status).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(node.aiStore?.status ?? "本机 AI 分析暂不可用")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if !sharedJournalEntries.isEmpty {
                    Section("共享手写日记") {
                        ForEach(sharedJournalEntries) { record in
                            if let entry = record.journalEntryContent {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(entry.dayKey).font(.caption.monospaced())
                                        Spacer()
                                        if let mood = entry.moodScore {
                                            Text("心情 · \(mood)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    if !entry.body.isEmpty { Text(entry.body).font(.callout).textSelection(.enabled) }
                                    if !entry.tags.isEmpty { Text(entry.tags.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !sharedMonthlyLetters.isEmpty {
                    Section("共享河流信") {
                        ForEach(sharedMonthlyLetters) { record in
                            if let letter = record.monthlyLetterContent {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(letter.title).font(.headline)
                                    Text(letter.body).font(.callout).textSelection(.enabled)
                                    if !letter.evidence.isEmpty {
                                        Text(letter.evidence).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !sharedMonthlyLetterDrafts.isEmpty {
                    Section("未保存的河流信草稿") {
                        ForEach(sharedMonthlyLetterDrafts) { record in
                            if let draft = record.monthlyLetterDraftContent {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(draft.monthKey).font(.caption.monospaced())
                                        Spacer()
                                        Label("未保存", systemImage: "pencil")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(draft.body).font(.callout).textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }

                if !sharedArtifacts.isEmpty {
                    Section("共享 AI 结果") {
                        ForEach(sharedArtifacts) { artifact in
                            artifactRow(artifact)
                        }
                    }
                }

                Section("习惯回顾") {
                    if let batch = batches.max(by: { $0.createdAt < $1.createdAt }) {
                        let payload = jsonObject(batch.payloadJSON)
                        if let title = payload["introTitle"] as? String, !title.isEmpty {
                            Text(title).font(.headline)
                        }
                        if let detail = payload["introDetail"] as? String, !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if cards.isEmpty {
                        ContentUnavailableView(
                            "还没有习惯回顾卡",
                            systemImage: "checkmark.seal",
                            description: Text("Mac 或 iPhone 生成的问题卡会通过加密同步出现在这里。")
                        )
                        .listRowBackground(Color.clear)
                    }
                    ForEach(cards) { record in
                        habitCard(record)
                    }
                }

                if !rules.isEmpty {
                    Section("已确认规则") {
                        ForEach(rules) { record in
                            ruleRow(record)
                        }
                    }
                }

                if !memories.isEmpty {
                    Section("共享记忆") {
                        ForEach(memories) { record in
                            memoryRow(record)
                        }
                    }
                }

                Section {
                    LabeledContent("加密同步", value: node.syncStatus)
                    Button("同步回顾决定") {
                        node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate)
                    }
                    .disabled(!drive.hasAccess || node.isSyncing)
                    if let message = node.habitActionMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("回顾")
            .refreshable { node.database?.refreshTimeline() }
        }
    }

    private func habitCard(_ record: RiverSharedStateRecord) -> some View {
        let payload = jsonObject(record.payloadJSON)
        let question = payload["question"] as? String ?? "习惯回顾"
        let lead = payload["lead"] as? String ?? ""
        let appName = payload["appName"] as? String ?? ""
        let status = payload["status"] as? String ?? record.status
        let isPending = status == "bundled" || status == "shown"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(question).font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel(status)).font(.caption).foregroundStyle(isPending ? Color.orange : Color.gray)
            }
            if !lead.isEmpty { Text(lead).font(.callout) }
            if !appName.isEmpty { Text("应用：\(appName)").font(.caption).foregroundStyle(.secondary) }
            if isPending {
                HStack {
                    Button("确认这些例子") { answer(record, "onlyTheseExamples") }
                        .buttonStyle(.bordered)
                    Button("确认长期习惯") { answer(record, "longTermRule") }
                        .buttonStyle(.borderedProminent)
                    Button("跳过") { answer(record, "skip") }
                        .buttonStyle(.bordered)
                }
            } else if let scope = payload["answerScopeText"] as? String, !scope.isEmpty {
                Text(scope).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func ruleRow(_ record: RiverSharedStateRecord) -> some View {
        let payload = jsonObject(record.payloadJSON)
        let scope = payload["scopeText"] as? String ?? record.logicalKey
        let category = payload["conclusionCategory"] as? String ?? "个人习惯"
        return VStack(alignment: .leading, spacing: 4) {
            Text(scope).font(.subheadline.weight(.medium))
            Text("\(category) · \(statusLabel(record.status))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func memoryRow(_ record: RiverSharedStateRecord) -> some View {
        let payload = jsonObject(record.payloadJSON)
        let title = payload["title"] as? String ?? "记忆候选"
        let body = payload["body"] as? String ?? ""
        let confirmation = node.database?.memoryConfirmation(for: record.id)
        let isConfirmed = confirmation?.confirmed ?? (payload["isUserConfirmed"] as? Bool ?? false)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Text(isConfirmed ? "已确认" : (confirmation == nil ? "待确认" : "已撤销"))
                    .font(.caption)
                    .foregroundStyle(isConfirmed ? Color.green : Color.orange)
            }
            if !body.isEmpty { Text(body).font(.callout) }
            HStack {
                Button(isConfirmed ? "撤销确认" : "确认记忆") {
                    node.setSharedMemoryConfirmation(record, confirmed: !isConfirmed)
                    node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 5)
    }

    private func pendingConfirmationRow(_ record: RiverSharedStateRecord) -> some View {
        guard let content = record.pendingConfirmationContent else {
            return AnyView(Text("待确认事项内容无法读取。").foregroundStyle(.secondary))
        }
        return AnyView(VStack(alignment: .leading, spacing: 8) {
            Text(content.question).font(.subheadline.weight(.semibold))
            if !content.detail.isEmpty { Text(content.detail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("确认") { resolve(record, as: .confirmed) }
                    .buttonStyle(.borderedProminent)
                Button("不正确") { resolve(record, as: .rejected) }
                    .buttonStyle(.bordered)
            }
            HStack {
                TextField("改成你自己的地点名称", text: binding(for: record.id))
                    .textFieldStyle(.roundedBorder)
                Button("保存修改") { resolve(record, as: .corrected) }
                    .buttonStyle(.bordered)
                    .disabled((corrections[record.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(.vertical, 5))
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { corrections[id, default: ""] },
            set: { corrections[id] = $0 }
        )
    }

    private func resolve(_ record: RiverSharedStateRecord, as resolution: RiverPendingConfirmationResolution) {
        node.resolveSharedPendingConfirmation(record, as: resolution, correction: corrections[record.id])
        node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate)
    }

    private func artifactRow(_ artifact: RiverArtifactRevision) -> some View {
        let raw = String(data: artifact.content, encoding: .utf8) ?? ""
        let content = readableArtifactText(raw)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(artifactTitle(artifact.kind)).font(.subheadline.weight(.semibold))
                Spacer()
                Text(statusLabel(artifact.status.rawValue)).font(.caption).foregroundStyle(.secondary)
            }
            if !content.isEmpty { Text(content).font(.callout).textSelection(.enabled) }
            Text("\(artifact.modelProvider) · \(artifact.modelIdentifier) · \(artifact.logicalKey)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.vertical, 5)
    }

    private func readableArtifactText(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return raw }
        for key in ["headline", "summary", "title", "overview", "text"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return raw
    }

    private func artifactTitle(_ kind: RiverArtifactKind) -> String {
        switch kind {
        case .semanticTimeline: "时间线理解"
        case .habitReview: "习惯回顾"
        case .insight: "洞察"
        case .suggestion: "建议"
        case .weeklyReview: "周回顾"
        case .monthlyReview: "月回顾"
        case .pendingConfirmation: "待确认"
        case .activityInterpretation: "活动解释"
        case .dailyReview: "今日回顾"
        case .memory: "记忆"
        }
    }

    private func answer(_ record: RiverSharedStateRecord, _ decision: String) {
        node.answerSharedHabitCard(record, decision: decision)
        node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate)
    }

    private func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private func statusLabel(_ value: String) -> String {
        switch value {
        case "bundled", "shown": "待确认"
        case "answered": "已回答"
        case "skipped": "已跳过"
        case "expired": "已过期"
        case "active": "生效中"
        case "retired": "已退役"
        case "provisional": "待其他设备核对"
        case "current": "当前版本"
        case "superseded": "已有新版本"
        case "stale": "依据有更新"
        default: value
        }
    }
}
