import SwiftUI

/// Trailing inspector used by Today / Memory / Ask to show evidence.
struct InspectorPanel: View {
    let content: InspectorContent?
    @ObservedObject var store: DiaryStore

    @State private var editingTitle = ""
    @State private var editingNote = ""
    @State private var editingFavorite = false
    @State private var isEditing = false

    var body: some View {
        Group {
            if let content {
                switch content {
                case .episode(let item):
                    episodeInspector(item)
                case .evidence(let title, let entries, let captures):
                    evidenceInspector(title: title, entries: entries, captures: captures)
                }
            } else {
                Text("Nothing selected")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Episode

    private func episodeInspector(_ item: ActivityTimelineItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                    HStack(spacing: 8) {
                        Text(clockRange(item))
                        if item.duration > 0 { Text(ActivityFormatter.time(item.duration)) }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                if isEditing {
                    editor(item)
                } else {
                    section("Summary") {
                        Text(item.summary)
                            .font(.system(size: 12))
                            .lineSpacing(5)
                        if let note = item.annotation?.note, !note.isEmpty {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                                .padding(.top, 4)
                        }
                    }
                }

                section("Evidence") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.sessions, id: \.id) { session in
                            EvidenceRow(session: session)
                        }
                        if item.kind == .capture, let capture = item.capture {
                            HStack(spacing: 8) {
                                Text(capture.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .leading)
                                Text(capture.text)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }

                section("Confidence") {
                    confidenceBadge(for: item)
                }

                HStack(spacing: 8) {
                    Button(isEditing ? "完成" : "Edit") { toggleEditing(item) }
                        .buttonStyle(.bordered)
                    if item.annotation != nil {
                        Button("清除整理") {
                            if let key = item.annotationKey {
                                try? store.saveTimelineAnnotation(TimelineAnnotation(), for: key)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(20)
        }
        .onAppear { isEditing = false }
    }

    private func toggleEditing(_ item: ActivityTimelineItem) {
        if isEditing {
            if let key = item.annotationKey {
                var annotation = store.timelineAnnotations[key] ?? TimelineAnnotation()
                annotation.title = editingTitle
                annotation.note = editingNote
                annotation.isFavorite = editingFavorite
                try? store.saveTimelineAnnotation(annotation, for: key)
            }
            isEditing = false
        } else {
            editingTitle = item.annotation?.title ?? ""
            editingNote = item.annotation?.note ?? ""
            editingFavorite = item.annotation?.isFavorite ?? false
            isEditing = true
        }
    }

    private func editor(_ item: ActivityTimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("标题", text: $editingTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $editingNote)
                .font(.system(size: 12))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Toggle("收藏", isOn: $editingFavorite)
                .font(.system(size: 12))
        }
    }

    private func confidenceBadge(for item: ActivityTimelineItem) -> some View {
        let titled = item.sessions.filter { !($0.windowTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let label: String
        let color: Color
        if item.sessions.isEmpty {
            label = "Unknown"
            color = .gray
        } else if titled == item.sessions.count {
            label = "High"
            color = .green
        } else if titled > 0 {
            label = "Medium"
            color = .orange
        } else {
            label = "Low"
            color = .gray
        }
        return Text(label.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }

    // MARK: Evidence

    private func evidenceInspector(title: String, entries: [DiaryEntry], captures: [QuickCapture]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                section("Diary") {
                    ForEach(Array(entries.prefix(12)), id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.shortDate)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.displayOverview)
                                .font(.system(size: 12))
                                .lineLimit(3)
                        }
                        .padding(.vertical, 3)
                    }
                    if entries.isEmpty {
                        Text("No diary evidence.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                section("Quick notes") {
                    ForEach(Array(captures.prefix(12)), id: \.id) { capture in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capture.text)
                                .font(.system(size: 12))
                                .lineLimit(3)
                            Text(capture.createdAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    if captures.isEmpty {
                        Text("No quick notes.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func clockRange(_ item: ActivityTimelineItem) -> String {
        let start = item.start.formatted(date: .omitted, time: .shortened)
        let end = item.end.formatted(date: .omitted, time: .shortened)
        return "\(start) — \(end)"
    }
}

private struct EvidenceRow: View {
    let session: ActivitySession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(session.start.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Text(session.appName)
                    .font(.system(size: 12, weight: .medium))
            }
            if let title = session.windowTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 54)
            }
        }
        .padding(.vertical, 2)
    }
}
