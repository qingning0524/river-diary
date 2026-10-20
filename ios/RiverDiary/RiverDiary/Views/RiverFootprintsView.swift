import CoreLocation
import Combine
import MapKit
import RiverDiaryCore
import SwiftUI
import UIKit

struct RiverFootprintsView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.riverUsesSharedHeader) private var usesSharedHeader
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var selectedStopID: String?
    @State private var hasPositionedMap = false
    @State private var locationRevision = 0
    @State private var timelineRefreshToken = 0
    @State private var showingCalendar = false
    @State private var viewMode: FootprintViewMode = .timeline
    @State private var timelineFilter: FootprintFilter = .all
    @State private var returnAnchor: String?
    @State private var readingRecord: IOSActivityRow?
    @State private var query = ""
    @State private var showingTools = false

    private enum FootprintViewMode: String, CaseIterable { case timeline = "时间线", map = "地图" }

    private var date: Date { coordinator.selectedDate }
    private var database: RiverLocalDatabase? { node.database }
    private var stops: [RiverFootprintStop] {
        let _ = timelineRefreshToken
        return RiverIOSProjection.footprintStops(events: database?.timelineEvents ?? [], places: database?.places ?? [])
    }
    private var timelineRows: [IOSActivityRow] {
        let _ = timelineRefreshToken
        guard let database else { return [] }
        var result = RiverIOSProjection.timelineRows(database: database, date: date)
        if let record = database.sharedUserRecords.first(where: { $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == RiverIOSProjection.dayKey(date) }),
           let content = record.journalEntryContent, !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(IOSActivityRow(id: "journal:\(content.dayKey)", date: date, title: "这一天的手写日记", detail: content.body,
                                         sourceLabel: "自己写下 · 最后编辑于 \(content.updatedAt.formatted(date: .abbreviated, time: .shortened))",
                                         kind: .note, eventIDs: [], placeID: nil, duration: nil, isInferred: false, timeLabel: "当天手记"))
        }
        return result
    }
    private var locationStatus: String { node.locationCollector?.statusText ?? "位置记录暂不可用" }
    private var hasLocations: Bool { !stops.isEmpty }
    private var selectedStop: RiverFootprintStop? { stops.first { $0.id == selectedStopID } }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Group { if !usesSharedHeader { pageHeader } else { RiverScrollingPageHeading(tab: .footprints) } }.id("footprints.top")

                if database == nil {
                    RiverIOSDatabaseUnavailablePanel(message: node.initializationError) { node.retryOpen() }
                } else {
                    if !usesSharedHeader {
                    HStack(spacing: 8) {
                        ForEach(FootprintViewMode.allCases, id: \.self) { mode in
                            Button {
                                RiverHaptics.selection()
                                viewMode = mode
                            } label: {
                                Text(mode.rawValue).font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(viewMode == mode ? theme.accentText : theme.secondaryInk)
                                    .background(viewMode == mode ? theme.surface : theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier(mode == .timeline ? "river.footprints.mode.timeline" : "river.footprints.mode.map")
                                .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
                        }
                    }.padding(3)
                        .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
                    }
                    if usesSharedHeader || viewMode == .timeline {
                        if usesSharedHeader {
                            RiverIOSPanel(padding: 14, referenceGradient: true) {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(spacing: 6) { Circle().fill(theme.accent).frame(width: 7, height: 7); Text(Calendar.current.isDateInToday(date) ? "今日生活轨迹" : "当日生活轨迹").font(.system(size: 14, weight: .bold)); Spacer(); Text("✦ \(stops.count) 处停留点").font(.system(size: 11)).foregroundStyle(theme.secondaryInk) }
                                    mapPanel
                                    HStack(spacing: 6) {
                                        Button {
                                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("footprints.timeline", anchor: .top) }
                                        } label: { Text("生活片段 ↓").font(.system(size: 11, weight: .medium)) }
                                            .foregroundStyle(theme.secondaryInk).accessibilityIdentifier("river.footprints.jumpToTimeline")
                                        Spacer(minLength: 0)
                                        if node.locationCollector?.isEnabled == false {
                                            Button("开启记录 ›") { coordinator.selectedTab = .me; coordinator.mePath.append(.settings) }.font(.system(size: 10)).foregroundStyle(theme.secondaryInk)
                                        } else if hasLocations { Text("✓ 已记录").font(.system(size: 10)).foregroundStyle(theme.success) }
                                        Button { showingTools = true } label: { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 13)).frame(width: 44, height: 44) }.foregroundStyle(theme.secondaryInk).accessibilityLabel("搜索与筛选足迹")
                                    }
                                }
                            }
                        }
                        if !usesSharedHeader { recordSearch }
                        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || timelineFilter != .all {
                            HStack(spacing: 8) {
                                Label((timelineFilter == .all ? "全部类型" : timelineFilter.title) + (query.isEmpty ? "" : " · \(query)"), systemImage: "line.3.horizontal.decrease").font(.caption).lineLimit(1)
                                Spacer(minLength: 0)
                                Button("清除") { query = ""; timelineFilter = .all }.font(.caption.weight(.medium)).frame(minHeight: 44)
                            }.foregroundStyle(theme.accentText).padding(.horizontal, 12).riverNeumorphic(inset: true, radius: 14)
                        }
                        RiverFootprintTimelineView(date: date, rows: timelineRows, searchQuery: query, onOpen: openRecord,
                                                   canLocate: { locatedStop(for: $0) != nil }, onLocate: { row in
                            if let stop = locatedStop(for: row) { returnAnchor = row.id; viewMode = .map; select(stop) }
                        }, filterSelection: $timelineFilter, pendingCount: pendingInterpretations, onPending: { coordinator.openConfirmations() }).id("footprints.timeline")
                    } else {
                        if dynamicTypeSize.isAccessibilitySize {
                            Text("地点列表可独立阅读，也可以查看下方地图。").font(.footnote).foregroundStyle(theme.secondaryInk)
                        }
                        mapPanel
                        if locationStatus == "已拒绝" || locationStatus == "受系统限制" { permissionStatusPanel }
                        else if node.locationCollector?.isEnabled == false { recordingStatusPanel }
                        if hasLocations { placeStories } else { emptyFootprints }
                    }
                }
            }
            .riverPageEntrance()
            .padding(.horizontal, theme.footprintGutter)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("river.footprints.scroll")
        .task(id: viewMode) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            var target = viewMode == .timeline ? returnAnchor ?? "footprints.top" : "footprints.top"
            #if DEBUG
            if Bundle.main.bundleIdentifier == "studio.riverdiary.ios.qa", ProcessInfo.processInfo.arguments.contains("--riverdiary-qa-scroll-to-timeline") { target = "footprints.timeline" }
            #endif
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
        }
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingCalendar) { calendarPicker }
        .sheet(isPresented: $showingTools) {
            NavigationStack {
                Form {
                    Section("查找生活片段") { TextField("输入关键词", text: $query).autocorrectionDisabled().textInputAutocapitalization(.never) }
                    Section("片段类型") { Picker("类型", selection: $timelineFilter) { ForEach(FootprintFilter.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline) }
                    if !query.isEmpty || timelineFilter != .all { Button("清除筛选") { query = ""; timelineFilter = .all } }
                }.navigationTitle("搜索与筛选").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingTools = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(item: $readingRecord) { row in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RiverThemeReadingLead(title: row.title, timestamp: row.timeLabel ?? row.date.formatted(date: .omitted, time: .shortened), source: row.sourceLabel)
                        Text(row.detail).font(.body).lineSpacing(5).foregroundStyle(theme.ink).padding(.horizontal, 24)
                    }.padding(.bottom, 24)
                }.background(theme.canvas).navigationTitle("记录正文").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭记录") { readingRecord = nil } } }
            }.environment(\.riverTheme, theme)
        }
        .onAppear {
            refreshTimeline(for: date)
            updateCameraIfNeeded()
        }
        .onChange(of: coordinator.selectedDate) { _, newDate in
            refreshTimeline(for: newDate)
            selectedStopID = nil
            timelineFilter = .all; returnAnchor = nil; query = ""
            hasPositionedMap = false
            updateCameraIfNeeded()
        }
        .onChange(of: coordinator.journalSaveRevision) { _, _ in refreshTimeline(for: date) }
        .onChange(of: node.stateRevision) { _, _ in
            refreshTimeline(for: date)
            if let id = selectedStopID, !stops.contains(where: { $0.id == id }) { selectedStopID = nil }
            updateCameraIfNeeded()
        }
        .onReceive(locationChanges) { _ in
            locationRevision &+= 1
            refreshTimeline(for: date)
            updateCameraIfNeeded()
        }
    }

    private var selectedDateBinding: Binding<Date> {
        Binding(get: { coordinator.selectedDate }, set: { coordinator.selectedDate = Calendar.current.startOfDay(for: $0) })
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            RiverSystemSignature()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("记录").font(theme.titleFont).foregroundStyle(theme.ink)
                        .accessibilityIdentifier("river.records.title")
                    Text("生活留下的每一段线索").font(.subheadline).foregroundStyle(theme.secondaryInk)
                }
                Spacer(minLength: 12)
                Button { coordinator.presentJournal(on: date) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 18))
                        .frame(width: 48, height: 48)
                        .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 14))
                }.accessibilityLabel("为这一天写日记").accessibilityIdentifier("river.records.write")
            }
            HStack(spacing: 8) {
                Button { moveDate(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 44)
                }.accessibilityLabel("前一天").accessibilityIdentifier("river.footprints.previous")
                Button { showingCalendar = true } label: {
                    HStack(spacing: 6) {
                        Text(date.formatted(.dateTime.month().day().weekday(.abbreviated)))
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                        Image(systemName: "chevron.down").font(.caption2)
                    }.frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityLabel("选择日期").accessibilityIdentifier("river.footprints.calendar")
                Button { moveDate(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 44)
                }.accessibilityLabel("后一天").accessibilityIdentifier("river.footprints.next")
                    .disabled(Calendar.current.isDateInToday(date))
                if !Calendar.current.isDateInToday(date) {
                    Button("今天") { coordinator.selectedDate = Calendar.current.startOfDay(for: .now) }
                        .font(.subheadline).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("river.records.today")
                }
            }
            .background(theme.raisedSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).foregroundStyle(theme.accentText)
    }

    private var recordSearch: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryInk)
            TextField("查找这一天的记录", text: $query)
                .font(.body).autocorrectionDisabled()
                .accessibilityIdentifier("river.records.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("清除记录查找")
            }
        }.padding(.horizontal, 14).frame(minHeight: 48)
            .riverNeumorphic(inset: true, radius: 14)
    }
    private var pendingInterpretations: Int {
        (database?.sharedUserRecords ?? []).filter { ($0.kind == .pendingConfirmation && $0.status == "pending") || ($0.kind == .habitCard && ["bundled", "shown"].contains($0.status)) }.count
    }
    private func moveDate(_ delta: Int) {
        guard let target = Calendar.current.date(byAdding: .day, value: delta, to: date),
              target <= Calendar.current.startOfDay(for: .now) else { return }
        RiverHaptics.selection()
        coordinator.selectedDate = Calendar.current.startOfDay(for: target)
    }
    private func openRecord(_ row: IOSActivityRow) {
        if let id = row.routeEventID { coordinator.footprintsPath.append(.activity(id)) }
        else { readingRecord = row }
    }
    private func locatedStop(for row: IOSActivityRow) -> RiverFootprintStop? {
        guard row.kind == .place || row.kind == .riverInsight || row.kind == .photo else { return nil }
        return stops.first { stop in
            (row.placeID != nil && stop.placeID == row.placeID) || !Set(row.eventIDs).isDisjoint(with: stop.eventIDs)
        }
    }

    private var calendarPicker: some View {
        NavigationStack {
            DatePicker("选择日期", selection: selectedDateBinding, in: ...Date(), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .padding(20)
                .navigationTitle("选择日期")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { showingCalendar = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showingCalendar = false } }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func refreshTimeline(for date: Date) {
        database?.refreshTimeline(for: date)
        timelineRefreshToken &+= 1
    }

    private var locationChanges: AnyPublisher<Void, Never> {
        guard let collector = node.locationCollector else { return Empty<Void, Never>().eraseToAnyPublisher() }
        return collector.objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    private var mapPanel: some View {
        ZStack {
            if hasLocations {
                Map(position: $mapPosition, interactionModes: [.pan, .zoom, .rotate]) {
                    if stops.count > 1 {
                        MapPolyline(coordinates: stops.sorted { $0.firstSeen < $1.firstSeen }.map(\.coordinate))
                            .stroke(theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        Annotation(stop.displayTitle, coordinate: stop.coordinate, anchor: .bottom) {
                            Button {
                                select(stop)
                            } label: {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(selectedStopID == stop.id ? theme.palette.onAccent : theme.accentText)
                                    .frame(width: 32, height: 32)
                                    .background(selectedStopID == stop.id ? theme.accent : theme.surface, in: Circle())
                                    .overlay(Circle().strokeBorder(theme.accent, lineWidth: 2))
                                    .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
                                .frame(width: theme.tapTarget, height: theme.tapTarget)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(stop.displayTitle)，\(stop.firstSeen.formatted(date: .omitted, time: .shortened))")
                            .accessibilityHint("查看地图上这个地点的故事")
                        }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
                .mapControls { MapCompass(); MapScaleView() }
            } else {
                RiverEmptyFootprintMap()
            }
        }
        .frame(height: hasLocations ? 180 : 130)
        .clipShape(RoundedRectangle(cornerRadius: theme.mapRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.mapRadius).strokeBorder(theme.separator, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if hasLocations {
                Text("停留点连线示意").font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule()).padding(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hasLocations {
                Button {
                    selectedStopID = nil; hasPositionedMap = false; updateCameraIfNeeded()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.ink)
                        .frame(width: 44, height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("显示全部地点")
                    .accessibilityIdentifier("river.footprints.map.reset").padding(10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("当天足迹地图，共 \(stops.count) 段位置线索")
        .accessibilityIdentifier("river.footprints.map")
    }

    private var placeStories: some View {
        VStack(alignment: .leading, spacing: 11) {
            RiverIOSSectionHeading(title: placeStoriesTitle, detail: "地点与记录相互定位")
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                let activities = relatedActivities(for: stop)
                RiverIOSPanel(fill: selectedStopID == stop.id ? theme.placeSurface : theme.surface) {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            select(stop)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(theme.accentText)
                                .frame(width: 28, height: 28)
                                .background(theme.accent.opacity(0.13), in: Circle())
                            VStack(alignment: .leading, spacing: 6) {
                                if dynamicTypeSize.isAccessibilitySize {
                                    Text(stop.displayTitle)
                                        .font(.headline)
                                        .foregroundStyle(theme.ink)
                                    Text(stopTimeLabel(stop))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(theme.secondaryInk)
                                } else {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(stop.displayTitle)
                                            .font(.headline)
                                            .foregroundStyle(theme.ink)
                                        Spacer()
                                        Text(stopTimeLabel(stop))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(theme.secondaryInk)
                                    }
                                }
                                if !stop.subtitle.isEmpty {
                                    Text(stop.subtitle)
                                        .font(.callout)
                                        .foregroundStyle(theme.secondaryInk)
                                }
                                if let accuracy = stop.horizontalAccuracyMeters {
                                    Text("系统估计位置误差半径约 ±\(Int(accuracy.rounded())) 米")
                                        .font(.footnote)
                                        .foregroundStyle(theme.secondaryInk)
                                }
                                Text(storySummary(stop))
                                    .font(.subheadline)
                                    .foregroundStyle(theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        }
                        .buttonStyle(.plain)
                        if !activities.isEmpty {
                            Text("同一到访时段的记录").font(.footnote.weight(.medium)).foregroundStyle(theme.secondaryInk)
                            ForEach(activities) { activity in
                                Button {
                                    guard let eventID = activity.routeEventID else { return }
                                    coordinator.footprintsPath.append(.activity(eventID))
                                } label: {
                                    HStack {
                                        Text("\(activity.date.formatted(date: .omitted, time: .shortened)) · \(activity.title)").font(.callout).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(theme.accentText)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityHint("打开对应的原始记录")
                            }
                        }
                        stopActions(for: stop)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var placeStoriesTitle: String { "到访与停留" }

    private var emptyFootprints: some View {
        RiverIOSPanel(padding: 8, fill: theme.surface) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "map")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.accentText)
                    .frame(width: 28, height: 28)
                    .background(theme.placeSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("这一天还没有位置线索")
                        .font(.subheadline.weight(.semibold))
                    Text("开启后从现在开始记录，不会回填未记录的位置。")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    if locationStatus == "已拒绝" || locationStatus == "受系统限制" {
                        Button {
                            openSystemSettings()
                        } label: {
                            Text("前往系统设置")
                                .frame(minHeight: theme.tapTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .font(.caption.weight(.semibold))
                    } else if node.locationCollector?.isEnabled == true {
                        Label("等待系统交付新的到访线索 · \(locationStatus)", systemImage: "clock")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryInk)
                    } else {
                        Button {
                            node.locationCollector?.setEnabled(true)
                        } label: {
                            Label(Calendar.current.isDateInToday(date) ? "了解并开启足迹记录" : "从今天起开启足迹记录", systemImage: "location")
                                .frame(minHeight: theme.tapTarget, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(node.locationCollector == nil)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var recordingStatusPanel: some View {
        Label("位置记录已暂停 · 权限：\(locationStatus) · 已保存足迹可查看", systemImage: "location.slash")
            .font(.callout)
            .foregroundStyle(theme.secondaryInk)
            .padding(.horizontal, 4)
            .padding(.top, 20)
    }

    private var permissionStatusPanel: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 8) {
                Label("位置权限已关闭", systemImage: "location.slash")
                    .font(.subheadline.weight(.semibold))
                Text("可以继续查看已有足迹；开启权限后才会记录新的地点线索。")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryInk)
                Button {
                    openSystemSettings()
                } label: {
                    Text("前往系统设置")
                        .frame(minHeight: theme.tapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func storySummary(_ stop: RiverFootprintStop) -> String {
        if stop.eventIDs.count > 1 {
            return "本次到访记录包含 \(stop.eventIDs.count) 条位置线索。"
        }
        return "有一条位置线索；停留时长目前未知。"
    }

    @ViewBuilder
    private func stopActions(for stop: RiverFootprintStop) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text("\(stop.eventIDs.count) 条位置线索")
                    if stop.isNameCandidate {
                        Text("地点名称待核实")
                    } else if stop.placeID != nil {
                        Text("你已确认")
                    }
                }
                if let placeID = stop.placeID {
                    NavigationLink(value: RiverAppRoute.place(placeID)) {
                        Label(stop.isNameCandidate ? "查看并更正地点名称" : "查看地点详情", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: theme.tapTarget, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("查看地点来源，或更正 River 的候选名称")
                }
                Button {
                    openTimeline(for: stop)
                } label: {
                    Label("查看对应时间线", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: theme.tapTarget, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(theme.accentText)
        } else {
            HStack(spacing: 9) {
                Text("\(stop.eventIDs.count) 条位置线索")
                if stop.isNameCandidate {
                    Text("地图候选")
                } else if stop.placeID != nil {
                    Text("你已确认")
                }
                Spacer(minLength: 3)
                if let placeID = stop.placeID {
                    NavigationLink(value: RiverAppRoute.place(placeID)) {
                        Label(stop.isNameCandidate ? "更正地点" : "地点详情", systemImage: "mappin.and.ellipse")
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: theme.tapTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("查看地点来源或更正候选名称")
                }
                Button {
                    openTimeline(for: stop)
                } label: {
                    Label("查看时间线", systemImage: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: theme.tapTarget)
                        .contentShape(Rectangle())
                }
            }
            .font(.callout)
            .foregroundStyle(theme.accentText)
        }
    }

    private func stopTimeLabel(_ stop: RiverFootprintStop) -> String {
        let first = stop.firstSeen.formatted(date: .omitted, time: .shortened)
        guard stop.lastSeen > stop.firstSeen else { return first }
        return "\(first)–\(stop.lastSeen.formatted(date: .omitted, time: .shortened))"
    }

    private func relatedActivities(for stop: RiverFootprintStop) -> [IOSActivityRow] {
        guard let database else { return [] }
        let matchingEvents = database.timelineEvents.filter { stop.eventIDs.contains($0.id) }
        guard let arrival = matchingEvents.first(where: { $0.event.kind.hasSuffix("arrival") })?.event.observedAt,
              let departure = matchingEvents.last(where: { $0.event.kind.hasSuffix("departure") })?.event.observedAt,
              departure > arrival else { return [] }
        return RiverIOSProjection.timelineRows(database: database, date: arrival)
            .filter { row in
                guard row.kind != .place else { return false }
                let rowEnd = row.duration.map { row.date.addingTimeInterval($0) } ?? row.date
                return row.date <= departure && rowEnd >= arrival
            }
            .prefix(3)
            .map { $0 }
    }

    private func select(_ stop: RiverFootprintStop) {
        RiverHaptics.soft()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            selectedStopID = stop.id
            mapPosition = .region(MKCoordinateRegion(center: stop.coordinate,
                                                     span: MKCoordinateSpan(latitudeDelta: 0.012, longitudeDelta: 0.012)))
        }
    }

    private func updateCameraIfNeeded() {
        guard !hasPositionedMap, !stops.isEmpty else { return }
        let latitudes = stops.map(\.latitude)
        let longitudes = stops.map(\.longitude)
        guard let minimumLatitude = latitudes.min(), let maximumLatitude = latitudes.max(),
              let minimumLongitude = longitudes.min(), let maximumLongitude = longitudes.max() else { return }
        let center = CLLocationCoordinate2D(
            latitude: (minimumLatitude + maximumLatitude) / 2,
            longitude: (minimumLongitude + maximumLongitude) / 2
        )
        mapPosition = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max((maximumLatitude - minimumLatitude) * 1.7, 0.012),
                longitudeDelta: max((maximumLongitude - minimumLongitude) * 1.7, 0.012)
            )
        ))
        hasPositionedMap = true
    }

    private func openTimeline(for stop: RiverFootprintStop) {
        guard let eventID = stop.eventIDs.first else { return }
        coordinator.openTimeline(eventID: eventID, date: stop.firstSeen)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct RiverEmptyFootprintMap: View {
    @Environment(\.riverTheme) private var theme
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.and.ellipse").font(.title2).foregroundStyle(theme.accentText)
            VStack(alignment: .leading, spacing: 4) {
                Text("这一天没有位置记录").font(.subheadline.weight(.medium))
                Text("已保存的位置才会显示在地图上。").font(.caption).foregroundStyle(theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.surface)
    }
}
