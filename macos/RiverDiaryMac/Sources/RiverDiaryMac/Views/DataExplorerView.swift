import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DataExplorerCategory: String, CaseIterable, Identifiable {
    case overview, mood, sleep, exercise, browsing, notes, sessions, quickNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .mood: "心情"
        case .sleep: "睡眠"
        case .exercise: "运动"
        case .browsing: "浏览"
        case .notes: "备忘录"
        case .sessions: "足迹"
        case .quickNotes: "快记"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .mood: "heart"
        case .sleep: "moon.zzz"
        case .exercise: "figure.walk"
        case .browsing: "safari"
        case .notes: "note.text"
        case .sessions: "app.badge"
        case .quickNotes: "bolt"
        }
    }

    var accent: Color {
        switch self {
        case .overview: Color(hex: "#7787FF")
        case .mood: Color(hex: "#F06292")
        case .sleep: Color(hex: "#7C5CFC")
        case .exercise: Color(hex: "#66BB6A")
        case .browsing: Color(hex: "#42A5F5")
        case .notes: Color(hex: "#FFC15C")
        case .sessions: Color(hex: "#7FB3FF")
        case .quickNotes: Color(hex: "#FFA726")
        }
    }
}

struct DataExplorerView: View {
    @ObservedObject var ingestion: DataIngestionStore

    @Binding var selectedDate: Date
    var showsHeader: Bool = true
    @State private var category: DataExplorerCategory = .overview
    @State private var searchText = ""

    @State private var record: DBDailyRecord?
    @State private var mood: DBMoodScore?
    @State private var sleep: DBSleepNight?
    @State private var exercise: DBExerciseDay?
    @State private var visits: [DBChromeVisit] = []
    @State private var notes: [DBDailyNote] = []
    @State private var sessions: [DBActivitySession] = []
    @State private var quickCaptures: [DBQuickCapture] = []
    @State private var showsGlobalSearch = false
    @State private var globalQuery = ""
    @State private var globalDays = 30
    @State private var globalSnapshot: DatabaseCrossDaySnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showsHeader {
                    header
                }
                toolbar
                globalSearchCard
                categoryContent
            }
            .padding(.horizontal, 26)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 1280, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onAppear(perform: loadData)
        .onChange(of: selectedDate) {
            loadData()
        }
        .onChange(of: ingestion.lastCaptureDate) {
            loadData()
        }
    }

    // MARK: - Header

    private var header: some View {
        SoftCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("数据库")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(Color.ink)
                            StatusBadge("本地", tone: .positive)
                        }

                        Text(captureLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if isToday {
                        Button {
                            ingestion.captureNow()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                loadData()
                            }
                        } label: {
                            Label(ingestion.isRunning ? "采集中" : "立即采集", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .modifier(SmallActionButtonStyle(dark: true))
                        .disabled(ingestion.isRunning)
                    }
                }

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    summaryTile("心情", mood.map { "\($0.score)" } ?? "—", unit: "分", color: DataExplorerCategory.mood.accent)
                    summaryTile("睡眠", sleep.map { String(format: "%.1f", $0.totalHours) } ?? "—", unit: "小时", color: DataExplorerCategory.sleep.accent)
                    summaryTile("浏览", "\(visits.count)", unit: "条", color: DataExplorerCategory.browsing.accent)
                    summaryTile("足迹", "\(sessions.count)", unit: "段", color: DataExplorerCategory.sessions.accent)
                }
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(DataExplorerCategory.allCases) { item in
                        categoryButton(item)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if category.supportsSearch {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索\(category.title)，例如标题、网址、应用或内容", text: $searchText)
                        .textFieldStyle(.plain)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.border, lineWidth: 1))
            }
        }
    }

    private func categoryButton(_ item: DataExplorerCategory) -> some View {
        let count = count(for: item)
        let selected = category == item

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                category = item
                searchText = ""
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.system(size: 10, weight: .semibold))

                Text(item.title)
                    .font(.caption.weight(.semibold))

                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(selected ? 0.16 : 0.08), in: Capsule())
                }
            }
            .foregroundStyle(selected ? Color.ctaText : Color.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.ctaBackground : Color.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    // MARK: - Content

    @ViewBuilder
    private var categoryContent: some View {
        if hasCategoryData {
            switch category {
            case .overview: overviewContent
            case .mood: moodContent
            case .sleep: sleepContent
            case .exercise: exerciseContent
            case .browsing: browsingContent
            case .notes: notesContent
            case .sessions: sessionsContent
            case .quickNotes: quickNoteContent
            }
        } else {
            emptyState
        }
    }

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record {
                DataSectionCard(accent: category.accent, title: "当日概览", subtitle: "数据库主记录") {
                    if record.mixedOverview.isEmpty {
                        Text("这一天没有生成概览。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(record.mixedOverview)
                            .font(.system(size: 15, weight: .medium))
                            .lineSpacing(5)
                            .foregroundStyle(Color.ink)
                    }
                }

                VStack(spacing: 10) {
                    EqualWidthRow(spacing: 10) {
                        metricCard("屏幕使用", value: record.screenTimeMinutes.map { String(format: "%.1f 小时", Double($0) / 60) } ?? "—", icon: "desktopcomputer", color: DataExplorerCategory.sessions.accent)
                        metricCard("快记", value: "\(record.quickCaptureCount) 条", icon: "bolt", color: DataExplorerCategory.quickNotes.accent)
                    }
                    EqualWidthRow(spacing: 10) {
                        metricCard("iOS 健康", value: record.iosDataAvailable ? "已同步" : "未同步", icon: "heart.text.square", color: DataExplorerCategory.mood.accent)
                        metricCard("备忘录", value: "\(record.notesCount) 条", icon: "note.text", color: DataExplorerCategory.notes.accent)
                    }
                }
            }
        }
    }

    private var moodContent: some View {
        DataSectionCard(accent: category.accent, title: "心情", subtitle: "原始记录") {
            if let mood {
                VStack(spacing: 12) {
                    DataValueRow(label: "评分", value: "\(mood.score) 分")
                    DataValueRow(label: "来源", value: mood.source)
                }
            }
        }
    }

    private var sleepContent: some View {
        DataSectionCard(accent: category.accent, title: "睡眠", subtitle: "原始记录") {
            if let sleep {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    metricCard("总睡眠", value: String(format: "%.1f 小时", sleep.totalHours), icon: "bed.double", color: category.accent)
                    metricCard("深睡", value: String(format: "%.0f 分钟", sleep.deepMinutes), icon: "moon.circle", color: category.accent)
                    metricCard("REM", value: String(format: "%.0f 分钟", sleep.remMinutes), icon: "waveform", color: category.accent)
                    metricCard("清醒", value: String(format: "%.0f 分钟", sleep.awakeMinutes), icon: "sun.max", color: category.accent)
                }
            }
        }
    }

    private var exerciseContent: some View {
        DataSectionCard(accent: category.accent, title: "运动", subtitle: "原始记录") {
            if let exercise {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    metricCard("步数", value: "\(exercise.steps)", icon: "figure.walk", color: category.accent)
                    metricCard("距离", value: String(format: "%.2f 公里", exercise.distanceKM), icon: "point.topleft.down.curvedto.point.bottomright.up", color: category.accent)
                    metricCard("活动热量", value: String(format: "%.1f 千卡", exercise.activeEnergyKcal), icon: "flame", color: category.accent)
                }
            }
        }
    }

    private var browsingContent: some View {
        DataSectionCard(accent: category.accent, title: "浏览记录", subtitle: "\(filteredVisits.count) / \(visits.count) 条") {
            ForEach(filteredVisits) { visit in
                DataRecordRow(
                    title: visit.title.isEmpty ? visit.url : visit.title,
                    time: DatabaseTime.shortTime(visit.visitedAt),
                    subtitle: visit.domain.isEmpty ? visit.url : visit.domain,
                    icon: "safari",
                    color: category.accent
                )
            }
        }
    }

    private var notesContent: some View {
        DataSectionCard(accent: category.accent, title: "备忘录", subtitle: "\(filteredNotes.count) / \(notes.count) 条") {
            ForEach(filteredNotes) { note in
                DataRecordRow(
                    title: note.title,
                    time: DatabaseTime.shortTime(note.modifiedAt),
                    subtitle: "备忘录更新",
                    icon: "note.text",
                    color: category.accent
                )
            }
        }
    }

    private var sessionsContent: some View {
        DataSectionCard(accent: category.accent, title: "应用足迹", subtitle: "\(filteredSessions.count) / \(sessions.count) 段") {
            ForEach(filteredSessions) { session in
                DataRecordRow(
                    title: session.appName,
                    time: durationText(session.durationMinutes),
                    subtitle: "\(DatabaseTime.shortTime(session.startTime)) – \(DatabaseTime.shortTime(session.endTime))" + (session.windowTitle.map { " · \($0)" } ?? ""),
                    icon: "app.badge",
                    color: category.accent
                )
            }
        }
    }

    private var quickNoteContent: some View {
        DataSectionCard(accent: category.accent, title: "快记", subtitle: "\(filteredQuickCaptures.count) / \(quickCaptures.count) 条") {
            ForEach(filteredQuickCaptures) { item in
                DataRecordRow(
                    title: item.text,
                    time: DatabaseTime.shortTime(item.createdAt),
                    subtitle: item.source,
                    icon: "bolt",
                    color: category.accent
                )
            }
        }
    }

    private var emptyState: some View {
        SoftCard {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("这一天还没有\(category.title)数据")
                    .font(.headline)
                Text("到点采集后，数据会自动分类出现在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Data

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 165), spacing: 10)]
    }

    private var captureLabel: String {
        if let capturedAt = record?.capturedAt {
            return "\(dateLabel) · 采集于 \(DatabaseTime.fullTime(capturedAt))"
        }
        return "\(dateLabel) · 未采集"
    }

    private var dateLabel: String {
        selectedDate.formatted(date: .abbreviated, time: .omitted)
    }

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
    }

    private var hasCategoryData: Bool {
        switch category {
        case .overview: record != nil
        case .mood: mood != nil
        case .sleep: sleep != nil
        case .exercise: exercise != nil
        case .browsing: !filteredVisits.isEmpty
        case .notes: !filteredNotes.isEmpty
        case .sessions: !filteredSessions.isEmpty
        case .quickNotes: !filteredQuickCaptures.isEmpty
        }
    }

    private var filteredVisits: [DBChromeVisit] {
        filter(visits) { [$0.title, $0.url, $0.domain] }
    }

    private var filteredNotes: [DBDailyNote] {
        filter(notes) { [$0.title] }
    }

    private var filteredSessions: [DBActivitySession] {
        filter(sessions) { [$0.appName, $0.category, $0.windowTitle ?? ""] }
    }

    private var filteredQuickCaptures: [DBQuickCapture] {
        filter(quickCaptures) { [$0.text, $0.source] }
    }

    private func filter<T>(_ values: [T], fields: (T) -> [String]) -> [T] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return values }
        return values.filter { item in fields(item).contains { $0.lowercased().contains(query) } }
    }

    private func count(for item: DataExplorerCategory) -> Int {
        switch item {
        case .overview: record == nil ? 0 : 1
        case .mood: mood == nil ? 0 : 1
        case .sleep: sleep == nil ? 0 : 1
        case .exercise: exercise == nil ? 0 : 1
        case .browsing: visits.count
        case .notes: notes.count
        case .sessions: sessions.count
        case .quickNotes: quickCaptures.count
        }
    }

    private var globalSearchCard: some View {
        let snapshot = globalSnapshot

        return SoftCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Label("跨天查询", systemImage: "magnifyingglass.circle")
                        .font(.headline)

                    Spacer()

                    Toggle(isOn: $showsGlobalSearch) {
                        Text(showsGlobalSearch ? "已展开" : "展开")
                            .font(.caption.weight(.semibold))
                    }
                    .toggleStyle(.switch)
                }

                if showsGlobalSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)

                        TextField("搜索网址、标题、应用、备忘录或快记", text: $globalQuery)
                            .textFieldStyle(.plain)
                            .onSubmit(runGlobalSearch)

                        Picker("", selection: $globalDays) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("365 天").tag(365)
                        }
                        .labelsHidden()
                        .frame(width: 92)

                        Button("查询", action: runGlobalSearch)
                            .buttonStyle(.plain)
                            .smallAction(dark: true)

                        Button("导出 CSV") { exportGlobalCSV() }
                            .buttonStyle(.plain)
                            .smallAction()
                            .disabled(snapshot == nil || snapshot?.recordCount == 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.border, lineWidth: 1))

                    if let snapshot {
                        Text("找到 \(snapshot.dailyRecords.count) 天概览 · \(snapshot.chromeVisits.count) 条浏览 · \(snapshot.notes.count) 条备忘录 · \(snapshot.sessions.count) 段足迹 · \(snapshot.quickCaptures.count) 条快记")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        if snapshot.recordCount == 0 {
                            Text("这段范围里还没有匹配的记录。试试更宽的时间，或者换一个词。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(snapshot.chromeVisits.prefix(6)) { item in
                                    DataRecordRow(
                                        title: item.title.isEmpty ? item.url : item.title,
                                        time: "\(item.date) \(DatabaseTime.shortTime(item.visitedAt))",
                                        subtitle: item.domain,
                                        icon: "safari",
                                        color: DataExplorerCategory.browsing.accent
                                    )
                                }
                                ForEach(snapshot.notes.prefix(4)) { item in
                                    DataRecordRow(
                                        title: item.title,
                                        time: "\(item.date) \(DatabaseTime.shortTime(item.modifiedAt))",
                                        subtitle: "备忘录",
                                        icon: "note.text",
                                        color: DataExplorerCategory.notes.accent
                                    )
                                }
                                ForEach(snapshot.sessions.prefix(6)) { item in
                                    DataRecordRow(
                                        title: item.appName,
                                        time: "\(item.date) \(DatabaseTime.shortTime(item.startTime))",
                                        subtitle: item.windowTitle ?? item.category,
                                        icon: "app.badge",
                                        color: DataExplorerCategory.sessions.accent
                                    )
                                }
                                ForEach(snapshot.quickCaptures.prefix(5)) { item in
                                    DataRecordRow(
                                        title: item.text,
                                        time: "\(item.date) \(DatabaseTime.shortTime(item.createdAt))",
                                        subtitle: item.source,
                                        icon: "bolt",
                                        color: DataExplorerCategory.quickNotes.accent
                                    )
                                }
                            }
                        }
                    } else {
                        Text("可以跨天找“某一句话、某个网站、某款应用”，结果直接来自本地数据库。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func runGlobalSearch() {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: selectedDate)
        let start = calendar.date(byAdding: .day, value: -(globalDays - 1), to: end) ?? end
        let startKey = DiaryEntry.dateFormatter.string(from: start)
        let endKey = DiaryEntry.dateFormatter.string(from: end)
        globalSnapshot = AppDatabase.shared.queryCrossDaySnapshot(
            startDate: startKey,
            endDate: endKey,
            searchText: globalQuery
        )
    }

    private func exportGlobalCSV() {
        guard let snapshot = globalSnapshot, snapshot.recordCount > 0 else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "river-diary-query.csv"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var rows: [[String]] = [["type", "date", "time", "title", "detail"]]
        for item in snapshot.chromeVisits {
            rows.append(["浏览", item.date, DatabaseTime.shortTime(item.visitedAt), item.title, item.url])
        }
        for item in snapshot.notes {
            rows.append(["备忘录", item.date, DatabaseTime.shortTime(item.modifiedAt), item.title, ""])
        }
        for item in snapshot.sessions {
            rows.append(["足迹", item.date, DatabaseTime.shortTime(item.startTime), item.appName, item.windowTitle ?? item.category])
        }
        for item in snapshot.quickCaptures {
            rows.append(["快记", item.date, DatabaseTime.shortTime(item.createdAt), item.text, item.source])
        }

        let csv = rows.map { values in
            values.map { value in
                let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }.joined(separator: ",")
        }.joined(separator: "\n")

        do {
            try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(csv, forType: .string)
        }
    }

    private func loadData() {
        let key = DiaryEntry.dateFormatter.string(from: selectedDate)
        let database = AppDatabase.shared
        record = database.queryDailyRecord(date: key)
        mood = database.queryMoodScore(date: key)
        sleep = database.querySleepNight(date: key)
        exercise = database.queryExerciseDay(date: key)
        visits = database.queryChromeVisits(date: key)
        notes = database.queryDailyNotes(date: key)
        sessions = database.queryActivitySessions(date: key)
        quickCaptures = database.queryQuickCaptures(date: key)
    }

    private func durationText(_ minutes: Int) -> String {
        minutes >= 60 ? String(format: "%dh %02dm", minutes / 60, minutes % 60) : "\(minutes) 分钟"
    }

    private func summaryTile(_ title: String, _ value: String, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.smallCaps())
                .foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(12)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topLeading) {
            Circle().fill(color).frame(width: 4, height: 4).padding(7)
        }
    }

    private func metricCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.ink)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private extension DataExplorerCategory {
    var supportsSearch: Bool {
        switch self {
        case .browsing, .notes, .sessions, .quickNotes: true
        default: false
        }
    }
}

struct DataSectionCard<Content: View>: View {
    let accent: Color
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 2)
                .overlay(alignment: .bottomLeading) {
                    Rectangle()
                        .fill(accent.opacity(0.6))
                        .frame(width: 28, height: 3)
                        .cornerRadius(2)
                        .offset(y: 5)
                }

                content()
            }
        }
    }
}

struct DataValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.ink)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }
}

struct DataRecordRow: View {
    let title: String
    let time: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.1), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Text(time)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }
}
