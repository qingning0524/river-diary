import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var health: HealthKitStore
    @State private var moodEditorEntry: DiaryEntry?

    private var entry: DiaryEntry? { store.selectedEntry }

    private var dateSelection: Binding<String?> {
        Binding(
            get: { store.selectedEntryID },
            set: { newValue in
                guard let newValue,
                      let entry = store.entries.first(where: { $0.id == newValue }) else { return }
                store.select(entry)
            }
        )
    }

    private var header: some View {
        Text("情绪河流")
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        NavigationStack {
            Group {
            if entry != nil {
                TabView(selection: dateSelection) {
                    ForEach(Array(store.entries.reversed())) { pageEntry in
                        datePage(for: pageEntry)
                            .tag(Optional(pageEntry.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy, value: store.selectedEntryID)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        header
                        if let error = store.loadError {
                            ContentUnavailableView(
                                "日记无法读取",
                                systemImage: "exclamationmark.bubble",
                                description: Text(error)
                            )
                            .padding(.top, 80)
                        } else {
                            ProgressView("正在载入日记")
                                .padding(.top, 120)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 84)
                }
            }
            }
            .background {
                ZStack {
                    Color(.systemGroupedBackground).ignoresSafeArea()

                    LinearGradient(
                        colors: [(entry?.stageColor ?? .indigo).opacity(0.22), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $moodEditorEntry) { entry in
                MoodEditorSheet(entry: entry)
            }
        }
    }

    private func datePage(for entry: DiaryEntry) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                dateSelector(for: entry)
                heroCard(for: entry)
                metricsCard(for: entry)
                sleepCard(for: entry)
                exerciseCard(for: entry)
                summaryCard(for: entry)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 84)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func dateSelector(for current: DiaryEntry) -> some View {
        TodayDateNavigator(current: current)
    }
    private func heroCard(for entry: DiaryEntry) -> some View {
        Button {
            moodEditorEntry = entry
        } label: {
            GlassCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text(Calendar.current.isDateInToday(entry.entryDate) ? "今日心情" : "当日心情")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(entry.stageLabel)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(entry.stageColor.opacity(0.16), in: .capsule)
                            .foregroundStyle(entry.stageColor)
                    }

                    HStack(alignment: .center, spacing: 14) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(entry.score.map { String(format: "%.0f", $0) } ?? "—")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .foregroundStyle(entry.stageColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                                .contentTransition(.numericText())

                            Text("/100")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 0)

                        VStack(alignment: .trailing, spacing: 4) {
                            Text("成长 \(Int(entry.metrics?.growth ?? 0))")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                            Text(entry.daily ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    moodBlock(for: entry)

                }
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: moodEditorEntry)
        .accessibilityHint("点按修改心情评分")
    }

    @ViewBuilder
    private func moodBlock(for entry: DiaryEntry) -> some View {
        let mood = entry.mood ?? "这一天还没有记录心情。"

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening")
                .font(.caption2.weight(.bold))
                .foregroundStyle(entry.stageColor)
                .frame(width: 24, height: 24)
                .background(entry.stageColor.opacity(0.13), in: .circle)

            Text(mood)
                .font(.subheadline)
                .foregroundStyle(entry.mood == nil ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16, style: .continuous))
    }

    private func metricsCard(for entry: DiaryEntry) -> some View {
        let metrics = entry.metrics

        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "今日指标", subtitle: entry.status ?? "综合表现")

                HStack(spacing: 8) {
                    MetricRing(title: "精力", value: metrics?.energy ?? 0, color: .yellow)
                    MetricRing(title: "专注", value: metrics?.focus ?? 0, color: .orange)
                    MetricRing(title: "产出", value: metrics?.output ?? 0, color: .blue)
                    MetricRing(title: "综合", value: metrics?.overall ?? 0, color: .indigo)
                }
                .frame(maxWidth: .infinity)

                if let growth = metrics?.growth {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("成长指数")
                                .font(.footnote.weight(.semibold))
                            Spacer()
                            Text(metrics?.growthStage?.label ?? "—")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(entry.growthColor)
                        }

                        ProgressView(value: max(0, min(100, growth)), total: 100)
                            .tint(entry.growthColor)
                    }
                    .padding(13)
                    .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 15, style: .continuous))
                }
            }
        }
    }

    private func sleepCard(for entry: DiaryEntry) -> some View {
        TodaySleepCard(entry: entry)
    }

    private func exerciseCard(for entry: DiaryEntry) -> some View {
        TodayExerciseCard(entry: entry)
    }
    private func summaryCard(for entry: DiaryEntry) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "当日概览", subtitle: entry.status ?? "")

                Text(entry.overview ?? "这一天没有留下概览。")
                    .font(.subheadline)
                    .foregroundStyle(entry.overview == nil ? .secondary : .primary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let screenHours = entry.screenHours, let views = entry.views {
                    HStack(spacing: 8) {
                        summaryChip(icon: "iphone", text: String(format: "%.1f 小时", screenHours))
                        summaryChip(icon: "eye", text: "\(views) 次")
                    }
                }
            }
        }
    }

    private func summaryChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: .capsule)
    }
}
