import RiverDiaryCore
import SwiftUI

private struct RiverMemoryEvidenceItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let date: Date?
    let eventID: UUID?
    let journalDayKey: String?
}

/// A personal archive: every category searches the content that is actually stored.
struct RiverMemoryHomeView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.riverUsesSharedHeader) private var usesSharedHeader
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var diary: DiaryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var selection = "all"
    @State private var showsJournal = false
    @State private var pendingJournalEditDate: Date?
    @State private var feedback: RiverFeedback?
    @State private var readingAutomatic: AutomaticJournal?
    @AppStorage("river.profile.nickname") private var nickname = "River 旅人"
    @State private var profileDraft = ""
    @State private var editingProfile = false
    private struct MemoryCollection: Identifiable { let id: String }
    @State private var collection: MemoryCollection?
    @FocusState private var searchFocused: Bool

    private struct JournalItem: Identifiable {
        let day: String
        let shared: RiverSharedStateRecord?
        let legacy: DiaryEntry?
        var id: String { day }
        var body: String {
            if let content = shared?.journalEntryContent { return content.body }
            guard let legacy else { return "" }
            let sections = [legacy.overview, legacy.mood].compactMap { $0 } + (legacy.thoughts ?? []) + (legacy.memos ?? [])
            return sections.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        }
        var title: String { legacy?.displayTitle ?? body.split(separator: "\n").first.map { String($0.prefix(28)) } ?? "一段日记" }
        var excerpt: String { let lines = body.split(separator: "\n"); return legacy == nil && lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : body }
        var favorite: Bool { shared?.journalEntryContent?.tags.contains("river-favorite") == true }
        var tags: String { (shared?.journalEntryContent?.tags ?? legacy?.tags ?? []).filter { $0 != "river-favorite" }.joined(separator: " ") }
    }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !searchText.isEmpty }
    private var records: [RiverSharedStateRecord] { node.database?.sharedUserRecords ?? [] }
    private var memories: [RiverSharedStateRecord] { records.filter { $0.kind == .memory && $0.status != "deleted" }.sorted { $0.updatedAt > $1.updatedAt } }
    private var habits: [RiverSharedStateRecord] { records.filter { $0.kind == .habitRule && $0.status == "active" } }
    private var places: [RiverPlace] { (node.database?.places ?? []).sorted { $0.lastSeen > $1.lastSeen } }
    private var answeredHabits: [RiverSharedStateRecord] { records.filter { $0.kind == .habitCard && ["answered", "skipped"].contains($0.status) }.sorted { $0.updatedAt > $1.updatedAt } }
    private var resolvedQuestions: [RiverSharedStateRecord] { records.filter { $0.kind == .pendingConfirmation && ["confirmed", "rejected", "corrected", "dismissed"].contains($0.status) }.sorted { $0.updatedAt > $1.updatedAt } }
    private var journals: [JournalItem] {
        let legacyDays = Set(diary.entries.map(\.date))
        let modern = records.compactMap { record -> JournalItem? in
            guard record.kind == .journalEntry, record.status == "current", let content = record.journalEntryContent, !content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.source != "legacy-data.json" || !legacyDays.contains(content.dayKey) else { return nil }
            return JournalItem(day: content.dayKey, shared: record, legacy: nil)
        }
        let days = Set(modern.map(\.day))
        return (modern + diary.entries.filter { !days.contains($0.date) }.map { JournalItem(day: $0.date, shared: nil, legacy: $0) }).sorted { $0.day > $1.day }
    }
    private var visibleJournals: [JournalItem] {
        journals.filter { item in
            (selection != "favorites" || item.favorite) && (!isSearching || [item.day, item.title, item.body, item.tags].contains { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }
    private var matchingMemories: [RiverSharedStateRecord] {
        memories.filter { record in
            !isSearching || [RiverIOSProjection.memoryText(record, key: "title") ?? "", RiverIOSProjection.memoryText(record, key: "body") ?? ""].contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    private var matchingPlaces: [RiverPlace] {
        places.filter { place in
            !isSearching || [place.displayName, place.mapAddress ?? "", place.semanticType ?? "", place.poiCategory ?? ""].contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    private struct AutomaticJournal: Identifiable {
        var id: String
        var day: String
        var body: String
        var status: ArtifactStatus
    }
    private var allAutomaticJournals: [AutomaticJournal] {
        ((try? node.database?.canonicalArtifactRevisions()) ?? []).compactMap { revision in
            guard revision.kind == .dailyReview, revision.status != .superseded,
                  let body = String(data: revision.content, encoding: .utf8), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return AutomaticJournal(id: revision.id, day: String(revision.logicalKey.suffix(10)), body: body, status: revision.status)
        }.sorted { $0.day > $1.day }
    }
    private var automaticJournals: [AutomaticJournal] { allAutomaticJournals.filter { !isSearching || ($0.day + $0.body).localizedCaseInsensitiveContains(searchText) } }
    private var showsAutomatic: Bool { ["all", "automatic", "journals"].contains(selection) }
    private var options: [(String, String)] { [("all", "全部"), ("automatic", "自动日记"), ("journals", "日记与补充"), ("memories", "记忆"), ("places", "地点"), ("favorites", "收藏")] }
    private var showsJournals: Bool { ["all", "journals", "favorites"].contains(selection) }
    private var showsMemories: Bool { ["all", "memories"].contains(selection) }
    private var showsPlaces: Bool { ["all", "places"].contains(selection) }
    private var resultCount: Int { (showsAutomatic ? automaticJournals.count : 0) + (showsJournals ? visibleJournals.count : 0) + (showsMemories ? matchingMemories.count : 0) + (showsPlaces ? matchingPlaces.count : 0) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if usesSharedHeader { RiverScrollingPageHeading(tab: .me) }
                else { header }
                if node.database == nil {
                    RiverIOSDatabaseUnavailablePanel(message: node.initializationError) { node.retryOpen() }
                } else {
                    profile
                    archiveOverview
                    collectionGrid
                    habitHighlights
                    RiverIOSSectionHeading(title: "过去做过的事情 · 记忆回顾", detail: "可搜索与重读")
                    VStack(alignment: .leading, spacing: 12) {
                        search
                        tabs
                        if isSearching {
                            Text("找到 \(resultCount) 项 · \(options.first { $0.0 == selection }?.1 ?? "全部")")
                                .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                                .accessibilityIdentifier("river.memory.search.count")
                        }
                    }
                    archiveContent
                    exportCollection
                    if !isSearching { libraryLinks }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: drive.hasAccess ? "icloud" : "iphone")
                        Text(drive.hasAccess ? node.syncStatus : "记忆先保存在这台 iPhone；在设置中连接云端档案。")
                    }
                    .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                    .padding(.top, 8)
                }
            }
            .riverPageEntrance()
            .padding(.horizontal, theme.pageGutter).padding(.top, 16).padding(.bottom, 32)
        }
        .foregroundStyle(theme.ink).background(theme.canvas).toolbar(.hidden, for: .navigationBar)
        .sheet(item: $readingAutomatic) { item in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(item.body).font(.body).lineSpacing(5).textSelection(.enabled)
                        Button("回看这一天的依据") {
                            if let date = DiaryEntry.dateFormatter.date(from: item.day) { coordinator.openFootprints(day: date) }
                            readingAutomatic = nil
                        }.buttonStyle(.borderedProminent)
                    }.padding(22)
                }.background(theme.canvas).navigationTitle(item.day + " · 自动日记").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { readingAutomatic = nil } } }
            }
        }
        .riverFeedback($feedback)
        .sheet(isPresented: $editingProfile) {
            NavigationStack {
                Form { Section("怎么称呼你？") { TextField("昵称", text: $profileDraft).autocorrectionDisabled() } }
                    .navigationTitle("编辑资料").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingProfile = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { nickname = String(profileDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)); editingProfile = false }.disabled(profileDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }
            }.presentationDetents([.medium])
        }
        .sheet(item: $collection) { selectedCollection in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if selectedCollection.id == "places" {
                            if places.isEmpty { Text("位置来源留下的地点会自动归档在这里。").foregroundStyle(theme.secondaryInk) }
                            ForEach(places) { place in
                                NavigationLink { RiverPlaceDetailView(placeID: place.id) } label: {
                                    RiverIOSPanel { HStack { Label(place.displayName, systemImage: "mappin.and.ellipse"); Spacer(); Text("\(place.visitCount) 次").font(.caption).foregroundStyle(theme.secondaryInk) } }
                                }.buttonStyle(.plain)
                            }
                        } else if selectedCollection.id == "habits" {
                            if habits.isEmpty && entityMemories("habits").isEmpty { Text("习惯线索会由 AI 提出，经过你确认后记住。").foregroundStyle(theme.secondaryInk) }
                            ForEach(habits) { habitRuleRow($0) }
                            ForEach(entityMemories("habits")) { memoryRow($0).padding(14).riverNeumorphic() }
                            NavigationLink("管理确认历史与更正") { answersDetail }.frame(minHeight: 44)
                        } else {
                            if entityMemories(selectedCollection.id).isEmpty { Text("记录积累后，River 会把相关的生活记忆整理在这里。每条记忆都可以查看依据与更正。").foregroundStyle(theme.secondaryInk) }
                            ForEach(entityMemories(selectedCollection.id)) { memoryRow($0).padding(14).riverNeumorphic() }
                        }
                    }.padding(22)
                }.background(theme.canvas).navigationTitle(collectionTitle(selectedCollection.id)).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { collection = nil } } }
            }.environment(\.riverTheme, theme)
        }
        .scrollDismissesKeyboard(.interactively).onDisappear { searchFocused = false }
        .sheet(isPresented: $showsJournal, onDismiss: {
            guard let date = pendingJournalEditDate else { return }
            pendingJournalEditDate = nil
            coordinator.presentJournal(on: date)
        }) {
            JournalView(onEditRequest: { date in
                pendingJournalEditDate = date
                showsJournal = false
            })
        }
    }

    private var profile: some View {
        HStack(spacing: 14) {
            Text(String(nickname.prefix(1))).font(.title2.weight(.semibold)).foregroundStyle(theme.accentText)
                .frame(width: 58, height: 58).riverNeumorphic(radius: 29)
                .overlay(alignment: .bottomTrailing) { Circle().fill(theme.success).frame(width: 11, height: 11).overlay(Circle().stroke(theme.canvas, lineWidth: 2)) }
            VStack(alignment: .leading, spacing: 6) {
                Text(nickname).font(.title3.weight(.bold))
                Text("River 已留下 \(archiveCount) 条生活记忆").font(.caption).foregroundStyle(theme.secondaryInk)
                Button("编辑资料 ›") { profileDraft = nickname; editingProfile = true }.font(.caption.weight(.medium)).foregroundStyle(theme.accentText).frame(minHeight: 30)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { coordinator.mePath.append(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 44, height: 44).riverNeumorphic(radius: 15)
            }.buttonStyle(.plain).accessibilityLabel("设置、同步与隐私").accessibilityIdentifier("river.memory.settings")
        }
    }
    private var archiveCount: Int { allAutomaticJournals.count + journals.count + memories.count + places.count + habits.count }
    private var coveredDays: Int { Set(allAutomaticJournals.map(\.day) + journals.map(\.day) + memories.map { RiverIOSProjection.dayKey($0.createdAt) } + places.map { RiverIOSProjection.dayKey($0.firstSeen) }).count }
    private var archiveOverview: some View {
        RiverIOSPanel(padding: 19) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .firstTextBaseline) {
                    Text(archiveCount.formatted()).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("条生活记忆档案").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                Rectangle().fill(theme.separator.opacity(0.6)).frame(height: 1)
                HStack {
                    archiveMetric(coveredDays, label: "记忆覆盖天数", tint: theme.ink)
                    archiveMetric(places.count, label: "走过的地点", tint: theme.ink)
                    archiveMetric(allAutomaticJournals.count, label: "AI 自动日记", tint: theme.accentText)
                    archiveMetric(habits.count, label: "已确认规则", tint: theme.success)
                }
                HStack(spacing: 6) {
                    Circle().fill(theme.success).frame(width: 5, height: 5)
                    Text("记忆保存在本机").font(.caption2).foregroundStyle(theme.secondaryInk)
                    Spacer()
                    Text(drive.hasAccess ? "已连接同步" : "本机归档").font(.caption2.weight(.medium)).foregroundStyle(theme.accentText)
                }
            }
        }.accessibilityIdentifier("river.memory.overview")
    }
    private func archiveMetric(_ value: Int, label: String, tint: Color) -> some View {
        VStack(spacing: 5) { Text(value.formatted()).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(tint); Text(label).font(.system(size: 10)).foregroundStyle(theme.secondaryInk).multilineTextAlignment(.center) }.frame(maxWidth: .infinity)
    }
    private func entityMemories(_ kind: String) -> [RiverSharedStateRecord] {
        memories.filter { memory in
            let raw = RiverIOSProjection.memoryKind(memory)
            switch kind { case "projects": return raw == "projectTrajectory"; case "people": return raw == "interpersonal"; case "habits": return raw == "habit"; default: return false }
        }
    }
    private func collectionTitle(_ key: String) -> String { switch key { case "places": "Places · 地点记忆"; case "people": "People · 人物记忆"; case "habits": "Habits · 习惯记忆"; default: "Projects · 项目记忆" } }
    private var collectionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 16) {
            collectionTile("projects", title: "Projects", subtitle: "项目", symbol: "folder", count: entityMemories("projects").count, tint: theme.accentText)
            collectionTile("places", title: "Places", subtitle: "地点", symbol: "mappin.and.ellipse", count: places.count, tint: .pink)
            collectionTile("people", title: "People", subtitle: "人物", symbol: "person.2", count: entityMemories("people").count, tint: .purple)
            collectionTile("habits", title: "Habits", subtitle: "习惯", symbol: "leaf", count: habits.count + entityMemories("habits").count, tint: theme.success)
        }
    }
    private func collectionTile(_ key: String, title: String, subtitle: String, symbol: String, count: Int, tint: Color) -> some View {
        Button { collection = MemoryCollection(id: key) } label: {
            RiverIOSPanel(padding: 16) {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 8) { RiverIconChip(symbol: symbol, tint: tint, size: 30); VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline.weight(.semibold)); Text(subtitle).font(.caption2).foregroundStyle(theme.secondaryInk) } }
                    HStack(alignment: .firstTextBaseline) { Text(count.formatted()).font(.system(size: 28, weight: .bold, design: .rounded)); Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(theme.secondaryInk) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.riverTactile().accessibilityIdentifier("river.memory.collection.\(key)")
    }
    private var habitHighlights: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("River 知道的关于你").font(.headline)
                Spacer(minLength: 0)
                NavigationLink("管理规则 ›") { libraryDetail }.font(.caption).foregroundStyle(theme.accentText)
            }
            if habits.isEmpty && entityMemories("habits").isEmpty {
                RiverIOSPanel { VStack(alignment: .leading, spacing: 8) { Label("习惯会从生活中慢慢浮现", systemImage: "leaf").font(.subheadline.weight(.medium)); Text("自动记录积累后，River 会发现重复的生活节奏。你确认后，再记为长期习惯。").font(.caption).lineSpacing(4).foregroundStyle(theme.secondaryInk) } }
            }
            ForEach(habits.prefix(2)) { habitRuleRow($0) }
            ForEach(entityMemories("habits").prefix(2)) { memoryRow($0).padding(16).riverNeumorphic() }
        }
    }
    private var collectionText: String {
        let reviews = automaticJournals.map { "## \($0.day) · AI 自动日记\n\n\($0.body)" }
        let notes = journals.map { "## \($0.day) · 日记与补充\n\n\($0.body)" }
        let saved = memories.map { "## \(RiverIOSProjection.memoryText($0, key: "title") ?? "生活记忆")\n\n\(RiverIOSProjection.memoryText($0, key: "body") ?? "")" }
        return (["# \(nickname)的生活编年史", "导出日期：\(Date.now.formatted(date: .numeric, time: .shortened))"] + reviews + notes + saved).joined(separator: "\n\n")
    }
    private var exportCollection: some View {
        RiverIOSPanel(padding: 16) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) { Text("生成我的专属生活编年史").font(.subheadline.weight(.semibold)); Text("将当前归档与搜索结果汇成可保存的文字").font(.caption2).foregroundStyle(theme.secondaryInk) }
                Spacer(minLength: 0)
                ShareLink(item: collectionText, preview: SharePreview("我的生活编年史")) { Label("导出", systemImage: "arrow.up.right").font(.caption.weight(.semibold)).padding(10).riverNeumorphic(radius: 15) }.disabled(archiveCount == 0)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                RiverSystemSignature()
                Text("记忆").font(theme.titleFont).accessibilityIdentifier("river.memory.title")
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("写下的日子，记得的自己。")
                        .font(theme.textFont(15)).foregroundStyle(theme.secondaryInk)
                }
            }
            Spacer(minLength: 0)
            Button { coordinator.mePath.append(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 19)).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).foregroundStyle(theme.ink)
            .accessibilityLabel("设置、同步与隐私").accessibilityIdentifier("river.memory.settings")
        }
    }
    private var search: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(theme.secondaryInk)
            TextField("搜索日记、记忆或地点", text: $query)
                .font(theme.textFont(15)).focused($searchFocused).submitLabel(.search)
                .accessibilityLabel("搜索日记正文、记忆和地点").accessibilityIdentifier("river.memory.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(theme.secondaryInk).accessibilityLabel("清除查找")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 52)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(searchFocused ? theme.accent.opacity(0.6) : theme.separator, lineWidth: searchFocused ? 1 : theme.borderWidth) }
    }
    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(options, id: \.0) { value, title in
                    Button {
                        RiverHaptics.selection()
                        selection = value
                    } label: {
                        VStack(spacing: 8) {
                            Text(title).font(theme.textFont(15, weight: selection == value ? .semibold : .regular))
                                .foregroundStyle(selection == value ? theme.ink : theme.secondaryInk)
                            Capsule().fill(selection == value ? theme.accent : .clear).frame(height: 2)
                        }.frame(minWidth: 44, minHeight: 44)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("river.memory.filter.\(value)")
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
                }
            }
        }
    }
    @ViewBuilder private var archiveContent: some View {
        if resultCount == 0 {
            emptyArchive
        } else {
            if showsAutomatic && !automaticJournals.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    archiveHeading("River 自动生成的日记", count: automaticJournals.count)
                    ForEach(automaticJournals) { item in
                        Button { readingAutomatic = item } label: {
                            RiverIOSPanel {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(item.day).font(.subheadline.weight(.semibold)); Spacer(); Text(item.status == .stale ? "依据有更新" : item.status == .provisional ? "待合并核对" : "AI 已整理").font(.caption).foregroundStyle(theme.accentText) }
                                    Text(item.body).font(.subheadline).lineSpacing(4).lineLimit(4).foregroundStyle(theme.secondaryInk)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if showsJournals && !visibleJournals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    archiveHeading(selection == "favorites" ? "收藏的日记" : isSearching ? "日记" : selection == "all" ? "最近的日记" : "全部日记", count: visibleJournals.count)
                    ForEach(selection == "all" && !isSearching ? Array(visibleJournals.prefix(6)) : visibleJournals) { item in
                        journalRow(item)
                        Divider().overlay(theme.separator)
                    }
                    if selection == "all" && !isSearching && visibleJournals.count > 6 {
                        Button("查看全部 \(visibleJournals.count) 篇日记") { selection = "journals" }
                            .font(theme.textFont(14, weight: .medium)).foregroundStyle(theme.accentText).frame(minHeight: 44)
                    }
                }
            }
            if showsMemories && !matchingMemories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    archiveHeading("关于你的记忆", count: matchingMemories.count)
                    ForEach(matchingMemories) { memory in
                        memoryRow(memory)
                        Divider().overlay(theme.separator)
                    }
                }
            }
            if showsPlaces && !matchingPlaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    archiveHeading("走过的地方", count: matchingPlaces.count)
                    ForEach(matchingPlaces) { place in
                        NavigationLink { RiverPlaceDetailView(placeID: place.id) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "mappin.and.ellipse").font(.system(size: 18)).foregroundStyle(theme.accentText).frame(width: 28).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(place.displayName).font(theme.textFont(16, weight: .medium))
                                    if let address = place.mapAddress, !address.isEmpty { Text(address).font(theme.textFont(13)).foregroundStyle(theme.secondaryInk).lineLimit(2) }
                                    Text("\(place.visitCount) 次到访 · 最近 \(place.lastSeen.formatted(date: .abbreviated, time: .omitted))")
                                        .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk).padding(.top, 5)
                            }.padding(.vertical, 12).frame(minHeight: 68).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("river.memory.place.\(place.id)")
                        Divider().overlay(theme.separator)
                    }
                }
            }
        }
    }
    private func archiveHeading(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(theme.sectionFont).accessibilityAddTraits(.isHeader)
            Spacer()
            Text(count.formatted()).font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk).monospacedDigit()
        }.padding(.bottom, 4)
    }
    private var emptyArchive: some View {
        let title = isSearching ? "没有找到相关内容" : selection == "favorites" ? "把想重读的日子留下" : selection == "memories" ? "关于你的记忆，从真实记录开始" : selection == "places" ? "这里会记得你走过的地方" : "从今天，留下一页记忆"
        let detail = isSearching ? "可以搜索日期、正文中的词、记忆标题或地点名称。" : selection == "favorites" ? "长按自己写下的日记，选择“收藏日记”。" : selection == "memories" ? "在 River 对话或记录日常后，已有的个人记忆会收在这里。每一条都可以查看来源和更正。" : selection == "places" ? "在设置中开启位置记录，或回到今天补记地点。" : "开启记录来源并连接 AI 后，自动日记会陆续归档。手动补充可选。"
        return RiverEmptyState(title: title, detail: detail, systemImage: selection == "places" ? "mappin.and.ellipse" : selection == "memories" ? "sparkle" : "book.closed", showsChrome: false, actionTitle: isSearching ? "清除搜索" : selection == "favorites" ? "浏览日记" : selection == "memories" ? "与 River 聊聊" : selection == "places" ? "管理位置记录" : "连接自动记录来源") {
            if isSearching { query = "" }
            else if selection == "favorites" { selection = "journals" }
            else if selection == "memories" { coordinator.selectedTab = .river }
            else if selection == "places" { coordinator.mePath.append(.settings) }
            else { coordinator.mePath.append(.settings) }
        }
    }
    private func journalRow(_ item: JournalItem) -> some View {
        NavigationLink {
            if let record = item.shared { RiverSavedJournalView(id: record.id) }
            else if let legacy = item.legacy { RiverArchiveLegacyJournalView(entry: legacy) }
        } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text(item.day).font(.footnote).foregroundStyle(theme.secondaryInk)
                    } else {
                        Text(String(item.day.suffix(2))).font(theme.textFont(24, relativeTo: .title3, weight: .medium)).monospacedDigit()
                        Text(shortDateLabel(item.day)).font(theme.textFont(11, relativeTo: .caption)).foregroundStyle(theme.secondaryInk)
                    }
                }.frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 38, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.title).font(theme.textFont(17, relativeTo: .headline, weight: .medium)).lineLimit(2)
                        if item.favorite { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(theme.accentText) }
                    }
                    if !item.excerpt.isEmpty { Text(item.excerpt).font(theme.textFont(14)).foregroundStyle(theme.secondaryInk).lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).multilineTextAlignment(.leading) }
                    Text(item.day).font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(theme.secondaryInk)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk.opacity(0.7)).padding(.top, 8)
                }
            }.padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("river.memory.journal.\(item.day)")
        .contextMenu {
            if let record = item.shared { Button(item.favorite ? "取消收藏" : "收藏日记", systemImage: item.favorite ? "bookmark.slash" : "bookmark") { toggleFavorite(record) } }
        }
    }
    private func shortDateLabel(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        return "\(parts[1])月"
    }
    private func toggleFavorite(_ record: RiverSharedStateRecord) {
        guard let old = record.journalEntryContent, let database = node.database else { return }
        var tags = old.tags
        if tags.contains("river-favorite") { tags.removeAll { $0 == "river-favorite" } } else { tags.append("river-favorite") }
        let value = RiverJournalEntryContent(dayKey: old.dayKey, body: old.body, moodScore: old.moodScore, energyScore: old.energyScore, focusScore: old.focusScore, outputScore: old.outputScore, category: old.category, tags: tags, source: old.source, updatedAt: .now)
        guard let updated = RiverSharedStateRecord.journalEntry(value) else { return }
        do {
            try database.saveSharedUserRecord(updated)
            let message = tags.contains("river-favorite") ? "已收藏" : "已取消收藏"
            feedback = .success(message)
            RiverHaptics.success()
            synchronizeIfAvailable()
        } catch {
            feedback = .failure("收藏暂未保存：\(error.localizedDescription)")
            RiverHaptics.error()
        }
    }
    private var libraryLinks: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("档案管理").font(theme.sectionFont).padding(.bottom, 8)
            Button { showsJournal = true } label: {
                archiveLinkRow("按月份读日记", detail: "从一篇日记回到当时的生活", symbol: "book", showsDivider: true)
            }.buttonStyle(.plain).accessibilityIdentifier("river.memory.journals")
            NavigationLink { libraryDetail } label: {
                archiveLinkRow("确认的个人规则", detail: "\(habits.count) 条习惯与规则", symbol: "leaf", showsDivider: true)
            }.buttonStyle(.plain)
            NavigationLink { answersDetail } label: {
                archiveLinkRow("确认与回答", detail: "\(resolvedQuestions.count + answeredHabits.count) 条已处理 · 可以重新确认", symbol: "checkmark.circle", showsDivider: false)
            }.buttonStyle(.plain).accessibilityIdentifier("river.memory.answers")
        }
    }
    private func archiveLinkRow(_ title: String, detail: String, symbol: String, showsDivider: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(theme.accentText).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(theme.textFont(15, weight: .medium))
                Text(detail).font(theme.textFont(12)).foregroundStyle(theme.secondaryInk)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk)
        }
        .padding(.vertical, 14).frame(minHeight: 64).contentShape(Rectangle())
        .overlay(alignment: .bottom) { if showsDivider { Rectangle().fill(theme.separator).frame(height: 0.5) } }
    }
    private var libraryDetail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("由你确认，按你的方式理解生活。")
                    .font(theme.bodyFont).foregroundStyle(theme.secondaryInk)
                if habits.isEmpty {
                    RiverEmptyState(title: "还没有确认的个人规则", detail: "River 提出的习惯线索需要经过你的确认。", systemImage: "leaf", showsChrome: false, actionTitle: "查看待确认线索") { coordinator.openConfirmations() }
                } else { ForEach(habits) { habitRuleRow($0) } }
            }.padding(theme.pageGutter)
        }.background(theme.canvas).navigationTitle("个人规则").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    private var answersDetail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if answeredHabits.isEmpty && resolvedQuestions.isEmpty {
                    RiverEmptyState(title: "这里保存你做过的确认", detail: "回答和更正会成为 River 理解你的依据。", systemImage: "checkmark.circle", showsChrome: false, actionTitle: "查看待确认线索") { coordinator.openConfirmations() }
                }
                ForEach(answeredHabits) { answeredHabitRow($0) }
                ForEach(resolvedQuestions) { resolvedQuestionRow($0) }
            }.padding(theme.pageGutter)
        }.background(theme.canvas).navigationTitle("确认与回答").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
    private func memoryRow(_ record: RiverSharedStateRecord) -> some View {
        NavigationLink { RiverMemoryDetailView(memoryID: record.id) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(RiverIOSProjection.memoryText(record, key: "title") ?? "一条个人记忆")
                        .font(theme.textFont(17, relativeTo: .headline, weight: .medium)).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondaryInk).padding(.top, 6)
                }
                if let body = RiverIOSProjection.memoryText(record, key: "body"), !body.isEmpty {
                    Text(body).font(theme.textFont(14)).foregroundStyle(theme.secondaryInk)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("\(kindLabel(RiverIOSProjection.memoryKind(record))) · \(isConfirmed(record) ? "你已确认" : "River 暂定理解") · \(record.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(theme.textFont(12, relativeTo: .footnote)).foregroundStyle(isConfirmed(record) ? theme.accentText : theme.secondaryInk)
            }.padding(.vertical, 12).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("river.memory.item.\(record.id.uuidString)")
        .accessibilityLabel("\(RiverIOSProjection.memoryText(record, key: "title") ?? "个人记忆")，\(isConfirmed(record) ? "你已确认" : "River 暂定理解")，查看依据与更正选项")
    }
    private func habitRuleRow(_ record: RiverSharedStateRecord) -> some View {
        let payload = jsonObject(record.payloadJSON)
        let title = payload["scopeText"] as? String ?? payload["conditionAppName"] as? String ?? "已确认的个人规则"
        let detail = payload["conclusionCategory"] as? String ?? "已由用户确认"
        return RiverIOSPanel {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(theme.secondaryInk)
                }
            } icon: {
                Image(systemName: "leaf").foregroundStyle(theme.accentText)
            }
        }
    }

    private func answeredHabitRow(_ record: RiverSharedStateRecord) -> some View {
        let payload = jsonObject(record.payloadJSON)
        let question = payload["question"] as? String ?? "习惯回顾"
        let answer = payload["answerScopeText"] as? String ?? (record.status == "skipped" ? "暂不确定" : "已保存回答")
        return RiverIOSPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(question).font(.subheadline.weight(.semibold))
                Text(answer).font(.caption).foregroundStyle(theme.secondaryInk)
                Button("撤销回答并重新确认", role: .destructive) {
                    node.undoSharedHabitCard(record)
                    synchronizeIfAvailable()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func resolvedQuestionRow(_ record: RiverSharedStateRecord) -> some View {
        let content = record.pendingConfirmationContent
        let result = content?.correction ?? content?.candidate ?? statusLabel(record.status)
        return RiverIOSPanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(content?.question ?? "已处理的问题").font(.subheadline.weight(.semibold))
                Text("上次回答：\(result)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryInk)
                Button("重新确认这条问题") {
                    node.reopenSharedPendingConfirmation(record)
                    synchronizeIfAvailable()
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func isConfirmed(_ record: RiverSharedStateRecord) -> Bool {
        record.status == "confirmed" || (node.database?.memoryConfirmation(for: record.id)?.confirmed == true)
    }

    private func kindLabel(_ raw: String) -> String {
        switch raw {
        case "longTermFact": "长期事实"
        case "habit": "习惯"
        case "projectTrajectory": "项目轨迹"
        case "interpersonal": "关系"
        case "journey": "旅程"
        default: "个人记忆"
        }
    }

    private func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func synchronizeIfAvailable() {
        if drive.hasAccess { node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate) }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "confirmed": "已确认"
        case "rejected": "已标记为不准确"
        case "corrected": "已更正"
        default: "已暂时关闭"
        }
    }
}

struct RiverMemoryDetailView: View {
    @Environment(\.riverTheme) private var theme
    let memoryID: UUID
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var coordinator: RiverAppCoordinator
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var diary: DiaryStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var title = ""
    @State private var bodyText = ""
    @State private var initialized = false
    @State private var feedback: String?
    @State private var showingDeleteConfirmation = false
    @State private var showsAllEvidence = false
    @State private var showsCorrectionEditor = false
    @FocusState private var focusedField: MemoryField?

    private enum MemoryField { case title, body }
    private var record: RiverSharedStateRecord? { node.database?.sharedUserRecords.first { $0.id == memoryID } }
    private var memoryObject: [String: Any] { record.map { jsonObject($0.payloadJSON) } ?? [:] }
    private var evidenceReferences: [String] {
        let explicit = memoryObject["evidenceRefs"] as? [String] ?? []
        let episodes = (memoryObject["sourceEpisodeIDs"] as? [String] ?? []).map { "episode:\($0)" }
        return Array(Set(explicit + episodes)).sorted()
    }
    private var confirmed: Bool {
        guard let record else { return false }
        return record.status == "confirmed" || (node.database?.memoryConfirmation(for: record.id)?.confirmed == true)
    }
    private var sourceCount: Int { evidenceReferences.count }
    private var evidenceItems: [RiverMemoryEvidenceItem] {
        guard let database = node.database else { return [] }
        let eventIDs = evidenceReferences.compactMap { reference -> UUID? in
            let parts = reference.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  ["raw", "capture", "event", "location"].contains(String(parts[0])) else { return nil }
            return UUID(uuidString: String(parts[1]))
        }
        let events = (try? database.events(ids: eventIDs)) ?? []
        let eventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        return evidenceReferences.compactMap { reference in
            let parts = reference.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let kind = parts[0]
            let value = parts[1]
            if kind == "diary", let journal = node.database?.sharedUserRecords.first(where: {
                $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == value
            })?.journalEntryContent {
                return RiverMemoryEvidenceItem(
                    id: reference,
                    title: "你写下的日记 · \(value)",
                    detail: journal.body,
                    date: date(forDayKey: value),
                    eventID: nil,
                    journalDayKey: value
                )
            }
            if kind == "episode" {
                return RiverMemoryEvidenceItem(
                    id: reference,
                    title: "Mac 上的来源片段",
                    detail: "这类片段尚未随共享状态复制到 iPhone，因此此处无法展开原文。",
                    date: nil,
                    eventID: nil,
                    journalDayKey: nil
                )
            }
            guard ["raw", "capture", "event", "location"].contains(kind),
                  let eventID = UUID(uuidString: value),
                  let event = eventsByID[eventID],
                  let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
            let title = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? payload.text!.trimmingCharacters(in: .whitespacesAndNewlines)
                : (payload.appName.map { "使用 \($0)" }
                    ?? payload.locationName
                    ?? payload.mapAddress
                    ?? "一条生活记录")
            return RiverMemoryEvidenceItem(
                id: reference,
                title: title,
                detail: "\(RiverIOSProjection.sourceLabel(event.source)) · \(event.observedAt.formatted(date: .abbreviated, time: .shortened))",
                date: event.observedAt,
                eventID: eventID,
                journalDayKey: nil
            )
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let record, record.status != "deleted" {
                    RiverIOSPageHeader(title: title.isEmpty ? "记忆详情" : title,
                                      subtitle: confirmed ? "你已确认 · 可查看来源、更正或删除。" : "River 的暂定理解 · 可查看来源、更正或删除。")
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("River 的理解").font(theme.sectionFont)
                            if !bodyText.isEmpty {
                                Text(bodyText).font(theme.textFont(18)).lineSpacing(8).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("这条记忆没有附带解释文字。")
                                    .font(.subheadline)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                            Text(confirmed ? "状态：你已明确确认或更正。" : "状态：暂定理解，尚未由你确认。")
                                .font(.caption)
                                .foregroundStyle(theme.secondaryInk)
                            if let decision = node.database?.memoryConfirmation(for: record.id) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("你的确认记录：\(decision.confirmed ? "已确认" : "已撤销确认") · \(decision.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryInk)
                                    if !decision.note.isEmpty {
                                        Text("你的备注：\(decision.note)")
                                            .font(.caption)
                                            .foregroundStyle(theme.secondaryInk)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    RiverIOSPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("来源与更新时间").font(.headline)
                            LabeledContent("记忆类型", value: memoryKindLabel(memoryObject["kind"] as? String ?? "other"))
                            LabeledContent("建立时间", value: record.createdAt.formatted(date: .abbreviated, time: .shortened))
                            LabeledContent("最近更新", value: record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                            if let confidence = memoryObject["confidence"] as? NSNumber {
                                LabeledContent("模型置信度", value: "\(confidence.intValue)%")
                            }
                            if evidenceItems.isEmpty && sourceCount == 0 {
                                Text("当前共享记录没有可在 iPhone 展开的来源片段。")
                                    .font(.caption)
                                    .foregroundStyle(theme.secondaryInk)
                            }
                        }
                    }
                    if !evidenceItems.isEmpty {
                        RiverIOSPanel {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("支持来源 · \(sourceCount)").font(.headline)
                                ForEach(Array(evidenceItems.prefix(showsAllEvidence ? evidenceItems.count : 8))) { item in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(theme.ink)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 5)
                                        Text(item.detail)
                                            .font(.caption)
                                            .foregroundStyle(theme.secondaryInk)
                                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                                        if let eventID = item.eventID, let date = item.date {
                                            Button("查看对应时间线") {
                                                coordinator.openTimeline(eventID: eventID, date: date)
                                            }
                                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                                        } else if let dayKey = item.journalDayKey, let date = date(forDayKey: dayKey) {
                                            Button("回到当天") { coordinator.openTimeline(day: date) }
                                                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                                        }
                                    }
                                    if item.id != evidenceItems.prefix(showsAllEvidence ? evidenceItems.count : 8).last?.id { Divider() }
                                }
                                if evidenceItems.count > 8 {
                                    Button(showsAllEvidence ? "收起来源" : "显示全部 \(evidenceItems.count) 条来源") { showsAllEvidence.toggle() }
                                        .frame(minHeight: 44)
                                        .accessibilityIdentifier("river.memory.evidence.expand")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryInk)
                                }
                                if sourceCount > evidenceItems.count {
                                    Text("还有 \(sourceCount - evidenceItems.count) 个来源无法在这台 iPhone 上展开。")
                                        .font(.caption)
                                        .foregroundStyle(theme.secondaryInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    RiverIOSPanel {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("由你决定").font(theme.sectionFont)
                            if showsCorrectionEditor {
                                TextField("记忆标题", text: $title)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .title)
                                    .accessibilityLabel("记忆标题")
                                TextEditor(text: $bodyText)
                                    .font(theme.textFont(16)).frame(minHeight: 140)
                                    .scrollContentBackground(.hidden).padding(8)
                                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .focused($focusedField, equals: .body)
                                    .accessibilityLabel("记忆内容")
                                Button("保存我的更正") { saveCorrection(record) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                Button("取消编辑") {
                                    title = RiverIOSProjection.memoryText(record, key: "title") ?? ""
                                    bodyText = RiverIOSProjection.memoryText(record, key: "body") ?? ""
                                    focusedField = nil
                                    showsCorrectionEditor = false
                                }.frame(minHeight: 44)
                            } else {
                                Button("更正这条记忆", systemImage: "square.and.pencil") { showsCorrectionEditor = true }
                                    .font(theme.textFont(15, weight: .medium)).frame(minHeight: 44)
                                    .accessibilityIdentifier("river.memory.detail.edit")
                            }
                            Button(confirmed ? "撤销确认" : "确认这条记忆") {
                                node.setSharedMemoryConfirmation(record, confirmed: !confirmed)
                                syncIfAvailable()
                                feedback = node.habitActionMessage ?? "确认决定已处理。"
                            }
                            .buttonStyle(.bordered)
                            if let feedback { Text(feedback).font(.caption).foregroundStyle(theme.secondaryInk) }
                            Button("删除这条记忆", role: .destructive) { showingDeleteConfirmation = true }
                                .font(.subheadline)
                        }
                    }
                } else {
                    ContentUnavailableView("这条记忆已删除", systemImage: "trash",
                                            description: Text("删除决定保存在共享状态中，后续同步会让其他设备也移除该记忆。"))
                }
            }
            .padding(20)
            .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 120 : 26)
        }
        .background(theme.canvas.ignoresSafeArea())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("记忆详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
            }
        }
        .confirmationDialog("删除这条记忆？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除并同步", role: .destructive) { deleteMemory() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除决定会写入共享状态；同步后，这条记忆会从其他设备的长期记忆中移除。")
        }
        .onAppear { initializeDraft() }
    }

    private func initializeDraft() {
        guard !initialized, let record else { return }
        title = RiverIOSProjection.memoryText(record, key: "title") ?? ""
        bodyText = RiverIOSProjection.memoryText(record, key: "body") ?? ""
        initialized = true
    }

    private func saveCorrection(_ record: RiverSharedStateRecord) {
        node.correctSharedMemory(record, title: title, body: bodyText)
        syncIfAvailable()
        feedback = node.habitActionMessage ?? "更正已处理。"
        focusedField = nil
        showsCorrectionEditor = false
    }

    private func deleteMemory() {
        guard let record else { return }
        node.deleteSharedMemory(record)
        syncIfAvailable()
        feedback = node.habitActionMessage ?? "删除决定已处理。"
    }

    private func syncIfAvailable() {
        if drive.hasAccess { node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate) }
    }

    private func memoryKindLabel(_ raw: String) -> String {
        switch raw {
        case "longTermFact": "长期事实"
        case "habit": "习惯"
        case "projectTrajectory": "项目轨迹"
        case "interpersonal": "关系"
        case "journey": "旅程"
        default: "其他"
        }
    }

    private func jsonObject(_ text: String) -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func date(forDayKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: key)
    }
}
