import AppKit
import SwiftUI

enum AppLayout {
    static let sidebarWidth: CGFloat = 176
    static let contentMaxWidth: CGFloat = 1280
    static let outerPadding: CGFloat = 22
}

private func dynamicColor(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

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

    static let ink = dynamicColor(
        NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.94, green: 0.94, blue: 0.93, alpha: 1)
    )

    static let secondaryInk = dynamicColor(
        NSColor(srgbRed: 0.36, green: 0.34, blue: 0.31, alpha: 1),
        NSColor(srgbRed: 0.70, green: 0.69, blue: 0.68, alpha: 1)
    )

    static let surface = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.78),
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 0.78)
    )

    static let strongSurface = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.90),
        NSColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 0.92)
    )

    static let border = dynamicColor(
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.72),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    )

    static let editor = dynamicColor(
        NSColor(srgbRed: 1, green: 0.976, blue: 0.957, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    )

    static let chip = dynamicColor(
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.055),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
    )

    static let ctaBackground = dynamicColor(
        NSColor(srgbRed: 0.13, green: 0.11, blue: 0.09, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.94, blue: 0.92, alpha: 1)
    )

    static let ctaText = dynamicColor(
        NSColor(srgbRed: 1, green: 0.97, blue: 0.94, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.11, blue: 0.10, alpha: 1)
    )
}

struct VisualBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(hex: "#0F1013"),
                        Color(hex: "#151419"),
                        Color(hex: "#181E25")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [Color(hex: "#7886FF").opacity(0.13), .clear],
                    center: UnitPoint(x: 0.18, y: 0.10),
                    startRadius: 0,
                    endRadius: 580
                )

                RadialGradient(
                    colors: [Color(hex: "#FF8FB3").opacity(0.10), .clear],
                    center: UnitPoint(x: 0.88, y: 0.18),
                    startRadius: 0,
                    endRadius: 560
                )
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: "#FFF7EF"),
                        Color(hex: "#FFF2F4"),
                        Color(hex: "#F0F4F7")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                RadialGradient(
                    colors: [.white.opacity(0.9), .clear],
                    center: UnitPoint(x: 0.18, y: 0.12),
                    startRadius: 0,
                    endRadius: 560
                )

                RadialGradient(
                    colors: [Color(hex: "#FFD0DB").opacity(0.52), .clear],
                    center: UnitPoint(x: 0.9, y: 0.16),
                    startRadius: 0,
                    endRadius: 540
                )

                RadialGradient(
                    colors: [Color(hex: "#C7DEFF").opacity(0.38), .clear],
                    center: UnitPoint(x: 0.68, y: 0.62),
                    startRadius: 0,
                    endRadius: 520
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct SoftCard<Content: View>: View {
    var padding: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 34, x: 0, y: 20)
    }
}

struct ProgressBar: View {
    var value: Double
    var colors: [Color] = [Color(hex: "#7FB3FF"), Color(hex: "#FF8FB3")]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, proxy.size.width * min(max(value, 0), 100) / 100))
            }
        }
        .frame(height: 6)
    }
}

struct PrimaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.ctaText)
            .padding(.horizontal, 21)
            .padding(.vertical, 12)
            .background(Color.ctaBackground, in: Capsule())
            .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

struct SecondaryButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.surface, in: Capsule())
            .overlay(Capsule().stroke(Color.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 9)
    }
}

struct SmallActionButtonStyle: ViewModifier {
    var dark = false

    func body(content: Content) -> some View {
        content
            .font(.caption.weight(.semibold))
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
            .frame(width: 26, height: 26)
            .background(Color.chip, in: Circle())
            .overlay(Circle().stroke(Color.border, lineWidth: 1))
    }
}

extension View {
    func primaryCTA() -> some View { modifier(PrimaryButtonStyle()) }
    func secondaryCTA() -> some View { modifier(SecondaryButtonStyle()) }
    func smallAction(dark: Bool = false) -> some View { modifier(SmallActionButtonStyle(dark: dark)) }
    func iconAction() -> some View { modifier(IconActionButtonStyle()) }
}

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

enum StatusTone {
    case positive
    case neutral
    case attention
}

/// 所有卡片右上角的状态统一使用这一个组件，
/// 避免不同页面出现不同字号、圆角和内边距。
struct StatusBadge: View {
    let text: String
    var tone: StatusTone = .neutral

    init(_ text: String, tone: StatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .positive: Color(hex: "#2C8158")
        case .attention: Color(hex: "#B26B00")
        case .neutral: Color.secondaryInk
        }
    }

    private var background: Color {
        switch tone {
        case .positive: Color(hex: "#D9F2E3")
        case .attention: Color(hex: "#FFEBC7")
        case .neutral: Color.chip
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
    }
}
