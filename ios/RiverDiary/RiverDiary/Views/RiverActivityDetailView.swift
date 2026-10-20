import MapKit
import RiverDiaryCore
import SwiftUI

struct RiverActivityDetailView: View {
    @Environment(\.riverTheme) private var theme
    let eventID: UUID

    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var database: RiverLocalDatabase? { node.database }
    private struct DetailSnapshot {
        var event: RiverTimelineEvent?
        var session: RiverAppSession?
        var fused: [RiverAppSession] = []
        var evidence: [RiverTimelineEvent] = []
        var insights: [IOSActivityRow] = []
        var rows: [IOSActivityRow] = []
        var loaded = false
        var error: String?
    }
    @State private var detail = DetailSnapshot()
    @State private var retry = 0
    private var event: RiverTimelineEvent? { detail.event }
    private var session: RiverAppSession? { detail.session }
    private var fusedSessions: [RiverAppSession] { detail.fused }
    private var evidenceEvents: [RiverTimelineEvent] { detail.evidence }
    private var matchedPlace: RiverPlace? {
        guard let payload = event?.payload,
              let latitude = payload.latitude, let longitude = payload.longitude else { return nil }
        return database?.places.min {
            Self.meters(latitude, longitude, $0.latitude, $0.longitude)
                < Self.meters(latitude, longitude, $1.latitude, $1.longitude)
        }.flatMap {
            Self.meters(latitude, longitude, $0.latitude, $0.longitude) <= max($0.radiusMeters + 100, 350) ? $0 : nil
        }
    }
    private var relatedInsights: [IOSActivityRow] { detail.insights }
    private var dayRows: [IOSActivityRow] { detail.rows }

    private func loadDetail() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        var result = DetailSnapshot()
        defer { result.loaded = true; detail = result }
        guard let database else { result.error = node.initializationError ?? "本机记录暂不可用。"; return }
        do {
            guard let raw = try database.events(ids: [eventID]).first,
                  let item = Self.timelineEvent(raw) else { return }
            result.event = item
            // One projection read per revision, rather than re-reading history for every label.
            let all = SessionBuilder.isSessionEvent(raw) ? try database.allSessions() : []
            result.session = all.first { $0.evidenceEventIDs.contains(eventID) }
            if let session = result.session {
                if let group = SessionFusionEngine.fuse(all).first(where: { $0.primary.id == session.id || $0.secondary.contains(where: { $0.id == session.id }) }) {
                    result.fused = [group.primary] + group.secondary
                } else { result.fused = [session] }
            }
            let ids = Array(Set([eventID] + result.fused.flatMap(\.evidenceEventIDs)))
            result.evidence = try database.events(ids: ids).compactMap(Self.timelineEvent)
                .sorted { $0.event.observedAt < $1.event.observedAt }
            result.rows = RiverIOSProjection.timelineRows(database: database, date: raw.observedAt)
            result.insights = RiverIOSProjection.timelineInsights(database: database, date: raw.observedAt).filter { $0.eventIDs.contains(eventID) }
        } catch { result.error = "记录暂时无法读取：\(error.localizedDescription)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !detail.loaded {
                    ProgressView("正在打开记录…").frame(maxWidth: .infinity, minHeight: 160)
                } else if let error = detail.error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(.body)
                        Button("重新读取") { retry += 1 }.frame(minHeight: 44)
                    }.padding(20)
                } else if let event {
                    themeDetailOpening(event)
                    observationCard(event)
                    ForEach(relatedInsights) { insight in insightCard(insight) }
                    if let session { sessionCard(session) }
                    if let matchedPlace { placeLink(matchedPlace, event: event) }
                    evidenceCard(event)
                } else {
                    ContentUnavailableView("找不到这条记录", systemImage: "questionmark.folder",
                                            description: Text("记录可能来自另一个日期或已被更新。你可以返回 Timeline 重新打开。"))
                }
            }
            .padding(20)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 120 : 24)
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .task(id: "\(eventID.uuidString)-\(node.stateRevision)-\(retry)") { await loadDetail() }
        .navigationTitle("活动详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func themeDetailOpening(_ item: RiverTimelineEvent) -> some View {
        RiverThemeReadingLead(title: title(for: item), timestamp: eventTimestampLabel(item), source: RiverIOSProjection.sourceLabel(item.event.source))
    }

    private func observationCard(_ item: RiverTimelineEvent) -> some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("观察到的记录").font(.headline)
                    Spacer()
                    Text(item.payload.appName == nil && item.payload.text == nil ? "事实" : "来源记录")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.secondaryInk)
                }
                LabeledContent("时间", value: eventTimestampLabel(item))
                if let app = item.payload.appName { LabeledContent("应用", value: app) }
                if let title = item.payload.windowTitle, !title.isEmpty {
                    LabeledContent("窗口标题", value: title)
                }
                if let text = item.payload.text, !text.isEmpty {
                    Text(text).font(.body).textSelection(.enabled)
                }
                if item.payload.metrics != nil {
                    metrics(item.payload.metrics)
                }
                if item.payload.latitude != nil, item.payload.longitude != nil {
                    Label(item.payload.locationName ?? item.payload.mapAddress ?? "位置坐标已保存在本机", systemImage: "location")
                        .font(.subheadline)
                }
            }
        }
    }

    private func sessionCard(_ session: RiverAppSession) -> some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 9) {
                Text("活动时间范围").font(.headline)
                Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end?.formatted(date: .omitted, time: .shortened) ?? "仍在进行")")
                    .font(.body.monospacedDigit())
                Text(session.quality == .observed && session.end != nil
                     ? "开始与结束时间均有应用事件依据。"
                     : "结束时间没有直接记录，当前显示的是暂定时间范围。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                if fusedSessions.count > 1 {
                    Text("同时段内，另一台设备也有重叠活动记录：")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.secondaryInk)
                    ForEach(fusedSessions.filter { $0.id != session.id }) { related in
                        Text("\(related.displayName) · \(related.originDeviceID.rawValue.hasPrefix("mac") ? "Mac" : "iPhone") · \(related.start.formatted(date: .omitted, time: .shortened))–\(related.end?.formatted(date: .omitted, time: .shortened) ?? "时间未结束")")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryInk)
                    }
                }
                let evidenceCount = Set(fusedSessions.flatMap(\.evidenceEventIDs)).count
                Text("包含 \(evidenceCount) 条应用事件依据。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
        }
    }

    private func insightCard(_ insight: IOSActivityRow) -> some View {
        RiverIOSPanel(fill: theme.riverSurface) {
            VStack(alignment: .leading, spacing: 8) {
                Label(insight.sourceLabel, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accentText)
                Text(insight.title).font(.headline)
                Text(insight.detail)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("这是一条暂定理解，依据可在下方展开；如有相关待确认项，可在待确认页面纠正。")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
            }
        }
    }

    private func placeLink(_ place: RiverPlace, event: RiverTimelineEvent) -> some View {
        Button {
            coordinator.openPlace(place.id, date: event.event.observedAt)
        } label: {
            RiverIOSPanel {
                HStack(spacing: 12) {
                    Image(systemName: "map.fill")
                        .font(.title3)
                        .foregroundStyle(theme.accentText)
                        .frame(width: 42, height: 42)
                        .background(theme.placeSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("在足迹中查看").font(.subheadline.weight(.semibold))
                        Text(place.displayName).font(.caption).foregroundStyle(theme.secondaryInk)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func evidenceCard(_ item: RiverTimelineEvent) -> some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text("来源与状态").font(.headline)
                LabeledContent("来源", value: RiverIOSProjection.sourceLabel(item.event.source))
                LabeledContent("记录状态", value: session?.quality == .inferred ? "时间为估算" : "本机已保存")
                if !evidenceEvents.isEmpty {
                    DisclosureGroup("查看全部 \(evidenceEvents.count) 条来源记录") {
                        VStack(alignment: .leading, spacing: 9) {
                            ForEach(evidenceEvents) { evidence in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(eventTimestampLabel(evidence)) · \(title(for: evidence))")
                                        .font(.caption.weight(.medium))
                                    Text("\(RiverIOSProjection.sourceLabel(evidence.event.source)) · \(evidence.event.kind)")
                                        .font(.caption2)
                                        .foregroundStyle(theme.secondaryInk)
                                }
                            }
                        }
                        .padding(.top, 7)
                    }
                    .font(.subheadline)
                }
                DisclosureGroup("查看技术依据") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("记录类型：\(item.event.kind)")
                        Text("事件编号：\(item.event.id.uuidString)")
                        Text("设备：\(item.event.originDeviceID.rawValue)")
                        Text("设备序号：\(item.event.originSequence)")
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(theme.secondaryInk)
                    .textSelection(.enabled)
                    .padding(.top, 8)
                }
                .font(.subheadline)
            }
        }
    }

    private func eventTimestampLabel(_ item: RiverTimelineEvent) -> String {
        if item.event.kind == "health.sleep.snapshot" || item.event.kind == "health.exercise.snapshot" {
            return "\(item.event.observedAt.formatted(date: .abbreviated, time: .omitted)) · 全天汇总"
        }
        return item.event.observedAt.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private func metrics(_ value: RiverEventMetrics?) -> some View {
        if let value {
            VStack(alignment: .leading, spacing: 5) {
                if let sleep = value.sleepHours { Text(String(format: "睡眠 %.1f 小时", sleep)) }
                if let steps = value.steps { Text("步数 \(steps.formatted())") }
                if let distance = value.distanceKm { Text(String(format: "距离 %.1f 公里", distance)) }
                if let calories = value.activeEnergyKcal { Text("活动能量 \(Int(calories.rounded())) 千卡") }
                if let screen = value.screenMinutes { Text("屏幕活动 \(screen) 分钟") }
            }
            .font(.subheadline)
        }
    }

    private func title(for item: RiverTimelineEvent) -> String {
        if let text = item.payload.text, !text.isEmpty { return text }
        if let app = item.payload.appName, !app.isEmpty { return "使用 \(app)" }
        if let place = item.payload.locationName, !place.isEmpty { return place }
        if item.payload.metrics != nil { return "健康记录" }
        return "生活线索"
    }

    private static func timelineEvent(_ event: RiverEvent) -> RiverTimelineEvent? {
        guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
        return RiverTimelineEvent(event: event, payload: payload)
    }

    private static func meters(_ latitude: Double, _ longitude: Double, _ otherLatitude: Double, _ otherLongitude: Double) -> Double {
        let radius = 6_371_000.0
        let lat = (otherLatitude - latitude) * .pi / 180
        let lon = (otherLongitude - longitude) * .pi / 180
        let a = sin(lat / 2) * sin(lat / 2)
            + cos(latitude * .pi / 180) * cos(otherLatitude * .pi / 180) * sin(lon / 2) * sin(lon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

struct RiverPlaceDetailView: View {
    @Environment(\.riverTheme) private var theme
    let placeID: String

    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var diary: DiaryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var name = ""
    @State private var category = ""
    @State private var feedback: String?
    @State private var didLoadDraft = false

    private var place: RiverPlace? { node.database?.places.first { $0.id == placeID } }
    private var camera: MapCameraPosition {
        guard let place else { return .automatic }
        return .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                          span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let place {
                    RiverIOSPageHeader(title: place.isUserConfirmed ? "你已确认的地点" : "地图候选地点 · \(place.displayName)",
                                      subtitle: place.mapAddress ?? "此名称来自多次位置线索的地图匹配。")
                    Map(initialPosition: camera) {
                        Marker(place.displayName, coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
                            .tint(theme.accent)
                    }
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: theme.mapRadius, style: .continuous))
                    RiverIOSPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("地点故事").font(.headline)
                            LabeledContent("到访次数", value: "\(place.visitCount)")
                            LabeledContent("首次记录", value: place.firstSeen.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("最近记录", value: place.lastSeen.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("累计停留", value: Duration.seconds(place.totalDurationSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                            Text(place.isUserConfirmed ? "这个地点名称来自你的确认。" : "地图名称是候选理解，可以按你的实际称呼修改。")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryInk)
                        }
                    }
                    RiverIOSPanel {
                        VStack(alignment: .leading, spacing: 11) {
                            Text("地点名称与类型").font(.headline)
                            TextField("地点名称", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("地点名称")
                            TextField("地点类型，例如学校或图书馆", text: $category)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("地点类型")
                            Button("保存地点更正") { savePlace() }
                                .buttonStyle(.borderedProminent)
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if let feedback { Text(feedback).font(.caption).foregroundStyle(theme.secondaryInk) }
                        }
                    }
                } else {
                    ContentUnavailableView("找不到这个地点", systemImage: "mappin.slash",
                                            description: Text("地点可能已合并或被更新。返回足迹查看当前地点。"))
                }
            }
            .padding(20)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 120 : 0)
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("地点故事")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didLoadDraft, let place else { return }
            name = place.userDefinedName ?? place.mapName ?? ""
            category = place.semanticType ?? place.poiCategory ?? ""
            didLoadDraft = true
        }
    }

    private func savePlace() {
        guard let place else { return }
        guard node.savePlaceDecision(placeID: place.id, name: name, semanticType: category.isEmpty ? "userDefined" : category) else {
            feedback = node.lastCaptureError ?? "地点更正保存失败。"
            return
        }
        if drive.hasAccess { node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate) }
        feedback = drive.hasAccess ? "已保存在本机，等待加密同步核对。" : "已保存在本机；连接共享文件夹后会继续同步。"
    }
}

struct RiverQuestionEvidenceView: View {
    @Environment(\.riverTheme) private var theme
    let questionID: UUID
    var onOpenEvent: ((UUID, Date) -> Void)? = nil
    var onOpenPlace: ((String, Date?) -> Void)? = nil
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var record: RiverSharedStateRecord? { node.database?.sharedUserRecords.first { $0.id == questionID } }
    private var content: RiverPendingConfirmationContent? { record?.pendingConfirmationContent }
    private var habitPayload: [String: Any] {
        guard record?.kind == .habitCard, let data = record?.payloadJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private var evidenceIDs: [UUID] {
        let references = content?.evidenceRefs ?? habitPayload["evidenceRefs"] as? [String] ?? []
        return references.compactMap { raw in
            UUID(uuidString: raw) ?? UUID(uuidString: raw.split(separator: ":").last.map(String.init) ?? "")
        }
    }
    private var evidenceEvent: RiverTimelineEvent? {
        guard let id = evidenceIDs.first else { return nil }
        return node.database?.timelineEvents.first { $0.id == id }
            ?? ((try? node.database?.events(ids: [id])) ?? []).first.flatMap { event in
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
                return RiverTimelineEvent(event: event, payload: payload)
            }
    }

    private var availableEvidence: [RiverEvent] { (try? node.database?.events(ids: evidenceIDs)) ?? [] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RiverIOSPageHeader(title: content?.title ?? "查看依据",
                                  subtitle: content?.question ?? habitPayload["question"] as? String ?? "问题已在另一台设备处理，或当前内容无法读取。")
                if let content {
                    RiverIOSPanel(fill: theme.riverSurface) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(content.question).font(.headline)
                            if !content.detail.isEmpty {
                                Text(content.detail).font(.body).fixedSize(horizontal: false, vertical: true)
                            }
                            if let candidate = content.candidate, !candidate.isEmpty {
                                Text("River 的候选理解：\(candidate)")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                    RiverIOSPanel {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("为什么会问你").font(.headline)
                            if let event = evidenceEvent {
                                Text("这条问题引用了 \(evidenceIDs.count) 条来源中的一条。")
                                    .font(.subheadline)
                                Text("\(event.event.observedAt.formatted(date: .abbreviated, time: .shortened)) · \(event.payload.appName ?? event.payload.locationName ?? event.payload.text ?? "生活记录")")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryInk)
                                Button("查看对应时间线") {
                                    if let onOpenEvent { onOpenEvent(event.id, event.event.observedAt) } else { coordinator.openTimeline(eventID: event.id, date: event.event.observedAt) }
                                }
                                .font(.subheadline.weight(.semibold))
                            } else if content.targetType == "place", let placeID = content.targetID {
                                Text(content.detail.isEmpty ? "这是根据重复位置记录与地图候选生成的地点问题。" : content.detail)
                                    .font(.subheadline)
                                Button("在足迹中查看地点") { if let onOpenPlace { onOpenPlace(placeID, record?.createdAt) } else { coordinator.openPlace(placeID, date: record?.createdAt) } }
                                    .font(.subheadline.weight(.semibold))
                            } else {
                                Text("当前设备没有这条问题引用的活动详情。问题内容与回答仍保存在共享记录中。")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                } else if record?.kind == .habitCard {
                    RiverIOSPanel(fill: theme.riverSurface) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text(habitPayload["question"] as? String ?? "习惯线索")
                                .font(.headline)
                            if let lead = habitPayload["lead"] as? String, !lead.isEmpty {
                                Text(lead).font(.body).fixedSize(horizontal: false, vertical: true)
                            }
                            if let app = habitPayload["appName"] as? String, !app.isEmpty {
                                Label("应用记录：\(app)", systemImage: "app.dashed")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                    let examples = habitPayload["examples"] as? [[String: Any]] ?? []
                    if !examples.isEmpty {
                        RiverIOSPanel {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("问题依据").font(.headline)
                                ForEach(Array(examples.enumerated()), id: \.offset) { index, example in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(example["dateText"] as? String ?? example["dayKey"] as? String ?? "一条记录")
                                            .font(.subheadline.weight(.medium))
                                        HStack(spacing: 7) {
                                            if let app = example["appName"] as? String { Text(app) }
                                            if let seconds = example["duration"] as? NSNumber {
                                                Text(Duration.seconds(seconds.doubleValue).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                                            }
                                            if let place = example["placeSummary"] as? String { Text(place) }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryInk)
                                    }
                                    if index < examples.count - 1 {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }
                }
                if !availableEvidence.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("原始记录").font(theme.sectionFont)
                        ForEach(availableEvidence) { event in
                            let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload)
                            Button {
                                if let onOpenEvent { onOpenEvent(event.id, event.observedAt) } else { coordinator.openTimeline(eventID: event.id, date: event.observedAt) }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(event.observedAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote.monospacedDigit()).foregroundStyle(theme.secondaryInk)
                                    Text(payload?.text ?? payload?.appName ?? payload?.locationName ?? "生活记录").font(.body).foregroundStyle(theme.ink)
                                    Text(event.source).font(.footnote).foregroundStyle(theme.secondaryInk)
                                }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider().overlay(theme.separator)
                        }
                    }
                }

            }
            .padding(20)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 120 : 0)
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("回答依据")
        .navigationBarTitleDisplayMode(.inline)
    }
}
