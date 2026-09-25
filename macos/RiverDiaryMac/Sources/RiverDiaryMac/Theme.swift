import AppKit
import SwiftUI

func dynamicColor(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

// MARK: - 色彩
// 柔和景深 palette, runtime-switchable. Tokens are cached dynamic NSColors:
// each draw resolves the current palette from `PaletteStore`, so switching
// 配色 in Settings repaints every view without rebuilding the tree. Status
// colours (正常/警示/错误) stay universal across palettes.

extension NSColor {
    convenience init(hex: String) {
        let value = hex.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// A palette-resolved colour. The wrapper is cached; the hex is looked up at
/// draw time from the current palette (parsed once per palette, then cached).
func paletteColor(_ keyPath: KeyPath<RiverPaletteColorSet, String>) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        PaletteStore.resolvedColor(keyPath, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    })
}

/// Hairlines: per-palette hex in light mode; quiet white alpha in dark mode
/// so any dark canvas keeps the same breathable outline.
func paletteRuleColor(_ keyPath: KeyPath<RiverPaletteColorSet, String>, darkAlpha: CGFloat) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            return NSColor(white: 1, alpha: darkAlpha)
        }
        return PaletteStore.resolvedColor(keyPath, dark: false)
    })
}

/// 发丝线在深色下的白透明度配方。
///
/// 原值 0.07 / 0.045 是"几乎看不见"的：白 4.5% 压在深色面板上只有 1.009:1，
/// 行分隔线在深色下等于没有，深色界面因此格外平。深色的分层靠线条而不是面，
/// 所以这两个值比浅色更需要"画得出来"。由 `PaletteDepthTests` 守卫。
let darkBorderAlpha: CGFloat = 0.10
let darkSeparatorAlpha: CGFloat = 0.08

extension Color {
    init(hex: String) {
        let value = hex.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    // MARK: Text
    static let ink = paletteColor(\.ink)
    static let secondaryInk = paletteColor(\.ink2)
    /// Quietest text step: inline hints and unrecorded values. Never essential state.
    static let tertiaryInk = paletteColor(\.ink3)

    // MARK: Surfaces
    static let workspace = paletteColor(\.canvas)
    static let sidebarSurface = paletteColor(\.sidebar)
    /// The surface of every panel on a page.
    static let surface = paletteColor(\.surface)
    /// Surfaces that sit on top of a panel, or float above the window.
    static let strongSurface = paletteColor(\.strongSurface)
    /// Wells: text editors and inputs that read as recessed.
    static let editor = paletteColor(\.editor)
    /// 设置窗口左栏的底色。
    ///
    /// 主题里 `sidebar` 与 `canvas` 只差几个色阶（浅色下 #F7FAFD vs #EAEDF2），
    /// 直接铺 `sidebarSurface` 会让左栏和内容糊成一片。这里把 `ink` 按固定比例压进
    /// sidebar，得到"比内容明确低一档"的左栏底——配方固定，八套配色 × 明暗都自适应，
    /// 不需要为每套配色手写一个新的十六进制值。
    static let settingsRailSurface = Color(nsColor: railSurfaceNSColor)
    static let chip = paletteColor(\.chip)

    // MARK: Rules
    /// Panel outline. A hairline, never a heavy border.
    static let border = paletteRuleColor(\.border, darkAlpha: darkBorderAlpha)
    /// Row divider inside a panel.
    static let separator = paletteRuleColor(\.separator, darkAlpha: darkSeparatorAlpha)
    /// Stronger section rule, used only between page-level groups.
    static let strongSeparator = paletteColor(\.strongSeparator)

    // MARK: Timeline spine
    //
    // 时间线的脊柱：一天里"有记录"的那根线。原来的 `accent@0.30` 只有 1.48:1
    //（浅色）/ 1.75:1（深色），设计文档写了"连续脊柱"而像素里看不见；空档段用
    // separator（1.10:1）更是完全断掉。现在浅色 0.72、深色 0.60，最低一套配色
    //（blossom 浅色）也有 2.2:1：脊柱读得出来，且仍然明显轻于实心节点。
    static let timelineSpine = Color(nsColor: timelineSpineNSColor)

    // MARK: Action
    static let ctaBackground = paletteColor(\.accent)
    static let ctaText = dynamicColor(NSColor(hex: "#FFFFFF"), NSColor(hex: "#FFFFFF"))

    /// The quiet two-stop gradient behind the primary action and brand mark.
    /// Each stop resolves light/dark from the current palette.
    static let ctaGradient = LinearGradient(
        colors: [paletteColor(\.gradientStart), paletteColor(\.gradientEnd)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: River accent
    static let riverBlue = paletteColor(\.accent)
    static let riverBlueSoft = paletteColor(\.accentSoft)
}

// MARK: - 字体

extension Font {
    /// Display text uses the same readable system face as the rest of the interface.
    static func editorial(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Body text follows the native system font for consistent reading and accessibility.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

// MARK: - 语义色与应用主题
//
// The only place a status colour is defined. `soft` variants are the matching
// tinted background for badges and icon wells.

enum AppTheme {
    /// One blue accent for evidence, selection, and the primary action.
    static let accent = Color.riverBlue
    static let accentSoft = Color.riverBlueSoft

    static let recording = dynamicColor(NSColor(hex: "#D2552C"), NSColor(hex: "#FF9A6E"))
    static let ok = dynamicColor(NSColor(hex: "#27A068"), NSColor(hex: "#5FD39C"))
    static let okSoft = dynamicColor(NSColor(hex: "#E1F5EB"), NSColor(hex: "#12291C"))
    static let warning = dynamicColor(NSColor(hex: "#C07A10"), NSColor(hex: "#F0B45C"))
    static let warningSoft = dynamicColor(NSColor(hex: "#FBF0DA"), NSColor(hex: "#332611"))
    static let error = dynamicColor(NSColor(hex: "#C94A38"), NSColor(hex: "#FF8A7A"))
    static let errorSoft = dynamicColor(NSColor(hex: "#FBE7E3"), NSColor(hex: "#3A1C18"))

    /// Neutral highlight with no judgement attached to it.
    static let neutral = Color.secondaryInk
    static let neutralSoft = Color.chip

    /// Layers.
    static func surface(_ level: AppSurfaceLevel) -> Color {
        switch level {
        case .page: Color.workspace
        case .panel: Color.surface
        case .raised: Color.chip
        case .overlay: Color.strongSurface
        }
    }

    /// Colour for an activity category on the timeline and the day ribbon.
    ///
    /// The product deliberately does **not** use one colour per category — that
    /// would turn the evidence report into a colour-coded productivity chart.
    /// Everything recorded shares the single accent; only system noise and
    /// unrecorded time step down to the neutral tone.
    static func categoryTint(_ category: String) -> Color {
        ["系统", "未记录"].contains(category) ? Color.tertiaryInk : accent
    }

    /// Fill for an icon well / status chip of the given tone.
    static func softFill(for tone: StatusTone) -> Color {
        switch tone {
        case .positive: okSoft
        case .attention: warningSoft
        case .critical: errorSoft
        case .neutral: neutralSoft
        }
    }

    /// Foreground for the same tone.
    static func foreground(for tone: StatusTone) -> Color {
        switch tone {
        case .positive: ok
        case .attention: warning
        case .critical: error
        case .neutral: neutral
        }
    }
}

// MARK: - 按钮
// Three visual weights only: Primary (the one main action of a surface),
// Secondary (bordered), and Small (compact inline action).

struct PrimaryButtonStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            // Kill the system button bezel — the CTA chrome below is the whole look.
            .buttonStyle(PressableButtonStyle())
            .font(AppTypography.label().weight(.semibold))
            .foregroundStyle(Color.ctaText)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 6)
            .background(
                Color.ctaGradient,
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.14),
                radius: 8,
                y: 3
            )
    }
}

struct SecondaryButtonStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(PressableButtonStyle())
            .font(AppTypography.label())
            .foregroundStyle(Color.ink)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, 6)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Compact inline action used inside panels and panel headers.
struct SmallActionButtonStyle: ViewModifier {
    var dark = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(PressableButtonStyle())
            .font(AppTypography.metadata().weight(dark ? .semibold : .regular))
            .foregroundStyle(dark ? Color.ctaText : Color.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                dark ? AnyShapeStyle(Color.ctaBackground) : AnyShapeStyle(Color.chip),
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .strokeBorder(dark ? .clear : Color.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Square icon button: panel headers, inspector chrome, toolbars.
struct IconActionButtonStyle: ViewModifier {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(PressableButtonStyle())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isProminent ? Color.ctaText : Color.secondaryInk)
            .frame(width: 26, height: 26)
            .background(
                isProminent ? AnyShapeStyle(Color.ctaBackground) : AnyShapeStyle(Color.chip),
                in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                    .strokeBorder(isProminent ? .clear : Color.border, lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// Text-only accent action (收起/展开、行内跳转)。macOS 的 `.link` 样式跟随系统
/// 链接色而不是应用配色，所以设计系统自己定义这一个。
struct LinkActionButtonStyle: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .buttonStyle(PressableButtonStyle())
            .font(AppTypography.secondary())
            .foregroundStyle(AppTheme.accent)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    func primaryCTA() -> some View { modifier(PrimaryButtonStyle()) }
    func secondaryCTA() -> some View { modifier(SecondaryButtonStyle()) }
    func smallAction(dark: Bool = false) -> some View { modifier(SmallActionButtonStyle(dark: dark)) }
    func iconAction(prominent: Bool = false) -> some View { modifier(IconActionButtonStyle(isProminent: prominent)) }
    func linkAction() -> some View { modifier(LinkActionButtonStyle()) }
}

/// 克制 的按反馈：按下时轻微变暗，不跳动。
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var softPress: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - 品牌印记
// A small, quiet mark: the blue-teal gradient, no glow.

struct BrandMark: View {
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: "leaf.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: size, height: size)
            .background(
                Color.ctaGradient,
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - 等宽行

/// 让同一行的卡片获得相同宽度和相同高度，
/// 避免右侧因为文案更短而提前收住。
struct EqualWidthRow: Layout {
    var spacing: CGFloat = AppSpacing.md

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let count = max(1, subviews.count)
        let width = proposal.width ?? AppLayout.contentMaxWidth
        let availableWidth = max(0, width - spacing * CGFloat(count - 1))
        let cellWidth = availableWidth / CGFloat(count)
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: proposal.height)).height
        }.max() ?? 0

        return CGSize(width: width, height: proposal.height ?? height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = max(1, subviews.count)
        let availableWidth = max(0, bounds.width - spacing * CGFloat(count - 1))
        let cellWidth = availableWidth / CGFloat(count)
        let rowHeight = proposal.height ?? subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: cellWidth, height: proposal.height)).height
        }.max() ?? bounds.height

        for (index, view) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (cellWidth + spacing)
            view.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellWidth, height: rowHeight)
            )
        }
    }
}

// MARK: - 状态徽章

enum StatusTone: Hashable {
    case positive
    case neutral
    case attention
    case critical
}

/// 所有卡片右上角的状态统一使用这一个组件。
struct StatusBadge: View {
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.riverHighContrast) private var highContrast

    let text: String
    var tone: StatusTone

    init(_ text: String, tone: StatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var symbol: String {
        switch tone {
        case .positive: "checkmark.circle"
        case .attention: "exclamationmark.triangle"
        case .critical: "xmark.octagon"
        case .neutral: "minus.circle"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            let foreground = highContrast ? Color.ink : AppTheme.foreground(for: tone)
            if differentiateWithoutColor {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(foreground)
            } else {
                Circle()
                    .fill(foreground)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(AppTypography.micro().weight(.medium))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(AppTheme.softFill(for: tone), in: Capsule())
        .overlay(
            Capsule().strokeBorder(highContrast ? Color.ink.opacity(0.55) : .clear, lineWidth: 1)
        )
    }
}


// MARK: - 左栏底色

/// `ink` 压进 `sidebar` 的比例。数值越大左栏越重。
///
/// 这个常量由 `SettingsChromeTests` 和 `SettingsRailContrastTests` 守卫：
/// 太小则左栏与内容分不出来，太大则左栏像一块压下来的重色。
///
/// 2026-09-26：0.07 → 0.13。画布从 `#F0F3F8` 压到 `#EAEDF2`（拉开面板与页面的
/// 台阶）之后，原来那档左栏正好落在画布上（只差 1–2 个色阶），两栏糊成一片。
let settingsRailBlendAmount: CGFloat = 0.13

/// 时间线脊柱的不透明度配方（accent 压进当前面板底色）。由 `PaletteDepthTests` 守卫：
/// 浅色最低一套配色 2.2:1，深色约 3.2:1 起。
let timelineSpineAlphaLight: CGFloat = 0.72
let timelineSpineAlphaDark: CGFloat = 0.60

/// 时间线脊柱色：随外观解析（和 `paletteColor` 同样的动态机制）。
var timelineSpineNSColor: NSColor {
    NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let accent = PaletteStore.resolvedColor(\.accent, dark: dark)
        let surface = PaletteStore.resolvedColor(\.surface, dark: dark)
        return blendHex(accent, overHex: surface, fraction: dark ? timelineSpineAlphaDark : timelineSpineAlphaLight)
            ?? accent
    }
}

/// 设置窗口左栏的底色，随外观解析（和 `paletteColor` 同样的动态机制）。
var railSurfaceNSColor: NSColor {
    NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let sidebar = PaletteStore.resolvedColor(\.sidebar, dark: dark)
        let ink = PaletteStore.resolvedColor(\.ink, dark: dark)
        return blendHex(ink, overHex: sidebar, fraction: settingsRailBlendAmount) ?? sidebar
    }
}

/// 把 `top` 以 `fraction` 的比例压到 `base` 上。两者都是不带 alpha 的十六进制色。
func blendHex(_ top: NSColor, overHex base: NSColor, fraction: CGFloat) -> NSColor? {
    guard let f = top.usingColorSpace(.sRGB),
          let b = base.usingColorSpace(.sRGB) else { return nil }
    let f0 = max(0, min(1, fraction))
    func channel(_ k: KeyPath<NSColor, CGFloat>) -> CGFloat {
        f[keyPath: k] * f0 + b[keyPath: k] * (1 - f0)
    }
    return NSColor(
        srgbRed: channel(\.redComponent),
        green: channel(\.greenComponent),
        blue: channel(\.blueComponent),
        alpha: 1
    )
}
