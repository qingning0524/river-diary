import SwiftUI

struct SettingsRedesignView: View {
    @Environment(\.riverDensity) private var density
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var settingsSection: SettingsCategory = .recording
    @AppStorage("appearance.mode") private var appearanceModeRaw = RiverAppearance.system.rawValue

    var body: some View {
        VStack(spacing: 0) {
            RiverHeaderBand(maxWidth: .infinity, spacing: AppSpacing.sm, showsRule: true) {
                PageHeader("设置", context: settingsSection.detail)
            }

            HStack(alignment: .top, spacing: 0) {
                settingsRail
                    .frame(width: AppLayout.settingsRailWidth)
                    .riverAppear(index: 0)
                RiverRule()
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                settingsContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .riverAppear(index: 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.workspace)
    }

    private var settingsRail: some View {
        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
            ForEach(SettingsCategory.allCases) { item in
                settingsRailRow(item)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, density.spacing(10))
        .padding(.top, density.spacing(AppSpacing.lg))
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.sidebarSurface)
    }

    private func settingsRailRow(_ item: SettingsCategory) -> some View {
        let isSelected = settingsSection == item
        return Button {
            settingsSection = item
        } label: {
            HStack(spacing: density.spacing(9)) {
                Image(systemName: item.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? AppTheme.accent : Color.secondaryInk)
                    .frame(width: 16)
                Text(item.rawValue)
                    .font(AppTypography.rowTitle().weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.ink : Color.secondaryInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, density.spacing(10))
            .frame(height: density.spacing(30))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AppTheme.accentSoft : Color.clear,
                in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch settingsSection {
        case .ai:
            AISettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        case .privacy:
            PrivacyBackupSettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        case .appearance:
            AppearanceSettingsView(appearanceModeRaw: $appearanceModeRaw)
        case .recording:
            RecordingSettingsView(store: store, activity: activity, ai: ai, ingestion: ingestion)
        }
    }
}
