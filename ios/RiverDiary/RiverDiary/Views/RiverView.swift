import Charts
import SwiftUI

struct RiverView: View {
    @EnvironmentObject private var store: DiaryStore
    @State private var selectedEntryID: String?

    private var ratedEntries: [DiaryEntry] {
        store.entries.filter { $0.score != nil }.reversed()
    }

    private var selectedEntry: DiaryEntry? {
        selectedEntryID.flatMap { id in
            store.entries.first { $0.id == id }
        } ?? store.latestEntry
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    riverChart
                    if let selectedEntry {
                        selectedCard(selectedEntry)
                    }
                    stageLegend
                }
                .padding(16)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("情绪河流")
            .onAppear {
                selectedEntryID = selectedEntryID ?? store.latestEntry?.id
            }
        }
    }

    private var riverChart: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "最近心情", subtitle: "\(ratedEntries.count) 天")

                Chart {
                    ForEach(ratedEntries) { entry in
                        AreaMark(
                            x: .value("日期", entry.entryDate),
                            y: .value("心情", entry.score ?? 0)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.indigo.opacity(0.25), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("日期", entry.entryDate),
                            y: .value("心情", entry.score ?? 0)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(.indigo)
                        .lineStyle(StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    }

                    if let selectedEntry {
                        RuleMark(x: .value("选中", selectedEntry.entryDate))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                        PointMark(
                            x: .value("日期", selectedEntry.entryDate),
                            y: .value("心情", selectedEntry.score ?? 0)
                        )
                        .symbolSize(120)
                        .foregroundStyle(selectedEntry.stageColor)
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) {
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartOverlay { proxy in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard let date: Date = proxy.value(atX: value.location.x) else { return }
                                    let nearest = nearestEntry(to: date)
                                    if nearest?.id != selectedEntryID {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                            selectedEntryID = nearest?.id
                                        }
                                    }
                                }
                        )
                }
                .frame(height: 260)
            }
        }
    }

    private func selectedCard(_ entry: DiaryEntry) -> some View {
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(entry.entryDate, style: .date)
                            .font(.headline)
                        Text(entry.stageLabel)
                            .font(.caption)
                            .foregroundStyle(entry.stageColor)
                    }
                    Spacer()
                    Text(entry.score.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.stageColor)
                }

                Text(entry.overview ?? entry.mood ?? "这一天没有文字记录。")
                    .font(.callout)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stageLegend: some View {
        GlassCard {
            HStack(spacing: 12) {
                ForEach(Scoring.stages, id: \.label) { stage in
                    stageDot(stage)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stageDot(_ stage: Stage) -> some View {
        VStack(spacing: 6) {
            Circle()
                .fill(stage.swiftColor)
                .frame(width: 8, height: 8)
            Text(stage.label)
                .font(.caption2)
        }
    }

    private func nearestEntry(to date: Date) -> DiaryEntry? {
        ratedEntries.min {
            abs($0.entryDate.timeIntervalSince(date)) < abs($1.entryDate.timeIntervalSince(date))
        }
    }
}
