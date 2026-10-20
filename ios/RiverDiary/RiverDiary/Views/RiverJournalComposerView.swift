import RiverDiaryCore
import SwiftUI

/// A single writing surface for Today, the archive, and the application action.
/// Drafts stay local; only an explicit save writes shared journal state.
struct RiverJournalComposerView: View {
    let date: Date
    var onSaved: () -> Void = {}
    @Environment(\.riverTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var node: RiverNodeStore
    @EnvironmentObject private var diary: DiaryStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @EnvironmentObject private var drafts: RiverLocalDraftStore
    @State private var text = ""
    @State private var ratingEnabled = false
    @State private var rating = 70.0
    @State private var restored = false
    @State private var saved = false
    @State private var message: String?
    @FocusState private var editorFocused: Bool

    private var dayKey: String { RiverIOSProjection.dayKey(date) }
    private var database: RiverLocalDatabase? { node.database }
    private var existing: RiverJournalEntryContent? {
        database?.sharedUserRecords.first {
            $0.kind == .journalEntry && $0.status == "current" && $0.logicalKey == dayKey
        }?.journalEntryContent
    }
    private var legacy: DiaryEntry? { diary.entries.first { $0.date == dayKey } }
    private var isManualDay: Bool { legacy == nil }
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if editorFocused {
                        Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                            .font(.footnote).foregroundStyle(theme.secondaryInk)
                    } else {
                        opening
                    }
                    editor
                    if isManualDay { ratingControl }
                    if let error = drafts.lastError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(theme.warning)
                    }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(theme.warning)
                            .accessibilityIdentifier("river.journal.message")
                    }
                    Label("草稿保存在这台 iPhone，保存后才参与已启用的同步。", systemImage: "lock")
                        .font(.footnote).foregroundStyle(theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, theme.pageGutter).padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("写日记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("稍后再写") { persistDraft(); drafts.flush(); dismiss() }
                        .accessibilityIdentifier("river.journal.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .font(.body.weight(.semibold)).disabled(!hasText || database == nil)
                        .accessibilityIdentifier("river.journal.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editorFocused = false }
                }
            }
        }
        .tint(theme.accentText)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: restore)
        .onChange(of: text) { _, _ in persistDraft() }
        .onChange(of: rating) { _, _ in persistDraft() }
        .onChange(of: ratingEnabled) { _, _ in persistDraft() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persistDraft(); drafts.flush() } }
        .onDisappear { if !saved { persistDraft(); drafts.flush() } }
    }

    private var opening: some View {
        VStack(alignment: .leading, spacing: 8) {
            RiverSystemSignature(detail: "JOURNAL")
            Text(date.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                .font(theme.titleFont).foregroundStyle(theme.ink)
            Text("这一页，留给你自己。")
                .font(.subheadline).foregroundStyle(theme.secondaryInk)
            if database == nil {
                Text("本机记录暂时无法打开。草稿仍可保留，恢复后再保存。")
                    .font(.callout).foregroundStyle(theme.warning)
            }
        }
    }

    private var editor: some View {
        TextField("从一句话开始…", text: $text, axis: .vertical)
            .font(theme.textFont(18)).lineSpacing(7)
            .lineLimit(textSize.isAccessibilitySize ? 3...24 : 8...24)
            .focused($editorFocused)
            .frame(minHeight: editorFocused ? (textSize.isAccessibilitySize ? 180 : 260) : 290, alignment: .topLeading)
            .padding(18)
            .foregroundStyle(theme.ink)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: theme.panelRadius))
            .overlay { RoundedRectangle(cornerRadius: theme.panelRadius).strokeBorder(theme.separator, lineWidth: 0.7) }
            .accessibilityLabel("日记内容")
            .accessibilityIdentifier("river.journal.editor")
    }

    private var ratingControl: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("给这一天一个评分（可选）", isOn: $ratingEnabled)
                .font(.subheadline).accessibilityIdentifier("river.journal.rating.enabled")
            if ratingEnabled {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(rating.rounded()))").font(theme.textFont(30, relativeTo: .title, weight: .medium)).monospacedDigit()
                    Text("/ 100").font(.subheadline).foregroundStyle(theme.secondaryInk)
                    Spacer()
                }.accessibilityElement(children: .combine).accessibilityIdentifier("river.journal.rating.value")
                Slider(value: $rating, in: 0...100, step: 1)
                    .accessibilityLabel("这一天的评分").accessibilityIdentifier("river.journal.rating")
                Text("用自己的尺度回看，可以随时留空。")
                    .font(.footnote).foregroundStyle(theme.secondaryInk)
            }
        }.foregroundStyle(theme.ink)
    }

    private func restore() {
        guard !restored else { return }
        let content = existing
        let storedText = content?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? content?.body : nil
        text = drafts.text(for: dayKey, kind: .journal) ?? storedText ?? legacyText
        let draftRating = drafts.rating(for: dayKey)
        ratingEnabled = draftRating?.enabled ?? (content?.moodScore != nil)
        rating = Double(draftRating?.score ?? content?.moodScore ?? 70)
        restored = true
    }

    /// Compatibility journals contain several real text fields. Keep them when
    /// making an editable shared journal rather than starting with a blank page.
    private var legacyText: String {
        guard let legacy else { return "" }
        var sections: [String] = []
        if let overview = legacy.overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(overview)
        } else if let mood = legacy.mood, !mood.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(mood)
        }
        let thoughts = (legacy.thoughts ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !thoughts.isEmpty { sections.append("想法\n" + thoughts.joined(separator: "\n\n")) }
        let memos = (legacy.memos ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !memos.isEmpty { sections.append("备忘\n" + memos.joined(separator: "\n\n")) }
        return sections.joined(separator: "\n\n")
    }

    private func persistDraft() {
        guard restored, !saved else { return }
        drafts.update(text, for: dayKey, kind: .journal, moodScore: Int(rating.rounded()), ratingEnabled: ratingEnabled)
    }

    private func save() {
        guard let database, hasText else { return }
        let previous = existing
        let content = RiverJournalEntryContent(
            dayKey: dayKey, body: text.trimmingCharacters(in: .whitespacesAndNewlines),
            moodScore: isManualDay ? (ratingEnabled ? Int(rating.rounded()) : nil) : previous?.moodScore,
            energyScore: previous?.energyScore, focusScore: previous?.focusScore,
            outputScore: previous?.outputScore, category: previous?.category,
            tags: previous?.tags ?? [], source: nil, updatedAt: .now
        )
        guard let record = RiverSharedStateRecord.journalEntry(content) else {
            message = "这段文字暂时无法保存。草稿会保留在本机。"
            return
        }
        do {
            try database.saveSharedUserRecord(record)
            saved = true
            drafts.remove(for: dayKey, kind: .journal)
            diary.select(legacy)
            RiverHaptics.success()
            if drive.hasAccess { node.synchronize(using: drive, localMoodScores: diary.localMoodScoresByDate) }
            onSaved()
            dismiss()
        } catch {
            message = "保存失败：\(error.localizedDescription)"
            persistDraft(); drafts.flush()
            RiverHaptics.error()
        }
    }
}
