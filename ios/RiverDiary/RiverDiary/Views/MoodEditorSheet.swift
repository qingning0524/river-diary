import SwiftUI
import UIKit

struct MoodEditorSheet: View {
    @EnvironmentObject private var store: DiaryStore
    @Environment(\.dismiss) private var dismiss

    let entry: DiaryEntry
    @State private var score: Double
    @FocusState private var scoreFieldFocused: Bool

    private var roundedScore: Int { min(100, max(0, Int(score.rounded()))) }
    private var stage: Stage { Scoring.stage(for: roundedScore) }

    init(entry: DiaryEntry) {
        self.entry = entry
        _score = State(initialValue: entry.score ?? 60)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.entryDate, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(roundedScore)")
                            .font(.system(size: 76, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: roundedScore)
                        Text("/100")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(stage.swiftColor)

                    Text(stage.label)
                        .font(.headline)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(stage.swiftColor.opacity(0.15), in: .capsule)
                }

                Slider(value: $score, in: 0...100, step: 1) {
                    Text("今日心情")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("100")
                }
                .tint(stage.swiftColor)
                .sensoryFeedback(.selection, trigger: roundedScore)

                TextField("分数", value: Binding(
                    get: { Double(roundedScore) },
                    set: { score = min(100, max(0, $0)) }
                ), format: .number)
                    .keyboardType(.numberPad)
                    .focused($scoreFieldFocused)
                    .multilineTextAlignment(.center)
                    .font(.title2.weight(.semibold))
                    .padding()
                    .background(.quaternary, in: .rect(cornerRadius: 16))

                Text("评分只保存在这台设备的本地，不会修改原始日记数据。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(22)
            .navigationTitle("修改心情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { scoreFieldFocused = false }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        store.setScore(roundedScore, for: entry)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
