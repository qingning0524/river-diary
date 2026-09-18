import AppKit
import SwiftUI

struct TodayView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    @ObservedObject var editor: JournalEditorStore
    let openTimeline: () -> Void
    @State private var suggestion: AIDraft?
    @State private var showsAI = false
    @State private var saveError: String?
    @State private var savedDateKey: String?

    private var entry: DiaryEntry { store.entry(for: selectedDate) }
    private var buffer: JournalEditingBuffer { editor.buffer(for: entry) }
    private var captures: [QuickCapture] { store.captures(for: entry) }
    private var sessions: [ActivitySession] { activity.liveSessions(for: selectedDate) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 20) {
                    writingDesk.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            dayMaterials
                            quickNotes
                            writingAssistance
                            if entry.health != nil { bodySignals }
                        }.padding(.bottom, 20)
                    }
                    .frame(width: min(330, geometry.size.width * 0.32))
                }
            }
        }
        .onChange(of: entry.date) {
            suggestion = nil; showsAI = false; saveError = nil; savedDateKey = nil
            ai.clearTask(.dailyOverview)
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A PAGE OF YOUR LIFE").font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2).foregroundStyle(Color.riverAmethyst)
                Text(Calendar.current.isDateInToday(selectedDate) ? "今天，写下一点。" : "\(entry.shortDate)，再翻一页。")
                    .font(.editorial(32)).foregroundStyle(Color.ink)
                Text("不用写得完整，真实的一句就很好。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(selectedDate.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var writingDesk: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("我的日记", systemImage: "text.alignleft").font(.system(size: 12, weight: .medium))
                Spacer()
                if buffer.isDirty {
                    Text("未保存 · 切页会暂留草稿").font(.system(size: 10)).foregroundStyle(.secondary)
                } else if savedDateKey == entry.date {
                    Label("已保存", systemImage: "checkmark").font(.system(size: 10)).foregroundStyle(Color.riverAmethyst)
                }
                Menu {
                    Button("复制正文") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(buffer.text, forType: .string)
                    }
                    Button("复制 Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("# \(entry.date)\n\n\(buffer.text)", forType: .string)
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 22) }
                .menuStyle(.borderlessButton).fixedSize()
            }.foregroundStyle(Color.secondaryInk).padding(22)
            Divider().opacity(0.6)
            ZStack(alignment: .topLeading) {
                if buffer.text.isEmpty {
                    Text("今天有什么想留下的？\n\n一件小事、一段想法，或者此刻的心情。")
                        .font(.system(size: 16)).lineSpacing(9).foregroundStyle(.tertiary)
                        .padding(.horizontal, 28).padding(.top, 27).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { buffer.text }, set: { editor.edit(entry, text: $0) }))
                    .font(.system(size: 16)).lineSpacing(9)
                    .scrollContentBackground(.hidden).padding(20)
                    .accessibilityLabel("日记正文")
            }.frame(maxHeight: .infinity)
            Divider().opacity(0.6)
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 8) {
                    Text("此刻的心情").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    ForEach([(25, "低落"), (45, "有点累"), (65, "平静"), (80, "轻快"), (95, "很好")], id: \.0) { value, label in
                        Button { editor.edit(entry, mood: value) } label: {
                            Text(label).font(.system(size: 11))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .foregroundStyle(buffer.mood == value ? Color.riverAmethyst : Color.secondaryInk)
                                .background(buffer.mood == value ? Color.riverAmethyst.opacity(0.12) : Color.chip.opacity(0.5), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(.red) }
                HStack {
                    Text("\(buffer.text.count) 字 · 心情可选")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(action: save) {
                        HStack(spacing: 10) {
                            Text("保存这一页")
                            Text("⌘S").font(.system(size: 10)).opacity(0.5)
                        }
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ctaText)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.ctaBackground, in: Capsule())
                    }
                    .buttonStyle(.plain).keyboardShortcut("s", modifiers: .command)
                    .disabled(!buffer.isDirty)
                }
            }.padding(22)
        }
        .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.separator, lineWidth: 1))
    }

    private var dayMaterials: some View {
        SoftCard(padding: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Label("当天留下的线索", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .medium))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    let duration = sessions.reduce(0) { $0 + $1.duration }
                    Text(duration > 0 ? ActivityFormatter.time(duration) : entry.screenMinutes.map { ActivityFormatter.time(Double($0) * 60) } ?? "尚无实时片段")
                        .font(.editorial(24))
                }
                Text(sessions.isEmpty && entry.screenMinutes != nil ? "屏幕汇总 · 暂无精确时间片段" : "来自当天实时片段")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if sessions.isEmpty {
                    ForEach(Array((entry.screenApps ?? []).sorted { ($0.minutes ?? 0) > ($1.minutes ?? 0) }.prefix(3)), id: \.app) { app in
                        HStack {
                            Text(app.app).lineLimit(1)
                            Spacer()
                            Text(app.minutes.map { ActivityFormatter.time(Double($0) * 60) } ?? app.time ?? "").foregroundStyle(.secondary)
                        }.font(.system(size: 11))
                    }
                }
                let model = ActivityTimelineEngine.build(for: selectedDate, sessions: sessions)
                ForEach(model.items.filter { $0.kind == .activity }.suffix(3)) { item in
                    HStack(alignment: .top, spacing: 9) {
                        Circle().fill(Color(hex: ActivityClassifier.color(for: item.category))).frame(width: 5, height: 5).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.narrativeTitle).font(.system(size: 12)).lineLimit(2)
                            Text(item.start.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                }
                Button(action: openTimeline) {
                    HStack { Text("展开这一天的时间线"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.riverAmethyst)
                }.buttonStyle(.plain)
            }
        }
    }

    private var quickNotes: some View {
        SoftCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("随手留下的", systemImage: "quote.bubble").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(captures.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                if captures.isEmpty {
                    Text("暂时没有快记。按 ⇧⌘N，可以随时留一句。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                }
                ForEach(captures) { capture in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(capture.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                        HStack {
                            Text(Calendar.current.isDate(capture.createdAt, inSameDayAs: selectedDate) ? capture.createdAt.formatted(date: .omitted, time: .shortened) : "补记于 " + capture.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                            Button("放入日记") { append(capture.text) }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Color.riverAmethyst)
                        }
                    }.padding(.bottom, 8)
                }
            }
        }
    }

    private var writingAssistance: some View {
        SoftCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Label("需要一点提示时", systemImage: "sparkles").font(.system(size: 13, weight: .medium))
                Button("根据本机素材整理一段") {
                    suggestion = AIDraftEngine.compose(entry: entry, previous: store.entries.last { $0.date < entry.date }, quickCaptures: captures, autoPaused: false, activitySessions: sessions)
                }.font(.system(size: 12)).buttonStyle(.bordered)
                if let suggestion {
                    Text(suggestion.narrative).font(.system(size: 12)).lineSpacing(5).foregroundStyle(.secondary)
                    Button("追加到草稿") { append(suggestion.narrative) }.buttonStyle(.plain).foregroundStyle(Color.riverAmethyst)
                    DisclosureGroup("查看依据") {
                        ForEach(suggestion.evidence) { evidence in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(evidence.title).font(.caption.weight(.medium))
                                Text(evidence.detail).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }.font(.system(size: 11))
                }
                DisclosureGroup("AI 帮我回顾", isExpanded: $showsAI) {
                    AITaskCard(ai: ai, task: .dailyOverview, buttonTitle: "AI 整理这一天", emptyMessage: "主动生成时，使用你已配置的模型整理当天素材。") {
                        Task { await ai.generateDailyOverview(entry: entry, quickCaptures: captures, activitySessions: sessions) }
                    } trailing: {
                        if let answer = ai.state(for: .dailyOverview)?.answer {
                            Button("追加到草稿") { append(answer) }.buttonStyle(.plain)
                        }
                    }
                }.font(.system(size: 12))
            }
        }
    }

    private var bodySignals: some View {
        SoftCard(padding: 18) {
            VStack(alignment: .leading, spacing: 13) {
                Label("身体的声音", systemImage: "leaf").font(.system(size: 13, weight: .medium))
                if let steps = entry.health?.steps { detail("走过的步数", "\(steps) 步") }
                if let distance = entry.health?.distanceKM { detail("活动距离", String(format: "%.1f 公里", distance)) }
                if let energy = entry.health?.activeEnergyKcal { detail("活动能量", String(format: "%.0f 千卡", energy)) }
            }
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value) }.font(.system(size: 12))
    }
    private func append(_ text: String) {
        editor.edit(entry, text: buffer.text.isEmpty ? text : buffer.text + "\n\n" + text)
    }
    private func save() {
        do {
            try store.saveWriting(entry: entry, text: buffer.text, mood: buffer.mood)
            editor.saved(entry.date); savedDateKey = entry.date; saveError = nil
        } catch { saveError = error.localizedDescription }
    }
}
