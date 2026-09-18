import SwiftUI

struct LocalReviewView: View {
    let review: LocalReview
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                metric("写下日记", "\(review.writingDays)", "天", "book.closed")
                metric("平均心情", review.averageMood.map { "\(Int($0.rounded()))" } ?? "—", "\(review.moodSamples) 天评分", "sun.horizon")
                metric("实时足迹", review.duration > 0 ? ActivityFormatter.time(review.duration) : "—", "已有记录", "clock")
                metric("随手留下", "\(review.captureCount)", "条快记", "quote.bubble")
            }
            SoftCard(padding: 22) {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 18) {
                        let hasActivity = review.days.contains { $0.duration > 0 }
                        Text(hasActivity ? "每天记录到的时间" : "心情的变化").font(.system(size: 14, weight: .medium))
                        GeometryReader { geometry in
                            HStack(alignment: .bottom, spacing: 5) {
                                let maximum = hasActivity ? max(60, review.days.map(\.duration).max() ?? 0) : 100
                                ForEach(review.days) { day in
                                    let value = hasActivity ? day.duration : day.mood ?? 0
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill((hasActivity ? day.duration > 0 : day.mood != nil) ? Color.riverAmethyst.opacity(0.65) : Color.chip)
                                        .frame(height: max(3, CGFloat(value / maximum) * geometry.size.height))
                                        .help(hasActivity ? "\(day.id) · \(day.duration > 0 ? ActivityFormatter.time(day.duration) : "未记录")" : "\(day.id) · \(day.mood.map { "心情 \(Int($0))" } ?? "未评分")")
                                }
                            }.frame(height: geometry.size.height, alignment: .bottom)
                        }.frame(height: 98)
                        HStack {
                            Text(review.start.formatted(.dateTime.month().day()))
                            Spacer()
                            Text(review.end.formatted(.dateTime.month().day()))
                        }.font(.system(size: 10)).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("时间去向").font(.system(size: 14, weight: .medium))
                        ForEach(review.categories.prefix(5), id: \.name) { usage in
                            HStack(spacing: 8) {
                                Circle().fill(Color(hex: ActivityClassifier.color(for: usage.name))).frame(width: 6, height: 6)
                                Text(usage.name)
                                Spacer()
                                Text(ActivityFormatter.time(usage.duration)).foregroundStyle(.secondary)
                            }.font(.system(size: 12))
                        }
                        if review.categories.isEmpty { Text("有了实时记录后，这里会显示时间分布。") .font(.system(size: 12)).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity)
                }
            }
            Text("本机回顾 · 只统计已有记录，未评分的日子不按零计算。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
    private func metric(_ title: String, _ value: String, _ footnote: String, _ icon: String) -> some View {
        SoftCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.editorial(value.count > 7 ? 21 : 29)).lineLimit(1).minimumScaleFactor(0.75)
                Text(footnote).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}
