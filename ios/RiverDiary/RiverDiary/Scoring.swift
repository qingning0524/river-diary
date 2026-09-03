import SwiftUI

enum Scoring {
    static let stages: [Stage] = [
        Stage(label: "低谷", color: "#E85D4E"),
        Stage(label: "回升", color: "#F5A04C"),
        Stage(label: "平稳", color: "#D4A017"),
        Stage(label: "积极", color: "#7CB342"),
        Stage(label: "饱满", color: "#5B9BD5")
    ]

    private static let thresholds: [(minimum: Int, stage: Stage)] = [
        (85, stages[4]),
        (70, stages[3]),
        (50, stages[2]),
        (30, stages[1]),
        (0, stages[0])
    ]

    static func stage(for score: Int) -> Stage {
        thresholds.first { score >= $0.minimum }?.stage ?? stages[2]
    }
}
