import SwiftUI

struct RiverView: View {
    let entries: [DiaryEntry]
    let selectedDate: Date
    @ObservedObject var ai: AIAssistantStore
    @State private var dayRange = 7
    @State private var selectedEntryID: String?
    var showsHeader: Bool = true

    private var visibleEntries: [DiaryEntry] {
        let endKey = DiaryEntry.dateFormatter.string(from: selectedDate)
        return entries
            .filter { $0.date <= endKey }
            .suffix(dayRange)
    }

    private var average: Int {
        let scores = visibleEntries.compactMap(\.score)
        guard !scores.isEmpty else { return 0 }
        return Int((scores.reduce(0, +) / Double(scores.count)).rounded())
    }

    private var lowEntry: DiaryEntry? {
        visibleEntries.min { ($0.score ?? 999) < ($1.score ?? 999) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeader {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Replay").font(.system(size: 11, weight: .semibold)).kerning(1.2).foregroundStyle(.tertiary)
                            Text("情绪河流")
                                .font(.editorial(34))
                                .foregroundStyle(Color.ink)
                        }
                        Spacer()
                        Picker("范围", selection: $dayRange) {
                            Text("7天").tag(7)
                            Text("30天").tag(30)
                            Text("90天").tag(90)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .tint(Color.riverAmethyst)
                        .controlSize(.large)
                        .frame(width: 280)
                    }
                    .frame(maxWidth: 1280)
                }

                chart
                SoftCard {
                    AITaskCard(
                        ai: ai,
                        task: .riverReading,
                        buttonTitle: "生成 AI 解读",
                        emptyMessage: "AI 会读取近期趋势和分数变化，描述情绪河流的流动与转折。"
                    ) {
                        Task { await ai.analyzeRiver(entries: visibleEntries) }
                    }
                }
                .frame(maxWidth: 1280)
                milestones
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .onChange(of: dayRange) {
            selectedEntryID = nil
            ai.clearTask(.riverReading)
        }
    }

    private var selectedEntry: DiaryEntry? {
        visibleEntries.first { $0.id == selectedEntryID }
    }

    private var chart: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("近 \(dayRange) 天")
                            .font(.system(size: 16, weight: .semibold))
                        Text("不是审判记录，而是看见自己如何穿过时间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 7) {
                        legend("安静", Color.riverBlue)
                        legend("变化", Color.riverAmethyst)
                        legend("温暖", Color.riverPink)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                MoodAreaChart(entries: visibleEntries, selectedID: $selectedEntryID)
                    .frame(height: 250)

                if let first = visibleEntries.first, let last = visibleEntries.last {
                    HStack {
                        Text(first.shortDate)
                        Spacer()
                        if visibleEntries.count > 2 {
                            Text(visibleEntries[visibleEntries.count / 2].shortDate)
                        }
                        Spacer()
                        Text(last.shortDate)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if let selected = selectedEntry {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(selected.shortDate + " · " + selected.stateLabel)
                                .font(.system(size: 13, weight: .semibold))
                            Text(selected.displayOverview)
                                .font(.caption)
                                .lineLimit(2)
                                .lineSpacing(4)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(selected.overall)")
                            .font(.system(size: 24, weight: .bold))
                    }
                    .padding(12)
                    .background(Color.chip, in: RoundedRectangle(cornerRadius: 14))
                }

                EqualWidthRow(spacing: 10) {
                    riverStat("平均", "\(average)")
                    riverStat("最低", "\(Int(lowEntry?.score ?? 0))")
                    riverStat("今天", "\(entries.last?.overall ?? 0)")
                    riverStat("趋势", trendText)
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private var trendText: String {
        let scores = entries.compactMap(\.score)
        guard scores.count >= 8 else { return "稳定" }
        let previous = scores.suffix(8).prefix(4).reduce(0, +) / 4
        let current = scores.suffix(4).reduce(0, +) / 4
        return current >= previous ? "↑ 恢复" : "↓ 波动"
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.chip, in: Capsule())
    }

    private func riverStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.editorial(17))
                .foregroundStyle(LinearGradient.river())
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.editor, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.border.opacity(0.7), lineWidth: 1)
        )
    }

    private var milestones: some View {
        let causes = AIDraftEngine.causes(entries: visibleEntries)

        return EqualWidthRow(spacing: 14) {
            if causes.isEmpty {
                milestone("—", "记录还太少", "没有足够的记录，就不替这一天解释。")
            } else {
                ForEach(causes, id: \.date) { cause in
                    milestone(cause.date, cause.title, cause.reason)
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private func milestone(_ date: String, _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(date).font(.caption2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).font(.caption).lineSpacing(5).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 16, y: 10)
    }
}
