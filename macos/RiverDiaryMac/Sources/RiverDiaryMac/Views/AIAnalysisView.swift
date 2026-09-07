import SwiftUI
import AppKit

struct AIAnalysisView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore

    @Binding var anchorDate: Date
    @State private var selectedRange = 7

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 420), spacing: 14)]

    private var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -(selectedRange - 1), to: Calendar.current.startOfDay(for: anchorDate)) ?? anchorDate
    }

    private var endDate: Date {
        Calendar.current.startOfDay(for: anchorDate)
    }

    private var startDateKey: String { DiaryEntry.dateFormatter.string(from: startDate) }
    private var endDateKey: String { DiaryEntry.dateFormatter.string(from: endDate) }

    private var dateRangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd"
        if selectedRange == 1 {
            return formatter.string(from: anchorDate)
        }
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    private var analysisTasks: [(task: AITask, runner: () async -> Void)] {
        let entries = filteredEntries
        let sessions = filteredSessions
        let captures = filteredCaptures
        let recent = Array(entries.suffix(selectedRange))

        return [
            (.analysisDaily, { await ai.runAnalysisDaily(entries: Array(entries.suffix(1)), sessions: sessions, captures: captures, archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
            (.analysisMood, { await ai.runAnalysisMood(entries: recent, sessions: sessions, archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
            (.analysisFocus, { await ai.runAnalysisFocus(sessions: sessions, entries: Array(recent.suffix(3)), archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
            (.analysisHealth, { await ai.runAnalysisHealth(entries: recent, archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
            (.analysisWeekly, { await ai.runAnalysisWeekly(entries: recent, sessions: sessions, archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
            (.analysisAction, { await ai.runAnalysisAction(entries: Array(recent.suffix(5)), sessions: sessions, archiveStartDate: startDateKey, archiveEndDate: endDateKey) }),
        ]
    }

    private var filteredEntries: [DiaryEntry] {
        let startKey = DiaryEntry.dateFormatter.string(from: startDate)
        let endKey = DiaryEntry.dateFormatter.string(from: endDate)
        return store.entries.filter { $0.date >= startKey && $0.date <= endKey }.sorted { $0.date < $1.date }
    }

    private var filteredSessions: [ActivitySession] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return activity.sessions.filter { $0.start >= start && $0.start < end }.sorted { $0.start < $1.start }
    }

    private var filteredCaptures: [QuickCapture] {
        let startKey = DiaryEntry.dateFormatter.string(from: startDate)
        let endKey = DiaryEntry.dateFormatter.string(from: endDate)
        return store.quickCaptures
            .filter { dateKey, _ in dateKey >= startKey && dateKey <= endKey }
            .values.flatMap { $0 }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var isAIReady: Bool {
        ai.isEnabled && ai.isConfigured && ai.analysisReady
    }

    private var generatedCount: Int {
        analysisTasks.filter { ai.taskStates[$0.task]?.answer != nil }.count
    }

    private var runningCount: Int {
        analysisTasks.filter { ai.taskStates[$0.task]?.isLoading == true }.count
    }

    private var isAnyTaskRunning: Bool {
        runningCount > 0
    }

    private var dataSummary: String {
        let parts = [
            "\(filteredEntries.count) 天日记",
            "\(filteredSessions.count) 段足迹",
            "\(filteredCaptures.count) 条快记"
        ]
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !ai.isEnabled {
                    lockedView(
                        icon: "sparkles.slash",
                        title: "AI 分析模式未开启",
                        message: "如果你想使用 AI 分析，可以在设置里打开分析模型。"
                    )
                } else if !ai.isConfigured {
                    lockedView(
                        icon: "key.slash",
                        title: "AI 模型未连接",
                        message: "先连接可用的模型 API，并完成一次测试连接。"
                    )
                } else {
                    controlPanel
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(analysisTasks, id: \.task) { item in
                            AIAnalysisCardView(
                                task: item.task,
                                ai: ai,
                                dateRange: dateRangeLabel,
                                onRun: { Task { await item.runner() } }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 1280, alignment: .topLeading)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            restoreArchivedResults()
        }
        .onChange(of: anchorDate) {
            clearAnalysisResults()
            restoreArchivedResults()
        }
        .onChange(of: selectedRange) {
            clearAnalysisResults()
            restoreArchivedResults()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("AI 分析")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.ink)
                StatusBadge(ai.analysisReady ? "已就绪" : ai.isEnabled ? "未连接" : "已关闭", tone: ai.analysisReady ? .positive : .neutral)
            }
            Text("\(dateRangeLabel) · \(dataSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlPanel: some View {
        SoftCard(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Label("日期在左侧导航统一选择，这里按范围往前分析。", systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(runningCount > 0 ? "生成中 \(runningCount) 项" : "\(generatedCount)/\(analysisTasks.count) 已生成")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(runningCount > 0 ? Color(hex: "#B26B00") : .secondary)
                        .monospacedDigit()
                }

                HStack(spacing: 8) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                        rangeButton(days)
                    }

                    Spacer()

                    Button {
                        Task {
                            for item in analysisTasks {
                                await item.runner()
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "wand.and.stars")
                            Text(isAnyTaskRunning ? "正在生成…" : "生成全部")
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.ctaBackground, in: Capsule())
                        .foregroundStyle(Color.ctaText)
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnyTaskRunning)
                }

                ProgressBar(value: Double(generatedCount) / Double(max(1, analysisTasks.count)) * 100)
            }
        }
    }

    private func rangeButton(_ days: Int) -> some View {
        let selected = selectedRange == days

        return Button {
            withAnimation(.easeOut(duration: 0.16)) {
                selectedRange = days
            }
        } label: {
            Text(days == 1 ? "1 天" : "\(days) 天")
                .font(.caption.weight(selected ? .semibold : .medium))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(selected ? Color.ctaBackground : Color.chip, in: Capsule())
                .foregroundStyle(selected ? Color.ctaText : Color.secondaryInk)
                .overlay(Capsule().stroke(Color.border.opacity(selected ? 0 : 1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func lockedView(icon: String, title: String, message: String) -> some View {
        SoftCard {
            VStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.ink)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("前往设置", systemImage: "gear")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(Color.ctaBackground, in: Capsule())
                        .foregroundStyle(Color.ctaText)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        }
    }

    private func clearAnalysisResults() {
        [AITask.analysisDaily, .analysisMood, .analysisFocus, .analysisHealth, .analysisWeekly, .analysisAction].forEach {
            ai.clearTask($0)
        }
    }

    private func restoreArchivedResults() {
        ai.restoreAnalysisResults(startDate: startDateKey, endDate: endDateKey)
    }
}

struct AIAnalysisCardView: View {
    let task: AITask
    @ObservedObject var ai: AIAssistantStore
    let dateRange: String
    let onRun: () -> Void

    @State private var userExpanded: Bool?

    private var state: AITaskState? {
        ai.taskStates[task]
    }

    private var isLoading: Bool {
        state?.isLoading == true
    }

    private var isExpanded: Bool {
        userExpanded ?? (state?.answer != nil || isLoading)
    }

    private var color: Color {
        Color(hex: task.analysisColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if isExpanded {
                content
            }
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.22), value: isExpanded)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: task.analysisIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)

                Text("\(dateRange) · \(task.analysisSubtitle)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if state?.error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            } else if state?.answer != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "#2C8158"))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    userExpanded = !isExpanded
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.chip, in: Circle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "收起" : "展开")
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = state?.error {
                errorView(error)
            } else if let answer = state?.answer {
                FormattedAIResult(text: answer, accentColor: color)

                HStack(spacing: 8) {
                    Text("更新于 \(state?.updatedAt?.formatted(date: .omitted, time: .shortened) ?? "")" + (state?.isArchived == true ? " · 已留档" : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .modifier(SmallActionButtonStyle(dark: false))

                    Button {
                        onRun()
                    } label: {
                        Label("重写", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .modifier(SmallActionButtonStyle(dark: false))
                    .disabled(isLoading)
                }
            } else {
                VStack(spacing: 10) {
                    Text("还没有生成这项分析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        onRun()
                    } label: {
                        Label("生成\(task.title)", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(color)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ai.analysisReady || isLoading)
                }
            }

            if !ai.analysisReady {
                Label(ai.isEnabled ? "AI 模型还没连接成功。" : "当前是非 AI 分析模式。", systemImage: "sparkles.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func errorView(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct FormattedAIResult: View {
    let text: String
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parseSections(text).enumerated()), id: \.offset) { _, section in
                sectionView(section)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.chip.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func parseSections(_ text: String) -> [(title: String?, body: String)] {
        var sections: [(String?, String)] = []
        var currentTitle: String?
        var currentBody: [String] = []

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                if !currentBody.isEmpty {
                    sections.append((currentTitle, currentBody.joined(separator: "\n")))
                    currentBody = []
                }
                currentTitle = trimmed.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("### ") {
                if !currentBody.isEmpty {
                    sections.append((currentTitle, currentBody.joined(separator: "\n")))
                    currentBody = []
                }
                currentTitle = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else if !trimmed.isEmpty {
                currentBody.append(line)
            }
        }

        if !currentBody.isEmpty {
            sections.append((currentTitle, currentBody.joined(separator: "\n")))
        }
        if sections.isEmpty {
            sections.append((nil, text))
        }
        return sections
    }

    @ViewBuilder
    private func sectionView(_ section: (title: String?, body: String)) -> some View {
        if let title = section.title {
            HStack(spacing: 7) {
                Rectangle()
                    .fill(accentColor.opacity(0.7))
                    .frame(width: 3, height: 12)
                    .cornerRadius(2)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.ink)
            }
        }

        ForEach(section.body.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, id: \.self) { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(accentColor.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                    Text(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .foregroundStyle(Color.secondaryInk)
                }
            } else {
                Text(trimmed)
                    .font(.system(size: 13, weight: .medium))
                    .lineSpacing(5)
                    .foregroundStyle(Color.ink)
            }
        }
    }
}
