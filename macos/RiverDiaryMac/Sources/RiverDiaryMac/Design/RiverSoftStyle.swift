import SwiftUI

/// The approved desktop prototype's raised and recessed material vocabulary.
struct RiverSoftSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.riverHighContrast) private var highContrast
    var radius: CGFloat = 24
    var compact = false
    var floating = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.background {
            shape.fill(Color.surface)
                .shadow(color: Color(hex: dark ? "#17212D" : "#D3DDE9").opacity(dark ? 0.9 : 0.9),
                        radius: floating ? 24 : compact ? 5 : 12,
                        x: compact ? 3 : 7, y: compact ? 3 : 7)
                .shadow(color: Color(hex: dark ? "#354355" : "#FFFFFF").opacity(dark ? 0.45 : 0.95),
                        radius: compact ? 5 : 12, x: compact ? -3 : -7, y: compact ? -3 : -7)
                .overlay(shape.strokeBorder(highContrast ? Color.border : Color.white.opacity(dark ? 0.065 : 0.72), lineWidth: 1))
        }
    }
}

struct RiverSoftInset: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = 13
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.editor
                    .shadow(.inner(color: .black.opacity(scheme == .dark ? 0.2 : 0.065), radius: 5, x: 3, y: 3))
                    .shadow(.inner(color: .white.opacity(scheme == .dark ? 0.025 : 0.8), radius: 5, x: -3, y: -3)))
        }
    }
}

extension View {
    func riverSoftSurface(radius: CGFloat = 24, compact: Bool = false, floating: Bool = false) -> some View {
        modifier(RiverSoftSurface(radius: radius, compact: compact, floating: floating))
    }
    func riverSoftInset(radius: CGFloat = 13) -> some View {
        modifier(RiverSoftInset(radius: radius))
    }
}

struct RiverSignatureMark: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for offset in [0.0, 0.24] {
            path.move(to: CGPoint(x: rect.width * (0.66 + offset), y: rect.height * 0.05))
            path.addCurve(to: CGPoint(x: rect.width * (0.08 + offset), y: rect.height * 0.95),
                          control1: CGPoint(x: rect.width * (-0.02 + offset), y: rect.height * 0.3),
                          control2: CGPoint(x: rect.width * (0.95 + offset), y: rect.height * 0.65))
        }
        return path
    }
}

/// Decorative brand line. It never encodes a health or mood measurement.
struct RiverQuietFlow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.72))
        path.addCurve(to: CGPoint(x: rect.width * 0.2, y: rect.height * 0.4),
                      control1: CGPoint(x: rect.width * 0.08, y: rect.height * 0.94),
                      control2: CGPoint(x: rect.width * 0.1, y: rect.height * 0.1))
        path.addCurve(to: CGPoint(x: rect.width * 0.45, y: rect.height * 0.53),
                      control1: CGPoint(x: rect.width * 0.31, y: rect.height * 0.8),
                      control2: CGPoint(x: rect.width * 0.34, y: rect.height * 0.22))
        path.addCurve(to: CGPoint(x: rect.width * 0.72, y: rect.height * 0.28),
                      control1: CGPoint(x: rect.width * 0.55, y: rect.height * 0.8),
                      control2: CGPoint(x: rect.width * 0.6, y: rect.height * 0.05))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.12),
                      control1: CGPoint(x: rect.width * 0.83, y: rect.height * 0.5),
                      control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.1))
        return path
    }
}

struct RiverSoftMetric: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    RiverIconWell(systemImage: symbol, tint: tint, size: 32)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Color.tertiaryInk)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk)
                    Text(value).font(AppTypography.metricDisplay()).foregroundStyle(Color.ink)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                }
                Text(detail).font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                    .lineLimit(2).frame(minHeight: 26, alignment: .topLeading)
            }
            .padding(19).frame(maxWidth: .infinity, alignment: .leading)
            .riverSoftSurface(radius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain)
    }
}
