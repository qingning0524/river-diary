import SwiftUI

struct MoodAreaChart: View {
    let entries: [DiaryEntry]
    @Binding var selectedID: String?

    private struct ChartPoint: Identifiable {
        let id: String
        let score: Double
        let point: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let points = chartPoints(in: proxy.size)

            Canvas { context, size in
                guard points.count > 1 else { return }

                let area = Path { path in
                    path.move(to: CGPoint(x: points[0].point.x, y: size.height))
                    points.forEach { path.addLine(to: $0.point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].point.x, y: size.height))
                    path.closeSubpath()
                }

                context.fill(area, with: .linearGradient(
                    Gradient(colors: [Color(hex: "#7886FF").opacity(0.24), Color(hex: "#7886FF").opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))

                let line = Path { path in
                    path.move(to: points[0].point)
                    points.dropFirst().forEach { path.addLine(to: $0.point) }
                }

                context.stroke(line, with: .linearGradient(
                    Gradient(colors: [Color(hex: "#7FB3FF"), Color(hex: "#7F83FF"), Color(hex: "#FF8FB3")]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                ), style: StrokeStyle(lineWidth: 3.2, lineCap: .round, lineJoin: .round))

                for item in points {
                    let isSelected = item.id == selectedID
                    let radius: CGFloat = isSelected ? 6 : 4
                    let rect = CGRect(
                        x: item.point.x - radius,
                        y: item.point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let dot = Path(ellipseIn: rect)
                    context.fill(dot, with: .color(isSelected ? Color(hex: "#FF8FB3") : .white))
                    context.stroke(dot, with: .color(Color(hex: "#7F83FF")), lineWidth: 3)
                }

                if let selectedID, let selected = points.first(where: { $0.id == selectedID }) {
                    var guide = Path()
                    guide.move(to: CGPoint(x: selected.point.x, y: 4))
                    guide.addLine(to: CGPoint(x: selected.point.x, y: size.height - 2))
                    context.stroke(guide, with: .color(.black.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedID = nearestID(to: value.location, in: points)
                    }
            )
        }
    }

    private func chartPoints(in size: CGSize) -> [ChartPoint] {
        let scores = entries.map { Double($0.metrics?.overall ?? $0.score ?? 0) }
        guard scores.count > 1, let maxValue = scores.max(), let minValue = scores.min() else { return [] }

        let span = max(maxValue - minValue, 18)
        let inset: CGFloat = 14
        let chartHeight = size.height - inset * 2
        let horizontalStep = (size.width - inset * 2) / CGFloat(scores.count - 1)

        return scores.enumerated().map { index, score in
            ChartPoint(
                id: entries[index].id,
                score: score,
                point: CGPoint(
                    x: inset + CGFloat(index) * horizontalStep,
                    y: inset + (1 - ((score - minValue) / span)) * chartHeight
                )
            )
        }
    }

    private func nearestID(to location: CGPoint, in points: [ChartPoint]) -> String? {
        points.min { lhs, rhs in
            distance(location, lhs.point) < distance(location, rhs.point)
        }?.id
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
