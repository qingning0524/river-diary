import AppKit
import SwiftUI

// MARK: - 布局与圆角

enum AppLayout {
    static let sidebarWidth: CGFloat = 206
    static let contentMaxWidth: CGFloat = 1180
    static let outerPadding: CGFloat = 20
}

enum AppRadius {
    static let control: CGFloat = 11
    static let inner: CGFloat = 16
    static let card: CGFloat = 16
    static let cardSmall: CGFloat = 13
}

private func dynamicColor(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

// MARK: - 色彩

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

    // 文字
    static let ink = dynamicColor(
        NSColor(srgbRed: 0.13, green: 0.115, blue: 0.102, alpha: 1),
        NSColor(srgbRed: 0.94, green: 0.93, blue: 0.91, alpha: 1)
    )

    static let secondaryInk = dynamicColor(
        NSColor(srgbRed: 0.42, green: 0.39, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.66, green: 0.65, blue: 0.62, alpha: 1)
    )

    // 表面
    static let surface = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72),
        NSColor(srgbRed: 0.13, green: 0.135, blue: 0.155, alpha: 0.72)
    )

    static let strongSurface = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88),
        NSColor(srgbRed: 0.165, green: 0.17, blue: 0.19, alpha: 0.92)
    )

    static let border = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.80),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )

    static let editor = dynamicColor(
        NSColor(srgbRed: 1, green: 0.976, blue: 0.957, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.075, blue: 0.085, alpha: 1)
    )

    static let chip = dynamicColor(
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.05),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
    )

    // 主行动（保留兼容）
    static let ctaBackground = dynamicColor(
        NSColor(srgbRed: 0.12, green: 0.10, blue: 0.085, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.93, blue: 0.90, alpha: 1)
    )

    static let ctaText = dynamicColor(
        NSColor(srgbRed: 1, green: 0.975, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.105, blue: 0.09, alpha: 1)
    )

    // 河流主题色
    static let riverBlue = dynamicColor(
        NSColor(srgbRed: 0.36, green: 0.48, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.50, green: 0.63, blue: 1.00, alpha: 1)
    )

    static let riverAmethyst = dynamicColor(
        NSColor(srgbRed: 0.48, green: 0.42, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.64, green: 0.57, blue: 1.00, alpha: 1)
    )

    static let riverPink = dynamicColor(
        NSColor(srgbRed: 0.94, green: 0.46, blue: 0.62, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.63, blue: 0.74, alpha: 1)
    )

    /// 安静的河流渐变色（蓝 → 紫罗兰 → 暮色粉）
    static var riverGradientColors: [Color] {
        [Color.riverBlue, Color.riverAmethyst, Color.riverPink]
    }
}

extension LinearGradient {
    static func river(startPoint: UnitPoint = .leading, endPoint: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(
            colors: Color.riverGradientColors,
            startPoint: startPoint,
            endPoint: endPoint
        )
    }
}


// MARK: - 字体

extension Font {
    /// 编辑体：页面大标题与关键数字，有一点「信纸」的安静感。
    static func editorial(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// 界面体：圆润、轻盈，让长内容的阅读不那么累。
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - 背景

struct VisualBackground: View {
    var body: some View { Color.workspace.ignoresSafeArea() }
}

extension Color {
    static let workspace = dynamicColor(
        NSColor(srgbRed: 0.975, green: 0.970, blue: 0.957, alpha: 1),
        NSColor(srgbRed: 0.075, green: 0.080, blue: 0.092, alpha: 1)
    )
    static let sidebarSurface = dynamicColor(
        NSColor(srgbRed: 0.946, green: 0.940, blue: 0.928, alpha: 1),
        NSColor(srgbRed: 0.095, green: 0.10, blue: 0.116, alpha: 1)
    )
    static let separator = dynamicColor(
        NSColor(srgbRed: 0.20, green: 0.18, blue: 0.16, alpha: 0.09),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
    )
}

// MARK: - 卡片

struct SoftCard<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppRadius.card, style: .continuous)
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.strongSurface, in: shape)
            .overlay(shape.strokeBorder(Color.separator, lineWidth: 1))
    }
}

// MARK: - 进度条

struct ProgressBar: View {
    var value: Double
    var colors: [Color] = Color.riverGradientColors

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, proxy.size.width * min(max(value, 0), 100) / 100))
                    .shadow(color: colors.first?.opacity(0.35) ?? .clear, radius: 4, y: 2)
            }
        }
        .frame(height: 7)
    }
}

// MARK: - 按钮

struct PrimaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.ui(14, weight: .semibold))
            .foregroundStyle(Color.ctaText)
            .padding(.horizontal, 21)
            .padding(.vertical, 12)
            .background(Color.ctaBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 9, y: 5)
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

struct SecondaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.ui(14, weight: .semibold))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.045), radius: 8, y: 4)
    }
}

struct SmallActionButtonStyle: ViewModifier {
    var dark = false

    func body(content: Content) -> some View {
        content
            .font(.ui(12, weight: .semibold))
            .foregroundStyle(dark ? Color.ctaText : Color.secondaryInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(dark ? Color.ctaBackground : Color.chip, in: Capsule())
            .overlay(Capsule().stroke(Color.border.opacity(dark ? 0 : 1), lineWidth: 1))
    }
}

struct IconActionButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.secondaryInk)
            .frame(width: 28, height: 28)
            .background(Color.surface, in: Circle())
            .overlay(Circle().stroke(Color.border, lineWidth: 1))
    }
}

extension View {
    func primaryCTA() -> some View { modifier(PrimaryButtonStyle()) }
    func secondaryCTA() -> some View { modifier(SecondaryButtonStyle()) }
    func smallAction(dark: Bool = false) -> some View { modifier(SmallActionButtonStyle(dark: dark)) }
    func iconAction() -> some View { modifier(IconActionButtonStyle()) }
}

/// 轻按反馈：按下时微微下沉，放松时回弹。
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.97
    var dim: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? dim : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var softPress: PressableButtonStyle { PressableButtonStyle() }
}

// MARK: - 品牌印记

/// 侧栏左上角的小圆章：河流渐变 + 一片叶子。
struct BrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient.river(startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Color.riverAmethyst.opacity(0.35), radius: 8, y: 4)

            Circle()
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)

            Image(systemName: "leaf.fill")
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: -0.5)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - 等宽行

/// 让同一行的卡片获得相同宽度和相同高度，
/// 避免右侧因为文案更短而提前收住。
struct EqualWidthRow: Layout {
    var spacing: CGFloat = 14

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let count = max(1, subviews.count)
        let width = proposal.width ?? 1030
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

enum StatusTone {
    case positive
    case neutral
    case attention
}

/// 所有卡片右上角的状态统一使用这一个组件。
struct StatusBadge: View {
    let text: String
    var tone: StatusTone = .neutral

    init(_ text: String, tone: StatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .positive: Color(hex: "#25704A")
        case .attention: Color(hex: "#9A5B00")
        case .neutral: Color.secondaryInk
        }
    }

    private var background: Color {
        switch tone {
        case .positive: Color(hex: "#DCEDE0")
        case .attention: Color(hex: "#FBE9C9")
        case .neutral: Color.chip
        }
    }

    private var dot: Color {
        switch tone {
        case .positive: Color(hex: "#2C8158")
        case .attention: Color(hex: "#C07A00")
        case .neutral: Color.secondaryInk.opacity(0.65)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 5, height: 5)
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }
}
