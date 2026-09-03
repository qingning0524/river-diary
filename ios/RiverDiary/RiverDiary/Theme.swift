import SwiftUI

extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .alphanumerics.inverted)
        let red, green, blue: Double
        if sanitized.count == 6, let value = UInt64(sanitized, radix: 16) {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        } else {
            red = 0.37
            green = 0.32
            blue = 0.86
        }
        self.init(red: red, green: green, blue: blue)
    }
}

extension DiaryEntry {
    var stageColor: Color {
        Color(hex: stageColorHex)
    }

    var growthColor: Color {
        Color(hex: metrics?.growthStage?.color ?? "#4A8FDE")
    }
}

extension Stage {
    var swiftColor: Color {
        Color(hex: color)
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(17)
            .background(.regularMaterial, in: .rect(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.07), radius: 14, y: 7)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            Spacer()
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct MetricRing: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0, min(1, value / 100)))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .shadow(color: color.opacity(0.16), radius: 3)
                    .rotationEffect(.degrees(-90))
                Text("\(Int(value.rounded()))")
                    .font(.system(.caption2, design: .rounded).weight(.bold))
                    .monospacedDigit()
            }
            .frame(width: 56, height: 56)

            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
