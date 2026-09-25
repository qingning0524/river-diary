import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var appearanceModeRaw: String
    @AppStorage("appearance.density") private var densityRaw = RiverDensity.standard.rawValue
    @StateObject private var paletteController = PaletteController.shared

    private let paletteColumns = [GridItem(.adaptive(minimum: 210), spacing: 10)]

    var body: some View {
        SettingsPage {
            SettingsGroup(
                title: "配色方案",
                detail: "八套主题色，浅色与深色各自调校；切换立即生效，选择会被记住。"
            ) {
                LazyVGrid(columns: paletteColumns, spacing: 10) {
                    ForEach(RiverPalette.allCases) { palette in
                        PaletteCard(
                            palette: palette,
                            isSelected: paletteController.palette == palette
                        ) {
                            paletteController.select(palette)
                        }
                    }
                }
            }

            SettingsGroup(
                title: "显示模式",
                detail: "跟随系统会使用 macOS 当前外观；选择浅色或深色只影响河流日记。"
            ) {
                RiverPanel {
                    RiverPanelRow(title: "外观", detail: "应用到整个窗口", showsDivider: false) {
                        Picker("显示模式", selection: $appearanceModeRaw) {
                            ForEach(RiverAppearance.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }

            SettingsGroup(
                title: "内容密度",
                detail: "标准模式留白更多；紧凑模式收紧间距，字号保持不变。"
            ) {
                RiverPanel {
                    RiverPanelRow(title: "密度", detail: "影响面板内边距与行高", showsDivider: false) {
                        Picker("内容密度", selection: $densityRaw) {
                            ForEach(RiverDensity.allCases) { density in
                                Text(density.title).tag(density.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                    }
                }
            }
        }
    }
}

/// One selectable palette: three overlapping swatches (画布 / 强调色 / 淡强调),
/// the name, and a checkmark when active.
private struct PaletteCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let palette: RiverPalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let set = colorScheme == .dark ? palette.theme.dark : palette.theme.light
            HStack(spacing: 10) {
                HStack(spacing: -5) {
                    swatch(Color(hex: set.canvas))
                    swatch(Color(hex: set.accent))
                    swatch(Color(hex: set.accentSoft))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(palette.title)
                        .font(AppTypography.rowTitle().weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.ink)
                    Text(palette.tagline)
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.tertiaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                isSelected ? AppTheme.accentSoft : Color.surface,
                in: RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous)
                    .strokeBorder(isSelected ? AppTheme.accent.opacity(0.55) : Color.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("配色 \(palette.title)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Color.border, lineWidth: 1))
    }
}
