import SwiftUI

// Color utilities shared by the data model and the scoring stages.
// The legacy GlassCard/SectionHeader/MetricRing components retired:
// everything renders through RiverIOSPanel and RiverDesignSystem now.

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
