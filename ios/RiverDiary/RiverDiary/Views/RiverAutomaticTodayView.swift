import Combine
import CoreLocation
import CoreMotion
import Photos
import RiverDiaryCore
import SwiftUI

/// A reading surface over the existing automatic Event/Artifact pipeline, not a second diary store.
struct RiverAutomaticTodayView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.riverUsesSharedHeader) private var usesSharedHeader
    @Environment(\.dynamicTypeSize) private var textSize
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var diary: DiaryStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @State private var revision = 0
    @State private var settings = false
    @State private var reading = false
    @State private var contextDetail: DayContextSnapshot?
    @State private var showsRawEvidence = false
    private var date: Date { coordinator.selectedDate }
    private var rows: [IOSActivityRow] { let _ = revision; guard let db = node.database else { return [] }; return RiverIOSProjection.timelineRows(database: db, date: date) }
    private var facts: [IOSActivityRow] { rows.filter { $0.kind != .riverInsight } }
    private var automaticFacts: [IOSActivityRow] { facts.filter { $0.kind != .note } }
    private var analysis: RiverDayAnalysisSnapshot { let _ = revision; return .load(database: node.database, date: date) }
    private var pipelineUpdates: AnyPublisher<Void, Never> {
        let publishers: [AnyPublisher<Void, Never>] = [
            node.aiStore?.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            node.locationCollector?.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            node.motionCollector?.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            node.photoAnalyzer?.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        ].compactMap { $0 }
        return Publishers.MergeMany(publishers).debounce(for: .milliseconds(100), scheduler: RunLoop.main).eraseToAnyPublisher()
    }
    private var shares: [ObservedTimeShare] {
        let intervals = automaticFacts.compactMap { row -> ObservedTimeInterval? in
            guard !row.isInferred, let duration = row.duration, duration.isFinite, duration > 0 else { return nil }
            let category: String, priority: Int
            switch row.kind { case .app: category = "应用活动"; priority = 3; case .health: category = "运动"; priority = 2; case .place: category = "地点停留"; priority = 1; default: return nil }
            return .init(id: row.id, category: category, start: row.date, end: row.date.addingTimeInterval(duration), priority: priority)
        }
        return ObservedTimeDistribution.calculate(intervals, on: date)
    }
    private var legacy: DiaryEntry? { diary.entries.first { $0.date == RiverIOSProjection.dayKey(date) } }
    private var capturedEvents: [RiverEvent] {
        guard let db = node.database, let end = Calendar.current.date(byAdding: .day, value: 1, to: date) else { return [] }
        return (try? db.events(from: Calendar.current.startOfDay(for: date), to: end)) ?? []
    }
    private var automaticEventCount: Int { capturedEvents.filter { $0.source != "manual" && !$0.kind.hasPrefix("manual.") }.count }
    private var observedMetrics: [RiverEventMetrics] { capturedEvents.sorted { $0.observedAt > $1.observedAt }.compactMap { (try? JSONDecoder().decode(RiverEventPayload.self, from: $0.payload))?.metrics } }
    private var sleepNight: SleepNight? {
        health.nights.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
    }

    private var sleep: Double? {
        observedMetrics.compactMap(\.sleepHours).first
            ?? sleepNight.flatMap { $0.hasAsleepSamples ? $0.totalHours : nil }
            ?? legacy?.health?.sleepHours
    }

    /// 总睡眠含午睡，但要把午睡单独说出来，避免把“补觉”当成整夜睡眠。
    private var healthCaption: String {
        if sleep == nil && steps == nil && calories == nil { return "暂无可用健康数据" }
        if let night = sleepNight, night.hasAsleepSamples, night.nap > 0 {
            let minutes = max(1, Int((night.nap / 60).rounded()))
            return "来自健康摘要 · 含午睡 \(minutes) 分钟"
        }
        return "来自健康摘要"
    }
    private var steps: Int? { observedMetrics.compactMap(\.steps).first ?? legacy?.health?.steps.map { Int($0) } }
    private var calories: Double? { observedMetrics.compactMap(\.activeEnergyKcal).first ?? legacy?.health?.activeEnergyKilocalories }
    private var pendingCount: Int { (node.database?.sharedUserRecords ?? []).filter { ($0.kind == .pendingConfirmation && $0.status == "pending") || ($0.kind == .habitCard && ["bundled", "shown"].contains($0.status)) }.count }
    private var isCollecting: Bool {
        let locationStatus = node.locationCollector?.authorizationStatus
        let location = node.locationCollector?.isEnabled == true && (locationStatus == .authorizedAlways || locationStatus == .authorizedWhenInUse)
        let motion = node.motionCollector?.isEnabled == true && CMMotionActivityManager.authorizationStatus() == .authorized
        let photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let photos = node.photoAnalyzer?.isEnabled == true && (photoStatus == .authorized || photoStatus == .limited)
        let healthConnected = health.isAuthorized && (!health.nights.isEmpty || !health.exerciseDays.isEmpty)
        return location || motion || photos || healthConnected
    }
    private var awaitingAISetup: Bool { node.aiStore?.canAskRiver != true }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if usesSharedHeader { RiverScrollingPageHeading(tab: .timeline) }
                if node.database == nil { RiverIOSDatabaseUnavailablePanel(message: node.initializationError) { node.retryOpen() } }
                else {
                    summary
                    deviceContextCard
                    if textSize.isAccessibilitySize {
                        recordTile; timeTile; healthTile; insightTile
                    } else {
                        VStack(spacing: 17) {
                            HStack(alignment: .top, spacing: 14) { recordTile; timeTile }.fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: 14) { healthTile; insightTile }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    poemCard
                    if pendingCount > 0 {
                        Button { coordinator.openConfirmations() } label: {
                            HStack { Image(systemName: "sparkles"); Text("\(pendingCount) 个理解需要你核对"); Spacer(); Image(systemName: "chevron.right") }.font(.caption.weight(.medium)).foregroundStyle(theme.warning).padding(14).riverNeumorphic(radius: 16)
                        }.buttonStyle(.plain)
                    }
                    HStack {
                        Text("还有想补充的？").font(.caption).foregroundStyle(theme.secondaryInk)
                        Spacer()
                        Button("补充一条线索 ›") { coordinator.presentJournal(on: date) }.font(.caption).foregroundStyle(theme.accentText).frame(minHeight: 44).accessibilityIdentifier("river.today.supplement")
                    }
                }
            }.riverPageEntrance().padding(.horizontal, 22).padding(.top, 5).padding(.bottom, 22)
        }.background(theme.canvas).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $settings, onDismiss: { revision &+= 1 }) { SettingsView() }
            .sheet(item: $contextDetail) { snapshot in
                DeviceContextDetailView(snapshot: snapshot)
            }
            .sheet(isPresented: $showsRawEvidence) {
                RawEvidenceDetailView(groups: rawEvidenceGroups)
            }
            .sheet(isPresented: $reading) {
                NavigationStack { ScrollView { Text(analysis.fullReview ?? "这一天还没有 AI 自动小结。 ").font(.body).lineSpacing(5).padding(22).textSelection(.enabled) }.background(theme.canvas).navigationTitle("这一天的自动日记").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { reading = false } } } }
            }
            .onAppear { node.database?.refreshTimeline(for: date); revision &+= 1 }
            .onChange(of: coordinator.selectedDate) { _, day in node.database?.refreshTimeline(for: day); revision &+= 1 }
            .onChange(of: node.stateRevision) { _, _ in revision &+= 1 }
            .onReceive(pipelineUpdates) { _ in Task { @MainActor in await Task.yield(); revision &+= 1 } }
    }
    private var deviceContexts: [DayContextSnapshot] {
        guard let database = node.database else { return [] }
        let contexts = capturedEvents
            .filter { $0.kind == "dayContextSnapshot" }
            .compactMap { event -> (Date, DayContextSnapshot)? in
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload),
                      let json = payload.contextJSON,
                      let snapshot = DayContextSnapshot.decodeJSON(json),
                      !snapshot.isEmpty,
                      snapshot.deviceID != database.deviceID.rawValue else { return nil }
                return (event.recordedAt, snapshot)
            }
        return Dictionary(grouping: contexts) { "\($0.1.deviceID)|\($0.1.day)" }
            .values.compactMap { group in group.max { $0.0 < $1.0 }?.1 }
            .sorted { $0.deviceName < $1.deviceName }
    }

    private var rawEvidenceGroups: [RawEvidenceGroup] {
        let labels = ["chrome": "浏览器", "notes": "备忘录", "markdown": "Markdown", "kindle": "Kindle"]
        let grouped = Dictionary(grouping: capturedEvents.filter { labels[$0.source] != nil }, by: { $0.source })
        return grouped.compactMap { source, events in
            guard let label = labels[source], !events.isEmpty else { return nil }
            return RawEvidenceGroup(
                id: source,
                label: label,
                items: events.sorted { $0.observedAt < $1.observedAt }.prefix(200).map { $0 }
            )
        }.sorted { $0.label < $1.label }
    }

    private var deviceContextCard: some View {
        let contexts = deviceContexts
        return Group {
            if !contexts.isEmpty {
                RiverIOSPanel(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "iphone").font(.system(size: 17, weight: .medium)).foregroundStyle(theme.accentText)
                            Text("其他设备的一天").font(.headline)
                            Spacer(minLength: 2)
                            Text("设备上下文").font(.caption2).foregroundStyle(theme.secondaryInk)
                        }
                        ForEach(contexts) { context in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(context.deviceName).font(.caption.weight(.medium)).foregroundStyle(theme.ink)
                                ForEach(context.sections) { section in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(section.title).font(.caption).foregroundStyle(theme.secondaryInk)
                                            Spacer(minLength: 2)
                                            Text(section.summary).font(.caption2).foregroundStyle(theme.ink).multilineTextAlignment(.trailing)
                                        }
                                        ForEach(Array(section.items.prefix(2).enumerated()), id: \.offset) { _, item in
                                            Text([item.title, item.detail].compactMap { $0 }.joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundStyle(theme.secondaryInk)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                                Button("查看 \(context.deviceName) 的全部上下文") { contextDetail = context }
                                    .font(.caption)
                                    .foregroundStyle(theme.accentText)
                            }
                            .padding(.vertical, 3)
                        }
                        if !rawEvidenceGroups.isEmpty {
                            Button("查看 Mac 原始明细") { showsRawEvidence = true }
                                .font(.caption)
                                .foregroundStyle(theme.accentText)
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
        }
    }

    private var summary: some View {
        RiverIOSPanel(padding: 18) {
            VStack(alignment: .leading, spacing: 15) {
                HStack { RiverIconChip(symbol: "book"); VStack(alignment: .leading, spacing: 3) { Text(Calendar.current.isDateInToday(date) ? "今日自动小结" : "当日自动小结").font(.headline); Text(node.aiStore?.isGenerating == true ? "River 正在整理生活线索" : analysis.statusText).font(.caption2).foregroundStyle(theme.secondaryInk) }; Spacer(minLength: 2); RiverStatusPill(text: isCollecting ? "自动采集中" : "手机来源待启用", tone: isCollecting ? .positive : .neutral) }
                Text(analysis.overview ?? (automaticFacts.isEmpty ? "开启记录来源后，生活线索会自动保存。连接 AI 并授权资料范围后，River 会自动生成日记。手动补充是可选项。" : awaitingAISetup ? "已自动留下 \(automaticEventCount) 条生活线索。连接 AI 后，River 会把这些记录整理成今日小结。" : "已自动留下 \(automaticEventCount) 条生活线索，River 将根据新的记录自动整理今日小结。"))
                    .font(.subheadline).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).padding(15).riverNeumorphic(inset: true, radius: 17)
                HStack(spacing: 12) {
                    if let steps { badge("\(steps.formatted()) 步", theme.success) }
                    if automaticEventCount == 0 && legacy == nil {
                        Button("写第一句") { coordinator.presentJournal(on: date) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accentText)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 38)
                            .background(theme.accentSoft, in: Capsule())
                            .accessibilityIdentifier("river.today.writeFirst")
                    }
                    if analysis.overview != nil { Button("阅读全文 ›") { reading = true }.font(.caption).foregroundStyle(theme.accentText) }
                    Spacer(minLength: 0)
                    if !isCollecting || awaitingAISetup { Button("连接记录来源 ›") { settings = true }.font(.caption).foregroundStyle(theme.accentText) }
                }
            }
        }
    }
    private var recordTile: some View {
        tile(icon: "bolt", title: "AI 行为记录与梳理", eyebrow: "自动记录", badge: "采集依据", color: .purple) {
            Text("\(automaticEventCount)").font(.system(size: 34, weight: .bold, design: .rounded)) + Text(" 条").font(.caption).foregroundColor(theme.secondaryInk)
            Text(isCollecting ? "持续自动采集" : automaticEventCount > 0 ? "已保存在本机" : "等待连接来源").font(.caption2).foregroundStyle(theme.secondaryInk)
            HStack(spacing: 4) { ForEach(0..<3) { index in Capsule().fill(index == 0 && automaticEventCount > 0 ? Color.purple.opacity(0.65) : theme.separator).frame(height: 4) } }
            Button("查看采集依据 ↗") { coordinator.openFootprints(day: date) }.font(.caption).foregroundStyle(theme.accentText).frame(minHeight: 30)
        }
    }
    private var timeTile: some View {
        tile(icon: "clock", title: "时间分布", eyebrow: "今日流转", badge: "已观测时段", color: theme.accentText) {
            if shares.isEmpty { Text("等待有时长的自动记录").font(.caption).foregroundStyle(theme.secondaryInk).padding(.vertical, 9) }
            else {
                ForEach(shares, id: \.category) { share in
                    VStack(alignment: .leading, spacing: 5) { HStack { Text(share.category); Spacer(minLength: 1); Text("\(share.percentage)%") }.font(.caption2); Text(RiverDayReadingMath.timeText(seconds: share.seconds)).font(.caption2.weight(.semibold)).foregroundStyle(theme.secondaryInk); ProgressView(value: Double(share.percentage), total: 100).tint(theme.accent) }
                }
                Text("来源时段已去重，非全天覆盖").font(.caption2).foregroundStyle(theme.secondaryInk)
            }
        }
    }
    private var healthTile: some View {
        tile(icon: "chart.line.uptrend.xyaxis", title: "运动与健康", eyebrow: "综合监测", badge: "健康摘要", color: .orange) {
            number("睡眠", sleep.map { String(format: "%.1f 小时", $0) } ?? "—")
            number("步数", steps.map { $0.formatted() } ?? "—")
            number("活动热量", calories.map { String(format: "%.0f kcal", $0) } ?? "—")
            Text(healthCaption).font(.caption2).foregroundStyle(theme.secondaryInk)
        }
    }
    private var insightTile: some View {
        tile(icon: "lightbulb", title: "AI 洞察", eyebrow: "记录解读", badge: "随行提示", color: .pink) {
            Text(analysis.moments.first?.detail ?? "随着生活记录积累，River 会整理变化和线索；有疑问的理解才会请你确认。").font(.caption).lineSpacing(3).foregroundStyle(theme.secondaryInk).lineLimit(5)
            Button("问问 River ↗") { coordinator.selectedTab = .river }.font(.caption).foregroundStyle(theme.accentText)
        }
    }
    private func tile<C: View>(icon: String, title: String, eyebrow: String, badge label: String, color: Color, @ViewBuilder content: () -> C) -> some View {
        RiverIOSPanel(padding: 15) {
            VStack(alignment: .leading, spacing: 11) {
                HStack { Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(color).frame(width: 38, height: 38).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14)); Spacer(minLength: 2); Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 6).riverNeumorphic(radius: 13) }
                VStack(alignment: .leading, spacing: 3) { Text(eyebrow).font(.caption2).foregroundStyle(theme.secondaryInk); Text(title).font(.subheadline.weight(.semibold)) }
                content()
            }.frame(maxWidth: .infinity, minHeight: textSize.isAccessibilitySize ? 0 : 205, maxHeight: .infinity, alignment: .topLeading)
        }
    }
    private var poemCard: some View {
        RiverIOSPanel(padding: 22) {
            VStack(spacing: 12) {
                Text("· 送给你的一句诗 ·").font(.caption.weight(.medium)).foregroundStyle(theme.secondaryInk)
                Text("山气日夕佳，飞鸟相与还。").font(.system(size: 18, weight: .medium, design: .serif)).foregroundStyle(theme.ink)
                Text("陶渊明 ·《饮酒》").font(.caption2).foregroundStyle(theme.secondaryInk)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
        }
    }
    private func badge(_ text: String, _ color: Color) -> some View { Text(text).font(.caption2.weight(.medium)).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5).riverNeumorphic(radius: 15) }
    private func number(_ title: String, _ value: String) -> some View { HStack { Text(title).foregroundStyle(theme.secondaryInk); Spacer(minLength: 2); Text(value).fontWeight(.semibold) }.font(.caption).monospacedDigit() }
}

private struct DeviceContextDetailView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let snapshot: DayContextSnapshot

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(snapshot.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.ink)
                                Spacer(minLength: 4)
                                Text(section.summary).font(.caption2).foregroundStyle(theme.secondaryInk)
                            }
                            ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(item.count.map { String($0) } ?? "·")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(theme.secondaryInk.opacity(0.7))
                                        .frame(width: 22, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.caption).foregroundStyle(theme.ink)
                                        if let detail = item.detail, !detail.isEmpty {
                                            Text(detail).font(.caption2).foregroundStyle(theme.secondaryInk)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .padding(22)
            }
            .background(theme.canvas)
            .navigationTitle("\(snapshot.deviceName) 的一天")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct RawEvidenceGroup: Identifiable {
    let id: String
    let label: String
    let items: [RiverEvent]
}

private struct RawEvidenceDetailView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    let groups: [RawEvidenceGroup]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mac \(group.label)（\(group.items.count)）")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(theme.ink)
                            ForEach(group.items) { event in
                                RawEvidenceRow(event: event)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                }
                .padding(22)
            }
            .background(theme.canvas)
            .navigationTitle("Mac 原始明细")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct RawEvidenceRow: View {
    @Environment(\.riverTheme) private var theme
    let event: RiverEvent

    private var payload: RiverEventPayload? {
        try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(payload?.title ?? payload?.url ?? "一条原始记录")
                .font(.caption)
                .foregroundStyle(theme.ink)
                .lineLimit(2)
            if let text = payload?.text, !text.isEmpty, text != payload?.title {
                Text(String(text.prefix(500)))
                    .font(.caption2)
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(4)
            }
            if let url = payload?.url, url != payload?.title {
                Text(url)
                    .font(.caption2.monospaced())
                    .foregroundStyle(theme.secondaryInk)
                    .lineLimit(2)
            }
            Text(event.observedAt, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(theme.secondaryInk)
        }
        .padding(.vertical, 3)
    }
}
