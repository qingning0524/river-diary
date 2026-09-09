import SwiftUI

struct InsightView: View {
    let entries: [DiaryEntry]
    @ObservedObject var ai: AIAssistantStore
    var showsHeader: Bool = true

    private var recentEntries: [DiaryEntry] {
        Array(entries.suffix(7))
    }

    private var average: Int {
        let scores = entries.compactMap(\.score)
        guard !scores.isEmpty else { return 0 }
        return Int((scores.reduce(0, +) / Double(scores.count)).rounded())
    }

    private var recentChange: Int {
        let scores = entries.compactMap(\.score)
        guard scores.count >= 8 else { return 0 }
        let previous = scores.suffix(8).prefix(4).reduce(0, +) / 4
        let current = scores.suffix(4).reduce(0, +) / 4
        return Int(current - previous)
    }

    private var signals: [MoodSignal] {
        MoodAnalyzer.frequentSignals(entries: entries)
    }

    private var headlineReading: MoodReading {
        MoodAnalyzer.reading(for: entries.last?.displayOverview ?? "")
    }

    private func recentAverage(_ keyPath: KeyPath<DiaryEntry, Int>) -> Int {
        guard !recentEntries.isEmpty else { return 0 }
        return recentEntries.map { $0[keyPath: keyPath] }.reduce(0, +) / recentEntries.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if showsHeader {
                    header
                }
                stats
                detail
                SoftCard {
                    AITaskCard(
                        ai: ai,
                        task: .insightReading,
                        buttonTitle: "生成 AI 洞察",
                        emptyMessage: "AI 会阅读近期日记，寻找重复出现的情绪、精力与专注线索。"
                    ) {
                        Task { await ai.analyzeInsight(entries: entries) }
                    }
                }
                .frame(maxWidth: 1280)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Insight").font(.caption.smallCaps()).foregroundStyle(.secondary)
            Text("状态").font(.system(size: 34, weight: .semibold)).foregroundStyle(Color.ink)
            Text("这些都是从你的文字里读出来的，不会上传。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private var stats: some View {
        EqualWidthRow(spacing: 12) {
            stat("记录天数", "\(entries.count)", "天 · 形成自我观察")
            stat("平均情绪", "\(average)", "分 · 包括低点与恢复")
            stat("近期变化", "\(recentChange >= 0 ? "+" : "")\(recentChange)", "分 · 近四天对比")
            stat("当前阶段", entries.last?.stateLabel ?? "平稳", "最新一天的状态")
        }
        .frame(maxWidth: 1280)
    }

    private func stat(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.editorial(26))
                .foregroundStyle(LinearGradient.river())
            Text(detail).font(.caption).lineLimit(2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: AppRadius.cardSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppRadius.cardSmall, style: .continuous).stroke(Color.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
        .shadow(color: .black.opacity(0.05), radius: 18, x: 0, y: 12)
    }

    private var detail: some View {
        EqualWidthRow(spacing: 18) {
            SoftCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("近七日状态").font(.headline)
                    Text(headlineReading.summary)
                        .font(.system(size: 14))
                        .lineSpacing(7)
                        .foregroundStyle(Color.secondaryInk)

                    VStack(spacing: 13) {
                        bar("心情", recentAverage(\.mood))
                        bar("专注", recentAverage(\.focus))
                        bar("产出", recentAverage(\.output))
                        bar("精力", recentAverage(\.energy))
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("常出现的词").font(.caption.weight(.semibold))
                        if signals.isEmpty {
                            Text("近 30 天暂时没有稳定重复的情绪词。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(signals.prefix(4)) { signal in
                                HStack {
                                    Text(signal.word).font(.caption)
                                    Spacer()
                                    Text("出现 \(signal.count) 次")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            SoftCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("情绪关键词").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(signals) { signal in
                            HStack(spacing: 5) {
                                Text(signal.word)
                                Text("\(signal.count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.ink.opacity(0.12), in: Capsule())
                            }
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.chip, in: Capsule())
                            .foregroundStyle(Color.secondaryInk)
                        }

                        if signals.isEmpty {
                            ForEach(["安静", "记录", "等待"], id: \.self) { word in
                                Text(word)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.chip, in: Capsule())
                            }
                        }
                    }
                    Spacer()
                }
            }
        }
        .frame(maxWidth: 1280)
    }

    private func bar(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
            ProgressBar(value: Double(value))
            Text("\(value)").font(.caption2).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
