import SwiftUI

struct ActivityView: View {
    @ObservedObject var activity: ActivityStore
    @Binding var selectedDate: Date
    @ObservedObject var ai: AIAssistantStore
    let entries: [DiaryEntry]
    let quickCaptures: [QuickCapture]

    @State private var period = 1
    @State private var selectedApp: String?
    @State private var showsConfidenceDetails = false
    @State private var showsDetails = false

    private var summary: FusedRangeStats {
        activity.summary(entries: entries, days: period, around: selectedDate)
    }



    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                periodPicker
                summaryCard
                TimelineSegmentCardView(
                    date: selectedDate,
                    sessions: activity.liveSessions(for: selectedDate),
                    quickCaptures: quickCaptures
                )
                correlationCard
                DayTimelineView(
                    sessions: activity.liveSessions(for: selectedDate),
                    date: selectedDate
                )
                timelineCard
                trendCard
                appRankingCard
                detailsCard
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Footprint")
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
            Text("足迹")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text("项目数据提供每日总量，实时记录补充时间段。两者不会重复相加。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private var periodPicker: some View {
        HStack(spacing: 7) {
            ForEach([1, 7, 30], id: \.self) { days in
                Button {
                    period = days
                } label: {
                    Text(days == 1 ? "今天" : "\(days) 天")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(period == days ? Color.ctaText : Color.secondaryInk)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(period == days ? Color.ctaBackground : Color.chip, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }

    private var summaryCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("记录概览", systemImage: "sparkles")
                            .font(.headline)
                        Text(summary.headline)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    StatusBadge("最近 \(summary.days) 天")
                }

                Text(summary.narrative)
                    .font(.system(size: 14))
                    .lineSpacing(7)
                    .foregroundStyle(.secondary)

                EqualWidthRow(spacing: 10) {
                    ActivityMetricView(
                        title: "每日屏幕时间",
                        value: ActivityFormatter.time(summary.pipelineTotal),
                        icon: "display"
                    )
                    ActivityMetricView(
                        title: "实时分段",
                        value: ActivityFormatter.time(summary.liveTotal),
                        icon: "waveform.path.ecg"
                    )
                    ActivityMetricView(
                        title: "实时专注",
                        value: ActivityFormatter.time(summary.focusTotal),
                        icon: "target"
                    )
                    ActivityMetricView(
                        title: "最长片段",
                        value: ActivityFormatter.time(summary.liveSessions.map(\.duration).max() ?? 0),
                        icon: "flowchart.fill"
                    )
                }
            }
        }
    }

    private var correlations: [ActivityCorrelation] {
        ActivityCorrelationEngine.insights(dayStats: summary.dayStats, entries: entries)
    }

    private var correlationCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("心情和足迹", systemImage: "arrow.triangle.branch")
                        .font(.headline)
                    Spacer()
                    Text("相关趋势，不代表因果")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if correlations.allSatisfy({ !$0.isUsable }) {
                    Text("连续记几天后，这里更容易看出稳定联系。")
                        .font(.caption)
                        .lineSpacing(5)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 10) {
                        ForEach(correlations.filter(\.isUsable)) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: item.colorHex))
                                    .frame(width: 28, height: 28)
                                    .background(Color.chip, in: Circle())

                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 8) {
                                        Text(item.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(Color.ink)
                                        Text(item.directionLabel)
                                            .font(.caption2)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 3)
                                            .background(Color(hex: item.colorHex).opacity(0.14), in: Capsule())
                                    }

                                    Text(item.detail)
                                        .font(.caption)
                                        .lineSpacing(5)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 12)

                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("\(item.strength)%")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(Color.ink)
                                    Text("\(item.sampleCount) 天样本")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.chip, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
    }

    private var timelineCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("24 小时分布", systemImage: "chart.bar.fill")
                        .font(.headline)
                    Spacer()
                    StatusBadge("来自 macOS 实时片段")
                }

                GeometryReader { proxy in
                    let maxDuration = max(300, summary.timeline.map(\.duration).max() ?? 0)
                    HStack(alignment: .bottom, spacing: proxy.size.width / 110) {
                        ForEach(summary.timeline) { hour in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(hour.duration < 1 ? Color.primary.opacity(0.06) : Color(hex: ActivityClassifier.color(for: hour.primaryCategory)))
                                    .frame(height: max(3, proxy.size.height * hour.duration / maxDuration))
                                Text(hour.hour % 3 == 0 ? "\(hour.hour)" : "")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: proxy.size.height, alignment: .bottom)
                }
                .frame(height: 126)

                if summary.liveSessions.isEmpty {
                    Text("还没有已结束的实时片段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 9) {
                        ForEach(summary.categoryUsage.prefix(5)) { category in
                            HStack(spacing: 5) {
                                Circle().fill(Color(hex: ActivityClassifier.color(for: category.name))).frame(width: 7, height: 7)
                                Text(category.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var trendCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                Label("每日趋势", systemImage: "chart.line.uptrend.xyaxis").font(.headline)

                let maxPipeline = max(300.0, summary.dayStats.map(\.pipelineTotal).max() ?? 1)
                let maxLive = max(300.0, summary.dayStats.map(\.liveTotal).max() ?? 1)

                VStack(spacing: 12) {
                    ForEach(Array(summary.dayStats.reversed().enumerated()), id: \.element.id) { pair in
                        let day = pair.element
                        HStack(spacing: 10) {
                            Text(day.dateKey.suffix(5))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 48, alignment: .leading)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 5) {
                                ProgressBar(
                                    value: day.pipelineTotal / maxPipeline * 100,
                                    colors: [Color(hex: "#7787FF"), Color(hex: "#FFC7D6")]
                                )
                                ProgressBar(
                                    value: day.liveTotal / maxLive * 100,
                                    colors: [Color(hex: "#59BF8A"), Color(hex: "#BDF2D2")]
                                )
                            }

                            Text(ActivityFormatter.time(day.pipelineTotal))
                                .font(.caption2.monospacedDigit())
                                .frame(width: 72, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var appRankingCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("应用排行", systemImage: "square.grid.2x2.fill")
                        .font(.headline)
                    Spacer()
                    Text("按时长排序，不重复相加")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if summary.appUsage.isEmpty {
                    Text("当前范围还没有应用数据。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let maxDuration = summary.appUsage.first?.duration ?? 1
                    VStack(spacing: 10) {
                        ForEach(summary.appUsage.prefix(12)) { app in
                            ActivityAppRowView(
                                app: app,
                                maxDuration: maxDuration,
                                isSelected: selectedApp == app.name
                            ) {
                                selectedApp = selectedApp == app.name ? nil : app.name
                            }
                        }
                    }

                    if let selected = selectedApp,
                       summary.appUsage.contains(where: { $0.name == selected }) {
                        let related = summary.liveSessions.filter {
                            ActivityClassifier.identity(appName: $0.appName, bundleID: $0.bundleID) == ActivityClassifier.identity(appName: selected)
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Divider()
                            Text("\(selected) 的时间线索")
                                .font(.caption.weight(.semibold))
                            if related.isEmpty {
                                Text("这个应用没有已结束的实时片段，或片段在退出后才会保存。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(related.prefix(5)) { session in
                                    HStack(spacing: 8) {
                                        Text(session.start.formatted(date: .omitted, time: .shortened))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        Text(session.windowTitle ?? session.category)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(ActivityFormatter.time(session.duration))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.top, 5)
                    }
                }
            }
        }
    }

    private var detailsCard: some View {
        SoftCard {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showsDetails.toggle() }
                } label: {
                    HStack {
                        Label("更多明细", systemImage: showsDetails ? "eye" : "eye.slash")
                            .font(.headline)
                        Spacer()
                        Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if showsDetails {
                    browsingCardContent
                    healthCardContent
                }
            }
        }
    }

    private var browsingCardContent: some View {
        let sites = summary.browseUsage.prefix(8)

        return VStack(alignment: .leading, spacing: 10) {
            Text("浏览足迹")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if sites.isEmpty {
                Text("这段时间没有浏览记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sites) { item in
                    HStack {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(item.site).font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(item.visits) 次 · \(item.days) 天")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 14))
    }

    private var healthCardContent: some View {
        HStack(spacing: 10) {
            ActivityMetricView(title: "步数", value: "\(summary.healthSteps)", icon: "figure.walk")
            ActivityMetricView(title: "距离", value: String(format: "%.2f km", summary.healthDistance), icon: "point.topleft.down.curvedto.point.bottomright.up")
            ActivityMetricView(title: "热量", value: String(format: "%.1f kcal", summary.healthEnergy), icon: "flame.fill")
        }
        .padding(12)
        .background(Color.chip, in: RoundedRectangle(cornerRadius: 14))
    }


}

struct ActivityMetricView: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityAppRowView: View {
    let app: UsageItem
    let maxDuration: TimeInterval
    let isSelected: Bool
    let action: () -> Void

    private var fraction: Double {
        maxDuration > 0 ? app.duration / maxDuration : 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: ActivityClassifier.symbol(for: app.name))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: ActivityClassifier.color(for: app.category)))
                    .frame(width: 24)

                Text(app.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                    .lineLimit(1)

                Spacer()

                Text(ActivityFormatter.time(app.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.strongSurface : Color.chip.opacity(0.5))
            )
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(hex: ActivityClassifier.color(for: app.category)).opacity(0.1))
                        .frame(width: geo.size.width * fraction)
                        .allowsHitTesting(false)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
