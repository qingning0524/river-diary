import SwiftUI

enum SourceHealthState: Hashable {
    case healthy
    case collecting
    case missing
    case paused
    case error

    var label: String {
        switch self {
        case .healthy: "正常"
        case .collecting: "采集中"
        case .missing: "未知"
        case .paused: "已暂停"
        case .error: "有问题"
        }
    }

    var color: Color {
        switch self {
        case .healthy: AppTheme.ok
        case .collecting: AppTheme.accent
        case .missing: Color.tertiaryInk
        case .paused: Color.tertiaryInk
        case .error: AppTheme.warning
        }
    }

    var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .collecting: "arrow.triangle.2.circlepath"
        case .missing: "questionmark.circle"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct SourceHealthItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let state: SourceHealthState
}

enum SourceHealthBuilder {
    static func make(
        pipelineEnabled: Bool,
        pipelineRunning: Bool,
        pipelineError: String?,
        lastIngestedAt: Date?,
        lastStatus: String,
        liveTracking: Bool,
        liveSessionCount: Int,
        healthAvailable: Bool,
        locationAvailable: Bool = false,
        locationState: SourceHealthState? = nil,
        locationDetail: String? = nil
    ) -> [SourceHealthItem] {
        let pipelineState: SourceHealthState
        let pipelineDetail: String
        if let pipelineError, !pipelineError.isEmpty {
            pipelineState = .error
            pipelineDetail = pipelineError
        } else if pipelineRunning {
            pipelineState = .collecting
            pipelineDetail = lastStatus
        } else if pipelineEnabled {
            pipelineState = lastIngestedAt == nil ? .missing : .healthy
            pipelineDetail = lastIngestedAt.map { "最近采集 \($0.formatted(.relative(presentation: .named)))" } ?? "尚未完成一次采集"
        } else {
            pipelineState = .paused
            pipelineDetail = "自动采集已暂停"
        }

        return [
            SourceHealthItem(id: "project-pipeline", title: "项目数据管道", detail: pipelineDetail, state: pipelineState),
            SourceHealthItem(
                id: "mac-live",
                title: "macOS 实时足迹",
                detail: liveTracking ? "已保存 \(liveSessionCount) 段实时片段" : "记录已暂停",
                state: liveTracking ? .collecting : .paused
            ),
            SourceHealthItem(
                id: "health",
                title: "健康快照",
                detail: healthAvailable ? "睡眠、步数或运动数据可用" : "今天没有健康数据",
                state: healthAvailable ? .healthy : .missing
            ),
            SourceHealthItem(
                id: "location",
                title: "地点足迹",
                detail: locationDetail ?? (locationAvailable ? "地点来源可用" : "地点来源尚未连接"),
                state: locationState ?? (locationAvailable ? .healthy : .missing)
            )
        ]
    }
}

struct SourceHealthPanel: View {
    @Environment(\.riverDensity) private var density
    let items: [SourceHealthItem]
    var onOpenSettings: (() -> Void)?

    var body: some View {
        RiverPanel(title: "数据来源", systemImage: "antenna.radiowaves.left.and.right", accent: AppTheme.accent) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: density.spacing(AppSpacing.sm)) {
                        Image(systemName: item.state.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(item.state.color)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: density.spacing(2)) {
                            Text(item.title)
                                .font(AppTypography.rowTitle())
                                .foregroundStyle(Color.ink)
                            Text(item.detail)
                                .font(AppTypography.metadata())
                                .foregroundStyle(Color.secondaryInk)
                                .lineLimit(1)
                        }
                        Spacer(minLength: density.spacing(AppSpacing.sm))
                        Text(item.state.label)
                            .font(AppTypography.metadata().weight(.medium))
                            .foregroundStyle(item.state.color)
                    }
                    .padding(.vertical, density.spacing(7))
                    .overlay(alignment: .bottom) {
                        if index < items.count - 1 { RiverRowDivider(inset: 0) }
                    }
                }
                if let onOpenSettings {
                    HStack {
                        Spacer()
                        Button("管理数据源", action: onOpenSettings)
                            .buttonStyle(.plain)
                            .smallAction()
                    }
                    .padding(.top, density.spacing(AppSpacing.sm))
                }
            }
        }
    }
}

