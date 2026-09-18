import SwiftUI

struct TimelineJournalPanel: View {
    let entry: DiaryEntry?
    var openDiary: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("THE DAILY NOTE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.8).foregroundStyle(Color.riverAmethyst)
                Spacer()
                Image(systemName: "book.closed").font(.system(size: 13)).foregroundStyle(Color.secondaryInk)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("一天的注脚")
                        .font(.system(size: 23, weight: .medium, design: .serif))
                        .foregroundStyle(Color.ink)
                    if let score = entry?.metrics?.mood ?? entry?.score, score.isFinite {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("心情").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("\(Int(score.rounded()))").font(.system(size: 17, weight: .medium, design: .rounded))
                            Text("/ 100").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    } else {
                        Text("感受也值得被留下")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                RiverLineMark().frame(width: 68, height: 60).accessibilityHidden(true)
            }
            if let entry, !entry.displayOverview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.displayOverview)
                    .font(.system(size: 13)).lineSpacing(6)
                    .foregroundStyle(Color.secondaryInk).lineLimit(5)
                    .textSelection(.enabled)
            } else {
                Text("发生的事已经在左边。\n这一刻的感受，留给你来写。")
                    .font(.system(size: 13)).lineSpacing(6).foregroundStyle(Color.secondaryInk)
            }
            if let openDiary {
                Button(action: openDiary) {
                    HStack {
                        Text(entry?.displayOverview.isEmpty == false ? "回到这篇日记" : "写下这一天")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.ink)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(Color.riverAmethyst.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.riverAmethyst.opacity(0.12), lineWidth: 1))
    }
}

private struct RiverLineMark: View {
    var body: some View {
        Canvas { context, size in
            for index in 0..<5 {
                var path = Path()
                let shift = CGFloat(index) * 7
                path.move(to: CGPoint(x: 2 + shift, y: 0))
                path.addCurve(to: CGPoint(x: 35 + shift, y: size.height),
                              control1: CGPoint(x: 62 + shift, y: size.height * 0.26),
                              control2: CGPoint(x: -22 + shift, y: size.height * 0.63))
                context.stroke(path, with: .color(Color.riverAmethyst.opacity(0.12 + Double(index) * 0.09)), lineWidth: 1)
            }
        }
    }
}
