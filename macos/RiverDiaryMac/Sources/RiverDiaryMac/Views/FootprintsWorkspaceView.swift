import SwiftUI

struct FootprintsWorkspaceView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var activity: ActivityStore
    let entries: [DiaryEntry]
    let selectedDate: Date
    @FocusState.Binding var inspectorSourceFocusID: String?
    var onSelectTimelineItem: (ActivityTimelineItem, String) -> Void
    var onOpenTimeline: () -> Void
    var onConnectLocation: () -> Void
    @ObservedObject var location: LocationSourceStore
    var onOpenSources: () -> Void

    private var timeline: ActivityTimeline {
        ActivityTimelineEngine.build(for: selectedDate, sessions: activity.liveSessions(for: selectedDate))
    }

    var body: some View {
        RiverPage {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                PageHeader("足迹", context: selectedDate.formatted(.dateTime.year().month().day())) {
                    HStack(spacing: 6) {
                        Button(location.isConnected ? "停止位置记录" : "连接位置") {
                            if location.isConnected { location.disconnect() }
                            else { onConnectLocation() }
                        }
                            .buttonStyle(.plain)
                            .smallAction(dark: true)
                        Button("连接数据源", action: onOpenSources)
                            .buttonStyle(.plain)
                            .smallAction()
                    }
                }
                .riverAppear(index: 0)

                RiverPanel(title: "空间状态", systemImage: "mappin.and.ellipse", accent: AppTheme.warning, tint: AppTheme.warning) {
                    HStack(alignment: .top, spacing: density.spacing(10)) {
                        RiverIconWell(systemImage: "mappin.and.ellipse", tint: AppTheme.warning, size: 26)
                        VStack(alignment: .leading, spacing: density.spacing(3)) {
                            Text(placeStatus)
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            if let latest = location.latestPlaceName, !latest.isEmpty {
                                Text("最近位置：\(latest)")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(AppTheme.accent)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .riverAppear(index: 1)

                RiverPanel(title: "地点记录", systemImage: "mappin.circle", accent: AppTheme.neutral) {
                    if placeItems.isEmpty {
                        EmptyStateView(
                            title: "还没有地点记录",
                            message: "连接地点来源后，这里会显示去过哪里、停留多久。也可以先从时间线打开一段记录，手动标注地点和活动。",
                            symbol: "mappin.and.ellipse",
                            actionTitle: "打开时间线",
                            action: onOpenTimeline,
                            secondaryTitle: "连接数据源",
                            secondaryAction: onOpenSources
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(placeItems) { item in
                                let focusID = "footprints:\(item.id)"
                                Button {
                                    inspectorSourceFocusID = focusID
                                    onSelectTimelineItem(item, focusID)
                                } label: {
                                    HStack(alignment: .top, spacing: density.spacing(10)) {
                                        Text(item.start.formatted(date: .omitted, time: .shortened))
                                            .font(AppTypography.mono())
                                            .foregroundStyle(Color.secondaryInk)
                                            .frame(width: 58, alignment: .leading)
                                        VStack(alignment: .leading, spacing: density.spacing(3)) {
                                            Text(item.annotation?.normalized.placeName ?? "未知地点")
                                                .font(AppTypography.rowTitle())
                                                .foregroundStyle(Color.ink)
                                            Text(item.annotation?.normalized.activityLabel ?? "未标注活动")
                                                .font(AppTypography.secondary())
                                                .foregroundStyle(Color.secondaryInk)
                                            Text("\(item.start.formatted(date: .omitted, time: .shortened))–\(item.end.formatted(date: .omitted, time: .shortened)) · \(ActivityFormatter.time(item.duration))")
                                                .font(AppTypography.metadata())
                                                .foregroundStyle(AppTheme.accent)
                                        }
                                        Spacer(minLength: density.spacing(AppSpacing.sm))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color.tertiaryInk)
                                    }
                                    .padding(.vertical, density.spacing(9))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focused($inspectorSourceFocusID, equals: focusID)
                                .overlay(alignment: .bottom) { RiverRowDivider(inset: 0) }
                            }
                        }
                    }
                }
                .riverAppear(index: 2)
            }
        }
    }

    private var placeStatus: String {
        let corrected = placeItems.count
        if corrected > 0 {
            return "\(location.statusDetail) · 已有 \(corrected) 段足迹由你人工标注地点。"
        }
        return "\(location.statusDetail)。电脑活动统一在时间线展示，足迹页只展示地点和停留。"
    }

    private var placeItems: [ActivityTimelineItem] {
        timeline.items.filter { item in
            guard let place = item.annotation?.normalized.placeName else { return false }
            return !place.isEmpty
        }
    }
}
