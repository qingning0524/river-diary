import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DayTimelineView: View {
    let sessions: [ActivitySession]
    let date: Date
    var quickCaptures: [QuickCapture] = []
    var activeSessionID: UUID?
    var isTracking = false
    var isPaused = false
    var toggleTracking: (() -> Void)?
    var addCapture: ((String) throws -> Void)?
    var diaryEntry: DiaryEntry?
    var openDiary: (() -> Void)?
    var annotations: [String: TimelineAnnotation] = [:]
    var saveAnnotation: ((String, TimelineAnnotation) throws -> Void)?

    @State private var selectedID: String?
    @State private var category: String?
    @State private var query = ""
    @State private var grouped = true
    @State private var showsSearch = false
    @State private var favoritesOnly = false
    @State private var editingItem: ActivityTimelineItem?
    @State private var note = ""
    @State private var noteDrafts: [String: String] = [:]
    @State private var feedback: String?
    @State private var exportError: String?

    private var timeline: ActivityTimeline {
        ActivityTimelineEngine.build(for: date, sessions: sessions, captures: quickCaptures, grouped: grouped, annotations: annotations)
    }

    var body: some View {
        let model = timeline
        let visible = model.items.filter { $0.matches(query: query, category: category) && (!favoritesOnly || $0.isFavorite) }
        let selected = visible.first { $0.id == selectedID }
        VStack(spacing: 0) {
            toolbar(model)
            Divider().opacity(0.6)
            filters(model)
            Divider().opacity(0.6)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    timelineList(visible, model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().opacity(0.6)
                    inspector(selected, model: model)
                        .frame(width: min(350, max(280, proxy.size.width * 0.36)))
                }
            }
        }
        .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 20))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.ink.opacity(0.08), lineWidth: 1))
        .onChange(of: ActivitySession.dayKey(for: date)) { oldDay, newDay in
            noteDrafts[oldDay] = note
            note = noteDrafts[newDay] ?? ""
            selectedID = nil
            category = nil
            query = ""
            favoritesOnly = false
            feedback = nil
        }
        .onChange(of: grouped) { selectedID = nil }
        .onChange(of: category) { selectedID = nil }
        .onChange(of: model.categories) {
            if let category, !model.categories.contains(category) { self.category = nil }
        }
        .sheet(item: $editingItem) { item in
            TimelineAnnotationEditor(item: item) { annotation in
                if let key = item.annotationKey, let saveAnnotation {
                    try saveAnnotation(key, annotation)
                    feedback = "已保存整理"
                }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "请重新选择保存位置。")
        }
    }

    private func toolbar(_ model: ActivityTimeline) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color.riverAmethyst).frame(width: 6, height: 6)
            Text(date.formatted(.dateTime.month().day().weekday(.wide)))
                .font(.system(size: 14, weight: .semibold))
            Text("·").foregroundStyle(.tertiary)
            Text(durationText(model.totalDuration) + " 的足迹")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let toggleTracking {
                Button(action: toggleTracking) {
                    HStack(spacing: 6) {
                        Circle().fill(isTracking && !isPaused ? Color.green : Color.secondaryInk).frame(width: 5, height: 5)
                        Text(isPaused ? "按计划暂停" : isTracking ? "记录中" : "开启记录")
                        Image(systemName: isTracking ? "pause.fill" : "play.fill").font(.system(size: 8))
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.chip.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(isTracking ? "停止实时记录" : "开启实时记录")
            }
            Menu {
                Button("复制当天时间线") { copy(ActivityTimelineExport.markdown(model)) }
                Button("导出当天 Markdown…") { export(model) }
            } label: {
                Image(systemName: "square.and.arrow.up").frame(width: 22, height: 26)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("导出包含当天全部片段、已采集的窗口标题和快记")
            .accessibilityLabel("导出时间线")
        }
        .padding(.horizontal, 22).padding(.vertical, 13)
    }

    private func filters(_ model: ActivityTimeline) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        categoryButton("全部", value: nil)
                        ForEach(model.categories, id: \.self) { name in categoryButton(name, value: name) }
                    }
                }
                Button { favoritesOnly.toggle(); selectedID = nil } label: {
                    Image(systemName: favoritesOnly ? "star.fill" : "star")
                        .foregroundStyle(favoritesOnly ? Color.riverAmethyst : Color.secondaryInk)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(favoritesOnly ? "显示全部片段" : "只看收藏片段")
                .help(favoritesOnly ? "显示全部片段" : "只看收藏片段")
                Divider().frame(height: 16)
                Menu {
                    Button("活动段落") { grouped = true }
                    Button("原始片段") { grouped = false }
                } label: {
                    Label(grouped ? "段落" : "原始", systemImage: "rectangle.3.group")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("相邻同类活动合并为段落；可切回原始片段")
                Button { showsSearch.toggle(); if !showsSearch { query = "" } } label: {
                    Image(systemName: showsSearch ? "xmark" : "magnifyingglass").frame(width: 22, height: 24)
                }
                .buttonStyle(.plain).accessibilityLabel(showsSearch ? "关闭搜索" : "搜索时间线")
            }
            if showsSearch {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索应用、窗口标题或快记", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 13)).padding(10)
                .background(Color.chip.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func categoryButton(_ title: String, value: String?) -> some View {
        let selected = category == value
        return Button { category = value } label: {
            HStack(spacing: 5) {
                if let value { Circle().fill(accent(value)).frame(width: 6, height: 6) }
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Color.ink : Color.secondaryInk)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(selected ? Color.riverAmethyst.opacity(0.12) : Color.chip.opacity(0.45), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.riverAmethyst.opacity(0.4) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func timelineList(_ items: [ActivityTimelineItem], model: ActivityTimeline) -> some View {
        ScrollViewReader { scroll in
            VStack(spacing: 0) {
                HStack {
                    Text(grouped ? "一天的段落" : "每一个原始片段")
                    Spacer()
                    Button("最近一段") {
                        if let item = items.last(where: { $0.kind != .gap }) {
                            selectedID = item.id
                            withAnimation(.easeOut(duration: 0.2)) { scroll.scrollTo(item.id, anchor: .bottom) }
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Color.riverAmethyst)
                    .disabled(!items.contains { $0.kind != .gap })
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 13)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if items.isEmpty {
                            emptyTimeline(hasData: !model.items.isEmpty)
                        } else {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || partOfDay(item.start) != partOfDay(items[index - 1].start) {
                                    HStack(spacing: 8) {
                                        Text(partOfDay(item.start)).font(.system(size: 12, weight: .semibold))
                                        Rectangle().fill(Color.ink.opacity(0.07)).frame(height: 1)
                                    }
                                    .foregroundStyle(Color.secondaryInk)
                                    .padding(.leading, 62).padding(.top, index == 0 ? 2 : 20).padding(.bottom, 14)
                                }
                                timelineRow(item).id(item.id)
                            }
                            HStack(spacing: 8) {
                                Circle().fill(Color.riverAmethyst.opacity(0.4)).frame(width: 5, height: 5)
                                Text(Calendar.current.isDateInToday(date) ? "一天还在继续" : "这一天的记录到这里")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            .padding(.leading, 65).padding(.vertical, 16)
                        }
                        if !favoritesOnly, !model.retrospectiveCaptures.isEmpty, category == nil || category == "快记" {
                            retrospectiveNotes(model.retrospectiveCaptures.filter {
                                query.isEmpty || $0.text.localizedStandardContains(query)
                            })
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 20)
                }
                .id(ActivitySession.dayKey(for: date))
            }
        }
    }

    private func timelineRow(_ item: ActivityTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(clock(item.start)).foregroundStyle(Color.secondaryInk)
                if item.kind == .activity { Text(clock(item.end)).foregroundStyle(.tertiary) }
            }
            .font(.system(size: 10, design: .monospaced))
            .frame(width: 42, alignment: .trailing).padding(.top, 15)
            VStack(spacing: 0) {
                Circle().fill(item.kind == .gap ? Color.secondaryInk.opacity(0.3) : accent(item.category))
                    .frame(width: 7, height: 7).padding(.top, 18)
                Rectangle().fill(Color.ink.opacity(0.1)).frame(width: 1)
            }
            .frame(width: 9)
            if item.kind == .gap {
                HStack(spacing: 7) {
                    Image(systemName: "ellipsis")
                    Text("\(durationText(item.end.timeIntervalSince(item.start))) 未记录")
                    Spacer()
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .padding(.vertical, 15)
                .help("未开启记录、锁屏或睡眠都可能产生空档，不代表休息或离开")
            } else {
                Button { selectedID = item.id; feedback = nil } label: {
                    activityCard(item)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(clock(item.start))，\(item.title)，\(durationText(item.duration))")
                .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
                .contextMenu {
                    Button("复制这段记录") { copy("\(clock(item.start))–\(clock(item.end)) \(item.narrativeTitle)\n\(item.annotation?.note ?? item.summary)") }
                    if item.kind == .activity, saveAnnotation != nil {
                        Button("整理这段时间…") { editingItem = item }
                        Button(item.isFavorite ? "取消收藏" : "收藏这段时间") { toggleFavorite(item) }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func activityCard(_ item: ActivityTimelineItem) -> some View {
        let color = accent(item.category)
        let selected = selectedID == item.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(item.category).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                if item.isFavorite { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.riverAmethyst) }
                if item.annotation?.title.isEmpty == false { Text("已整理").font(.system(size: 9)).foregroundStyle(.tertiary) }
                Spacer()
                if isLive(item) {
                    Circle().fill(Color.green).frame(width: 5, height: 5)
                    Text("进行中").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if item.kind == .activity {
                    Text(durationText(item.duration)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "quote.opening").foregroundStyle(color.opacity(0.7))
                }
            }
            Text(item.kind == .capture ? item.title : item.narrativeTitle)
                .font(.system(size: item.kind == .capture ? 14 : 15, weight: .medium))
                .foregroundStyle(Color.ink).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let personalNote = item.annotation?.note, !personalNote.isEmpty {
                Text(personalNote).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            if item.kind == .activity {
                HStack(spacing: 7) {
                    HStack(spacing: -4) {
                        ForEach(item.apps.prefix(3), id: \.name) { app in
                            AppIconBadge(app: app.name, size: 19)
                        }
                    }
                    Text(item.apps.prefix(3).map(\.name).joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if item.sessions.count > 1 {
                        Text("\(item.sessions.count) 段").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    if selected { Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(color) }
                }
            } else if let tag = item.capture?.tag {
                Text("# " + tag).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 17).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(item.kind == .capture ? Color.riverPink.opacity(0.075) : selected ? color.opacity(0.09) : Color.strongSurface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Capsule().fill(color.opacity(selected ? 0.9 : 0.4)).frame(width: 3).padding(.vertical, 16)
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? color.opacity(0.65) : Color.ink.opacity(0.09), lineWidth: selected ? 1.25 : 0.75))
        .shadow(color: .black.opacity(selected ? 0.035 : 0.012), radius: 5, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func inspector(_ selected: ActivityTimelineItem?, model: ActivityTimeline) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let selected { selectedDetails(selected) }
                    else { dayOverview(model) }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let addCapture {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("此刻，想记住什么", systemImage: "square.and.pencil")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("快记").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    TextField("给这一天留一句话…", text: $note, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .lineLimit(2...4).padding(12)
                        .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.ink.opacity(0.08), lineWidth: 1))
                    HStack {
                        if let feedback { Text(feedback).font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Button {
                            do {
                                try addCapture(note)
                                note = ""
                                noteDrafts[ActivitySession.dayKey(for: date)] = nil
                                feedback = "已保存到这一天"
                            } catch { feedback = "保存失败：" + error.localizedDescription }
                        } label: {
                            HStack(spacing: 6) {
                                Text("留下这句")
                                Image(systemName: "arrow.up").font(.system(size: 10, weight: .semibold))
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Color.ctaText).background(Color.ctaBackground, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(20)
                .background(Color.editor.opacity(0.6))
                .overlay(alignment: .top) { Divider().opacity(0.5) }
            }
        }
        .background(Color.editor.opacity(0.35))
    }

    private func dayOverview(_ model: ActivityTimeline) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            TimelineJournalPanel(entry: diaryEntry, openDiary: openDiary)
            HStack(spacing: 7) {
                Image(systemName: "sun.horizon")
                Text("足迹概览")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.secondaryInk)
            VStack(alignment: .leading, spacing: 6) {
                Text(durationText(model.totalDuration)).font(.editorial(26)).foregroundStyle(Color.ink)
                Text("有迹可循的时间").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            dayRibbon(model)
            HStack(alignment: .top, spacing: 20) {
                overviewMetric("专注类应用", durationText(model.focusDuration))
                overviewMetric("快记", "\(quickCaptures.count) 条")
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("时间去了哪里").font(.system(size: 13, weight: .semibold))
                let usage = model.categoryUsage
                ForEach(usage, id: \.name) { item in
                    HStack(spacing: 7) {
                        Circle().fill(accent(item.name)).frame(width: 7, height: 7)
                        Text(item.name)
                        Spacer()
                        Text(durationText(item.duration)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
                if usage.isEmpty {
                    Text("记录开始后，这里会显示当天的时间分布。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                }
            }
            Text("点选左侧片段，展开这段时间的细节。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
            Text("段落依据应用分类在本机整理；专注时长指工作、学习和创作类应用的记录时间。")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineSpacing(4)
        }
    }

    private func selectedDetails(_ item: ActivityTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(item.category, systemImage: item.kind == .capture ? "quote.bubble" : "circle.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(accent(item.category))
                Spacer()
                Button { selectedID = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("关闭详情")
            }
            Text(item.kind == .capture ? item.title : item.narrativeTitle).font(.editorial(24)).foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                Text(item.kind == .capture ? clock(item.start) : "\(clock(item.start)) – \(clock(item.end))")
                Spacer()
                if item.kind == .activity { Text(durationText(item.duration)) }
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            if item.kind == .activity {
                if saveAnnotation != nil {
                    HStack(spacing: 10) {
                        Button { editingItem = item } label: { Label("整理这段时间", systemImage: "pencil.line") }
                            .buttonStyle(.bordered).font(.system(size: 11))
                        Spacer()
                        Button { toggleFavorite(item) } label: {
                            Image(systemName: item.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(Color.riverAmethyst)
                        }
                        .buttonStyle(.plain).help(item.isFavorite ? "取消收藏" : "收藏这段时间")
                        .accessibilityLabel(item.isFavorite ? "取消收藏" : "收藏这段时间")
                    }
                }
                if let personalNote = item.annotation?.note, !personalNote.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("我的补充").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.riverAmethyst)
                        Text(personalNote).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                    }
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.riverAmethyst.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("使用的应用").font(.system(size: 13, weight: .semibold))
                    ForEach(item.apps, id: \.name) { app in
                        HStack(spacing: 9) {
                            AppIconBadge(app: app.name, size: 26)
                            Text(app.name).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(durationText(app.duration)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("原始片段").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(item.sessions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(item.sessions) { session in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(clock(session.start)) – \(clock(session.end))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                            Text(session.appName).font(.system(size: 12, weight: .medium))
                            if let title = session.windowTitle, !title.isEmpty {
                                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 11)
                        .overlay(alignment: .leading) { Rectangle().fill(accent(session.category).opacity(0.4)).frame(width: 2) }
                    }
                }
            } else if let capture = item.capture {
                Text("记录于 \(capture.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let tag = capture.tag { Text(tag).font(.system(size: 12)).foregroundStyle(Color.riverAmethyst) }
            }
        }
    }

    private func dayRibbon(_ model: ActivityTimeline) -> some View {
        VStack(spacing: 5) {
            GeometryReader { proxy in
                if let day = Calendar.current.dateInterval(of: .day, for: date) {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.chip)
                        ForEach(model.sessions) { session in
                            Rectangle().fill(accent(session.category).opacity(0.85))
                                .frame(width: max(1, session.duration / day.duration * proxy.size.width))
                                .offset(x: session.start.timeIntervalSince(day.start) / day.duration * proxy.size.width)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(height: 22)
            HStack {
                Text("00:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("24:00")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .accessibilityLabel("全天活动分布")
    }

    private func emptyTimeline(hasData: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: hasData ? "magnifyingglass" : "sun.horizon")
                .font(.system(size: 30, weight: .light)).foregroundStyle(Color.riverAmethyst.opacity(0.7))
            Text(favoritesOnly ? "这一天还没有匹配的收藏" : hasData ? "没有找到匹配的记录" : "让这一天慢慢浮现")
                .font(.editorial(22)).foregroundStyle(Color.ink)
            Text(hasData ? "换个关键词，或清除筛选再看看。" : "这一天还没有实时足迹。开启记录后，应用活动会自动出现在这里，也可以先留一句快记。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                .multilineTextAlignment(.center).frame(maxWidth: 280)
            if hasData {
                Button("清除筛选") { query = ""; category = nil; favoritesOnly = false }.buttonStyle(.bordered)
            } else if !isTracking, let toggleTracking {
                Button("开启实时记录", action: toggleTracking).buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 65).frame(maxWidth: .infinity)
    }

    private func retrospectiveNotes(_ captures: [QuickCapture]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !captures.isEmpty {
                Text("为这一天补记").font(.system(size: 12, weight: .semibold))
                Text("写于其他日期，未指定这一天的发生时间。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(captures) { capture in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(capture.text).font(.system(size: 12)).textSelection(.enabled)
                        Text(capture.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.riverPink.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(.leading, 62).padding(.top, 16)
    }

    private func overviewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .medium)).foregroundStyle(Color.ink)
        }
    }

    private func partOfDay(_ date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<6: return "深夜 · 万籁俱静"
        case 6..<12: return "上午 · 一天展开"
        case 12..<18: return "下午 · 继续流动"
        default: return "夜晚 · 慢慢收尾"
        }
    }

    private func toggleFavorite(_ item: ActivityTimelineItem) {
        guard let key = item.annotationKey, let saveAnnotation else { return }
        var annotation = item.annotation ?? TimelineAnnotation()
        annotation.isFavorite.toggle()
        annotation.updatedAt = Date()
        do { try saveAnnotation(key, annotation) }
        catch { exportError = error.localizedDescription }
    }

    private func isLive(_ item: ActivityTimelineItem) -> Bool {
        isTracking && !isPaused && Calendar.current.isDateInToday(date) && item.sessions.contains { $0.id == activeSessionID }
    }
    private func accent(_ category: String) -> Color {
        category == "快记" ? .riverPink : Color(hex: ActivityClassifier.color(for: category))
    }
    private func clock(_ date: Date) -> String { date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    private func durationText(_ duration: TimeInterval) -> String { duration <= 0 ? "0 分钟" : ActivityFormatter.time(duration) }
    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        feedback = "已复制"
    }
    private func export(_ model: ActivityTimeline) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "河流时间线-\(ActivitySession.dayKey(for: date)).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityTimelineExport.markdown(model).write(to: url, atomically: true, encoding: .utf8)
            feedback = "已导出"
        } catch { exportError = error.localizedDescription }
    }
}
