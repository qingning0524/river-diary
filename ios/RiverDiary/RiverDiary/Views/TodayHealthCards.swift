import SwiftUI

struct TodaySleepCard: View {
    @EnvironmentObject private var health: HealthKitStore
    let entry: DiaryEntry

    var body: some View {
        let night = health.nights.first {
            Calendar.current.isDate($0.date, inSameDayAs: entry.entryDate)
        }
        let syncedSleepHours = entry.health?.sleepHours

        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "睡眠", subtitle: night != nil ? "Apple 健康" : "同步数据")

                if let night = night {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.1f", night.totalHours))
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text("小时")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Text(night.date, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        sleepStat("深睡", minutes: night.deep, color: .indigo)
                        sleepStat("REM", minutes: night.rem, color: .blue)
                        sleepStat("清醒", minutes: night.awake, color: .orange)
                    }

                    if let average = health.averageSleepHours {
                        Label("近 7 天均值 \(String(format: "%.1f", average)) 小时", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } else if let hours = syncedSleepHours {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.1f", hours))
                            .font(.system(size: 36, weight: .heavy, design: .rounded))
                            .contentTransition(.numericText())
                        Text("小时")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                } else if health.isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 14) {
                        Text(health.isAuthorized ? "暂时没有可读取的睡眠样本。" : "连接 Apple 健康，自动对齐休息和情绪变化。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        if !health.isAuthorized {
                            Button {
                                health.requestAuthorization()
                            } label: {
                                Text("连接 Apple 健康")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(.indigo.opacity(0.14), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }

                if let error = health.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func sleepStat(_ title: String, minutes: TimeInterval, color: Color) -> some View {
        VStack(spacing: 5) {
            Text("\(Int(minutes / 60))")
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text("\(title) · 分")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 15, style: .continuous))
    }

}

struct TodayExerciseCard: View {
    @EnvironmentObject private var health: HealthKitStore
    let entry: DiaryEntry

    var body: some View {
        let syncedHealth = entry.health
        let liveHealth = health.exerciseDays.first {
            Calendar.current.isDate($0.date, inSameDayAs: entry.entryDate)
        }
        let steps = liveHealth?.steps ?? syncedHealth?.steps
        let distance = liveHealth?.distanceKilometers ?? syncedHealth?.distanceKilometers
        let energy = liveHealth?.activeEnergyKilocalories ?? syncedHealth?.activeEnergyKilocalories

        return GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: "运动",
                    subtitle: health.isAuthorized ? "以步数为准" : "未连接"
                )

                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(steps.map { Int($0).formatted() } ?? "—")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .contentTransition(.numericText())
                    Text("步")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let average = health.averageSteps, average > 0 {
                        Text("近 7 天 \(Int(average).formatted()) 步/天")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    exerciseStat("距离", value: distance.map { String(format: "%.1f km", $0) } ?? "—", color: .mint)
                    exerciseStat("热量", value: energy.map { String(format: "%.0f kcal", $0) } ?? "—", color: .orange)
                }

                if let error = health.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !health.isAuthorized {
                    Text("在设置里连接 Apple 健康后，运动摘要会自动同步。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func exerciseStat(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
    }

}
