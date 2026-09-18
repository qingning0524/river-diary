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

                let linePath = Path { path in
                    path.move(to: points[0].point)
                    points.dropFirst().forEach { path.addLine(to: $0.point) }
                }

                let area = Path { path in
                    path.move(to: CGPoint(x: points[0].point.x, y: size.height))
                    points.forEach { path.addLine(to: $0.point) }
                    path.addLine(to: CGPoint(x: points[points.count - 1].point.x, y: size.height))
                    path.closeSubpath()
                }

                context.fill(area, with: .linearGradient(
                    Gradient(colors: [Color.riverAmethyst.opacity(0.26), Color.riverBlue.opacity(0)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                ))

                let lineGradient = GraphicsContext.Shading.linearGradient(
                    Gradient(colors: [Color.riverBlue, Color.riverAmethyst, Color.riverPink]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: 0)
                )

                // 底层柔光，让曲线像一条发光的河
                context.stroke(linePath, with: lineGradient, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                context.stroke(linePath, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                context.stroke(linePath, with: lineGradient, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))

                for item in points {
                    let isSelected = item.id == selectedID
                    let radius: CGFloat = isSelected ? 5.5 : 3.5
                    let rect = CGRect(
                        x: item.point.x - radius,
                        y: item.point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let dot = Path(ellipseIn: rect)
                    context.fill(dot, with: .color(isSelected ? Color.riverPink : .white))
                    context.stroke(dot, with: .color(isSelected ? .white : Color.riverAmethyst.opacity(0.9)), lineWidth: isSelected ? 2 : 1.6)
                }

                if let selectedID, let selected = points.first(where: { $0.id == selectedID }) {
                    var guide = Path()
                    guide.move(to: CGPoint(x: selected.point.x, y: 4))
                    guide.addLine(to: CGPoint(x: selected.point.x, y: size.height - 2))
                    context.stroke(guide, with: .color(.black.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                    // 选中日期的悬浮小签
                    let entry = entries.first { $0.id == selectedID } ?? entries[0]
                    let labelText = Text("\(entry.shortDate)  \(Int(selected.score))")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                    let resolved = context.resolve(labelText)
                    let labelSize = resolved.measure(in: CGSize(width: 400, height: 40))
                    let labelWidth = labelSize.width + 16
                    let labelHeight = labelSize.height + 8
                    var labelX = selected.point.x - labelWidth / 2
                    labelX = min(max(labelX, 4), size.width - labelWidth - 4)
                    let labelRect = CGRect(
                        x: labelX,
                        y: max(2, selected.point.y - labelHeight - 10),
                        width: labelWidth,
                        height: labelHeight
                    )
                    let labelShape = Path(roundedRect: labelRect, cornerRadius: 8)
                    context.fill(labelShape, with: .color(Color.ink.opacity(0.92)))
                    context.draw(resolved, at: CGPoint(x: labelRect.midX, y: labelRect.midY))
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
        let scoredEntries = entries.filter { ($0.metrics?.overall ?? $0.score)?.isFinite == true }
        let scores = scoredEntries.compactMap { $0.metrics?.overall ?? $0.score }
        guard scores.count > 1, let maxValue = scores.max(), let minValue = scores.min() else { return [] }

        let span = max(maxValue - minValue, 18)
        let inset: CGFloat = 14
        let chartHeight = size.height - inset * 2
        let horizontalStep = (size.width - inset * 2) / CGFloat(scores.count - 1)

        return scores.enumerated().map { index, score in
            ChartPoint(
                id: scoredEntries[index].id,
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
