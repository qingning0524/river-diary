import RiverDiaryCore
import SwiftUI

struct AppearanceSettingsView: View {
    @Binding var appearanceModeRaw: String
    @AppStorage("appearance.density") private var densityRaw = RiverDensity.standard.rawValue
    @StateObject private var paletteController = PaletteController.shared
    @Environment(\.riverDensity) private var density

    private var paletteColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 210), spacing: density.spacing(10))]
    }

    var body: some View {
        SettingsPage {
            SettingsGroup(
                title: "配色方案",
                detail: "八套主题色，浅色与深色各自调校；切换立即生效，选择会被记住。"
            ) {
                LazyVGrid(columns: paletteColumns, spacing: density.spacing(10)) {
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
                        RiverSegmentedPicker(
                            title: "显示模式",
                            selection: $appearanceModeRaw,
                            options: RiverAppearance.allCases.map(\.rawValue),
                            label: { RiverAppearance(rawValue: $0)?.title ?? $0 }
                        )
                    }
                }
            }

            SettingsGroup(
                title: "内容密度",
                detail: "标准模式留白更多；紧凑模式收紧间距，字号保持不变。"
            ) {
                RiverPanel {
                    RiverPanelRow(title: "密度", detail: "影响面板内边距与行高", showsDivider: false) {
                        RiverSegmentedPicker(
                            title: "内容密度",
                            selection: $densityRaw,
                            options: RiverDensity.allCases.map(\.rawValue),
                            label: { RiverDensity(rawValue: $0)?.title ?? $0 }
                        )
                    }
                }
            }

            SettingsGroup(
                title: "关于",
                detail: "版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") · 隐私、条款与服务状态都在官网，不把法律文本塞进应用包。"
            ) {
                RiverPanel {
                    Link(destination: RiverLegalLinks.privacyPolicy) {
                        RiverPanelRow(title: "隐私政策", detail: "账号、云空间与本机数据的边界", systemImage: "hand.raised")
                    }.buttonStyle(.plain)
                    Link(destination: RiverLegalLinks.terms) {
                        RiverPanelRow(title: "服务条款", detail: "账号、云空间与可接受使用", systemImage: "doc.text")
                    }.buttonStyle(.plain)
                    Link(destination: RiverLegalLinks.serviceStatus) {
                        RiverPanelRow(title: "服务状态", detail: "账号 API 与下载分发是否响应", systemImage: "waveform.path.ecg", showsDivider: false)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// One selectable palette: three overlapping swatches (画布 / 强调色 / 淡强调),
/// the name, and a checkmark when active.
private struct PaletteCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.riverDensity) private var density
    let palette: RiverPalette
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let set = colorScheme == .dark ? palette.theme.dark : palette.theme.light
            HStack(spacing: density.spacing(10)) {
                HStack(spacing: -5) {
                    swatch(Color(hex: set.canvas))
                    swatch(Color(hex: set.accent))
                    swatch(Color(hex: set.accentSoft))
                }
                VStack(alignment: .leading, spacing: density.spacing(1)) {
                    Text(palette.title)
                        .font(AppTypography.rowTitle().weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.ink)
                    Text(palette.tagline)
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.tertiaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: density.spacing(AppSpacing.xs))
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(.horizontal, density.spacing(AppSpacing.md))
            .padding(.vertical, density.spacing(9))
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
