import SwiftUI

struct SourcesOverviewView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ingestion: DataIngestionStore
    @ObservedObject var location: LocationSourceStore
    let entry: DiaryEntry
    var onOpenSettings: () -> Void

    var body: some View {
        RiverPage(maxWidth: 760) {
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.panelGap)) {
                PageHeader("数据源", context: "权限、覆盖和采集状态") {
                    Button("打开设置", action: onOpenSettings)
                        .buttonStyle(.plain)
                        .smallAction()
                }
                .riverAppear(index: 0)

                SourceHealthPanel(
                    items: SourceHealthBuilder.make(
                        pipelineEnabled: ingestion.enabled,
                        pipelineRunning: ingestion.isRunning,
                        pipelineError: ingestion.lastError,
                        lastIngestedAt: ingestion.lastIngestedAt,
                        lastStatus: ingestion.lastStatus,
                        liveTracking: activity.isTracking,
                        liveSessionCount: activity.sessions.count,
                        healthAvailable: entry.health != nil,
                        locationState: location.statusState,
                        locationDetail: location.statusDetail
                    ),
                    onOpenSettings: onOpenSettings
                )
                .riverAppear(index: 1)

                RiverPanel(title: "当前策略", systemImage: "checkmark.shield", accent: AppTheme.neutral) {
                    SettingsFootnote(text: "缺失数据会显示为未知，不会按零参与判断；AI 解释不可用时，原始事实仍然保留。")
                }
                .riverAppear(index: 2)
            }
        }
    }
}
