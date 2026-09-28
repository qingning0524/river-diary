import SwiftUI
import RiverDiaryCore

struct RiverNodeTimelineView: View {
    @EnvironmentObject private var node: RiverNodeStore

    private var todayJournalRecord: RiverSharedStateRecord? {
        let dayKey = DiaryEntry.dateFormatter.string(from: Date())
        return node.database?.sharedUserRecords.first {
            $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == dayKey
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let database = node.database {
                    VStack(spacing: 0) {
                        if let ai = node.aiStore {
                            IPhoneAIReviewCard(ai: ai)
                        }
                        List {
                            if let journal = todayJournalRecord?.journalEntryContent {
                                Section("今日手写日记") {
                                    if !journal.body.isEmpty {
                                        Text(journal.body)
                                            .font(.body)
                                            .textSelection(.enabled)
                                    }
                                    if let mood = journal.moodScore {
                                        Label("心情评分 · \(mood)", systemImage: "face.smiling")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !journal.tags.isEmpty {
                                        Text(journal.tags.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if !database.places.isEmpty {
                                Section("地点确认") {
                                    ForEach(database.places) { place in
                                        PlaceDecisionRow(place: place) { name, type in
                                            node.savePlaceDecision(placeID: place.id, name: name, semanticType: type)
                                        }
                                    }
                                }
                            }
                            if !database.timelineSessions.isEmpty {
                                Section("活动") {
                                    ForEach(SessionFusionEngine.fuse(database.timelineSessions), id: \.primary.id) { group in
                                        VStack(alignment: .leading, spacing: 6) {
                                            sessionRow(group.primary)
                                            ForEach(group.secondary) { session in
                                                secondarySessionRow(session)
                                            }
                                        }
                                    }
                                }
                            }
                            if !database.timelineEvents.isEmpty {
                                Section("原始线索") {
                                    ForEach(database.timelineEvents) { item in
                                        eventRow(item)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .overlay {
                            if database.timelineEvents.isEmpty && database.timelineSessions.isEmpty && todayJournalRecord == nil {
                                ContentUnavailableView(
                                    "今天还没有采集到事件",
                                    systemImage: "point.3.connected.trianglepath.dotted",
                                    description: Text("启用位置记录或配置快捷指令后，新的真实事件会先保存在这台设备。")
                                )
                            }
                        }
                        .refreshable { database.refreshTimeline() }
                    }
                } else {
                    ContentUnavailableView {
                        Label("本地事件库不可用", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(node.initializationError ?? "未能初始化安全本地存储。")
                    } actions: {
                        Button("重试") { node.retryOpen() }
                    }
                }
            }
            .navigationTitle("时间线")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let database = node.database {
                        Text("\(database.deviceID.rawValue.prefix(12)) · \(database.timelineEvents.count)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func eventRow(_ item: RiverTimelineEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(item.event.observedAt, style: .time)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(title(for: item))
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(item.event.source)
                    Text("·")
                    Text(item.event.originDeviceID.rawValue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("·")
                    Text("#\(item.event.originSequence)")
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func sessionRow(_ session: RiverAppSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.displayName)
                    .font(.body.weight(.semibold))
                Spacer()
                if let duration = session.duration {
                    Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("进行中 · 待补结束时间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Text(session.start, style: .time)
                Text("–")
                if let end = session.end { Text(end, style: .time) }
                Text("·")
                Text(session.originDeviceID.rawValue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if session.endReason != .observedClose && session.endReason != .observedSessionBoundary {
                    Text("· 推断")
                }
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func secondarySessionRow(_ session: RiverAppSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(.tertiary)
                .frame(width: 2, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text("期间短暂使用 · \(session.displayName)")
                    .font(.caption.weight(.medium))
                HStack(spacing: 5) {
                    Text(session.start, style: .time)
                    Text("–")
                    if let end = session.end { Text(end, style: .time) }
                    if let duration = session.duration {
                        Text("· \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))")
                    }
                    Text("· \(session.originDeviceID.rawValue)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 16)
        .padding(.vertical, 3)
    }

    private func title(for item: RiverTimelineEvent) -> String {
        if let app = item.payload.appName, !app.isEmpty {
            return "使用 \(app)"
        }
        if let place = item.payload.locationName, !place.isEmpty {
            return place
        }
        if item.payload.latitude != nil, item.payload.longitude != nil {
            return "位置记录"
        }
        if let text = item.payload.text, !text.isEmpty {
            return text
        }
        return item.event.kind
    }
}

private struct PlaceDecisionRow: View {
    let place: RiverPlace
    let onSave: (String, String) -> Void
    @State private var name: String
    @State private var type: String

    init(place: RiverPlace, onSave: @escaping (String, String) -> Void) {
        self.place = place
        self.onSave = onSave
        _name = State(initialValue: place.userDefinedName ?? place.mapName ?? "")
        _type = State(initialValue: place.semanticType ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(place.displayName).font(.subheadline.weight(.semibold))
                Spacer()
                if place.isUserConfirmed { Label("已确认", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                else { Text("地点候选").font(.caption).foregroundStyle(.secondary) }
            }
            if let address = place.mapAddress, !address.isEmpty {
                Text(address).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("自定义名称，例如宿舍", text: $name)
                TextField("类型，例如 residence", text: $type)
            }
            Button(place.isUserConfirmed ? "保存地点修改" : "确认地点") { onSave(name, type) }
                .buttonStyle(.bordered)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 4)
    }
}

private struct IPhoneAIReviewCard: View {
    @ObservedObject var ai: IPhoneAIStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("今日整理", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if ai.isGenerating {
                    ProgressView()
                } else {
                    Button(ai.dailyReview == nil ? "分析" : "重新分析") { Task { await ai.analyzeToday() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let review = ai.dailyReview {
                Text(review)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(5)
            } else {
                Text(ai.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = ai.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}
