import SwiftUI

struct SavedQueryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SavedQuery
    let onSave: (SavedQuery) throws -> Void
    @State private var errorMessage: String?

    init(query: SavedQuery, onSave: @escaping (SavedQuery) throws -> Void) {
        _draft = State(initialValue: query)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("保存常用查询")
                .font(.title2.weight(.semibold))

            TextField("查询名称", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            TextField("查询词，可留空表示只按时间范围查询", text: $draft.query)
                .textFieldStyle(.roundedBorder)

            Picker("时间范围", selection: $draft.days) {
                Text("7 天").tag(7)
                Text("30 天").tag(30)
                Text("90 天").tag(90)
                Text("365 天").tag(365)
            }
            .pickerStyle(.segmented)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    var updated = draft
                    updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.query = updated.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.days = min(365, max(1, updated.days))
                    updated.updatedAt = Date()
                    do {
                        try onSave(updated)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
