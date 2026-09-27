import AppKit
import SwiftUI

struct TimelineAIDigestView: View {
    let digest: TimelineDigest?
    let timeline: ActivityTimeline
    let isStale: Bool
    let isGenerating: Bool
    let automaticAnalysisEnabled: Bool
    let hasVerifiedConnection: Bool
    let lastUpdated: Date?
    let errorMessage: String?
    let onSelectItem: (ActivityTimelineItem) -> Void
    let onOpenSettings: () -> Void
    let onOpenJournal: () -> Void

    private var rows: [DigestRow] {
        var result: [DigestRow] = []
        var assigned = Set<String>()
        let itemByID = Dictionary(uniqueKeysWithValues: timeline.foldedItems.map { ($0.id, $0) })

        if let digest {
            for segment in digest.segments {
                let sources = segment.candidateIDs.compactMap { itemByID[$0] }.sorted { $0.start < $1.start }
                guard !sources.isEmpty else { continue }
                assigned.formUnion(sources.map(\.id))
                result.append(DigestRow(content: .segment(segment, sources: sources, isAI: true)))
            }
        }

        for item in timeline.foldedItems.sorted(by: { $0.start < $1.start }) {
            if item.kind != .activity {
                result.append(DigestRow(content: .item(item)))
            } else if !assigned.contains(item.id) {
                // A model may omit an item. Keep every observed event visible as
                // a plain factual row rather than silently dropping it.
                result.append(DigestRow(content: .segment(
                    TimelineDigestSegment(
                        candidateIDs: [item.id],
                        title: item.title,
                        summary: item.evidenceLine.isEmpty ? "记录到 \(item.apps.map(\.name).joined(separator: "、")) 的使用" : item.evidenceLine
                    ),
                    sources: [item],
                    isAI: false
                )))
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private var sections: [DigestSection] {
        let grouped = Dictionary(grouping: rows, by: { sectionTitle(for: $0.start) })
        let order = ["凌晨", "上午", "午后", "晚上"]
        return order.compactMap { title in
            guard let rows = grouped[title], !rows.isEmpty else { return nil }
            return DigestSection(title: title, rows: rows.sorted { $0.start < $1.start })
        }
    }

    private func visibleOverview(_ digest: TimelineDigest) -> String {
        let evidenceItems = digest.overviewCandidateIDs.compactMap { id in
            timeline.foldedItems.first { $0.id == id }
        }
        let hasUserText = digest.overviewCaptureIDs.contains { reference in
            timeline.foldedItems.contains { $0.capture.map { "capture:\($0.id.uuidString)" == reference } ?? false }
        }
        if hasUserText || !digest.overviewDiaryDates.isEmpty || evidenceItems.contains(where: \.hasDescribingEvidence) {
            return digest.overview
        }
        let apps = Array(Set(evidenceItems.flatMap { $0.apps.map(\.name) })).prefix(4).joined(separator: "、")
        let prefix = evidenceItems.isEmpty ? "这一天还没有足够的活动记录。" : "这一天记录了 \(evidenceItems.count) 段应用活动。"
        return apps.isEmpty ? prefix : "\(prefix)主要涉及\(apps)，具体内容暂时未知。"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            overview
            if sections.isEmpty {
                EmptyStateView(
                    title: "这一天还没有可整理的应用记录。",
                    message: "有快记时会在下方显示；未记录的时段不会被补成活动。",
                    symbol: "sun.horizon"
                )
                .padding(.vertical, AppSpacing.md)
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(section.title)
                            .font(.system(size: 21, weight: .regular, design: .serif))
                            .foregroundStyle(Color.ink)
                            .padding(.top, AppSpacing.xs)
                        VStack(spacing: AppSpacing.xs) {
                            ForEach(section.rows) { row in
                                DigestRowView(row: row, onSelectItem: onSelectItem)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.md)
    }

    @ViewBuilder
    private var overview: some View {
        if let digest {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(AppTheme.accent)
                    Text("AI 整理的一天")
                        .font(AppTypography.label().weight(.semibold))
                        .foregroundStyle(AppTheme.accent)
                    Spacer()
                    if isGenerating {
                        ProgressView().controlSize(.small)
                        Text("正在更新")
                            .font(AppTypography.micro())
                            .foregroundStyle(Color.tertiaryInk)
                    } else if isStale {
                        Text("记录有更新")
                            .font(AppTypography.micro())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    if let lastUpdated {
                        Text(isStale ? "依据旧记录 · \(lastUpdated.formatted(date: .omitted, time: .shortened))" : "更新于 \(lastUpdated.formatted(date: .omitted, time: .shortened))")
                            .font(AppTypography.micro())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                }
                Text(visibleOverview(digest))
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                DisclosureGroup("查看概览依据 · \(overviewItems(digest).count + digest.overviewDiaryDates.count) 条") {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        ForEach(overviewItems(digest)) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                Label(item.kind == .capture ? "快记 · \(item.start.formatted(date: .omitted, time: .shortened))" : "活动 · \(item.start.formatted(date: .omitted, time: .shortened))", systemImage: item.kind == .capture ? "square.and.pencil" : "circle.fill")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(digest.overviewDiaryDates, id: \.self) { date in
                            Button(action: onOpenJournal) {
                                Label("日记 · \(date)", systemImage: "book.closed")
                                    .font(AppTypography.metadata())
                                    .foregroundStyle(Color.secondaryInk)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, AppSpacing.xs)
                }
                .font(AppTypography.metadata())
                .tint(AppTheme.accent)
            }
            .padding(AppSpacing.md)
            .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(AppTheme.accent.opacity(0.7)).frame(width: 2.5).padding(.vertical, 10)
            }
        } else if isGenerating {
            HStack(spacing: AppSpacing.sm) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 正在整理这一天")
                        .font(AppTypography.label().weight(.medium))
                        .foregroundStyle(Color.ink)
                    Text("先显示已有记录，整理完成后会自动更新。")
                        .font(AppTypography.metadata())
                        .foregroundStyle(Color.secondaryInk)
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(errorMessage ?? fallbackStatus)
                    .font(AppTypography.secondary())
                    .foregroundStyle(Color.secondaryInk)
                if !hasVerifiedConnection {
                    Button("连接模型以启用自动整理", action: onOpenSettings)
                        .buttonStyle(.plain)
                        .font(AppTypography.metadata().weight(.medium))
                        .foregroundStyle(AppTheme.accent)
                }
            }
            .padding(AppSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.strongSurface, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
        }
    }

    private var fallbackStatus: String {
        automaticAnalysisEnabled
            ? "先按本机记录展示；自动整理完成后会在这里出现。"
            : "自动采集与 AI 整理已关闭，当前显示本机记录。"
    }

    private func overviewItems(_ digest: TimelineDigest) -> [ActivityTimelineItem] {
        let items = digest.overviewCandidateIDs.compactMap { id in
            timeline.foldedItems.first { $0.id == id }
        }
        let captures = digest.overviewCaptureIDs.compactMap { reference in
            timeline.foldedItems.first { item in
                item.capture.map { "capture:\($0.id.uuidString)" == reference } ?? false
            }
        }
        return Array(Dictionary(grouping: items + captures, by: \.id).values.compactMap(\.first).sorted { $0.start < $1.start })
    }

    private func sectionTitle(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<5: "凌晨"
        case 5..<12: "上午"
        case 12..<18: "午后"
        default: "晚上"
        }
    }
}

private struct DigestSection: Identifiable {
    let title: String
    let rows: [DigestRow]
    var id: String { title }
}

private struct DigestRow: Identifiable {
    enum Content {
        case segment(TimelineDigestSegment, sources: [ActivityTimelineItem], isAI: Bool)
        case item(ActivityTimelineItem)
    }

    let content: Content

    var id: String {
        switch content {
        case .segment(let segment, _, _): "segment-\(segment.id)"
        case .item(let item): "item-\(item.id)"
        }
    }

    var start: Date {
        switch content {
        case .segment(_, let sources, _): sources.map(\.start).min() ?? .distantPast
        case .item(let item): item.start
        }
    }
}

private struct DigestRowView: View {
    @Environment(\.riverDensity) private var density
    let row: DigestRow
    let onSelectItem: (ActivityTimelineItem) -> Void

    var body: some View {
        switch row.content {
        case .segment(let segment, let sources, let isAI):
            segmentRow(segment, sources: sources, isAI: isAI)
        case .item(let item):
            sourceItemRow(item)
        }
    }

    private func segmentRow(_ segment: TimelineDigestSegment, sources: [ActivityTimelineItem], isAI: Bool) -> some View {
        let start = sources.map(\.start).min() ?? .distantPast
        let end = sources.map(\.end).max() ?? start
        let duration = sources.reduce(0.0) { total, item in total + item.duration }
        let apps = appTokens(sources)
        let hasDescribingSource = sources.contains(where: \.hasDescribingEvidence)
        let recordedApps = apps.prefix(3).map(\.name).joined(separator: "、")
        let displayedTitle = isAI && !hasDescribingSource
            ? (recordedApps.isEmpty ? "一段应用记录" : "\(recordedApps) 的记录")
            : segment.title
        let displayedSummary = isAI && !hasDescribingSource
            ? "记录到这几个应用的连续使用；具体内容暂时未知。"
            : segment.summary

        return HStack(alignment: .top, spacing: 0) {
            timeLabel(start)
            marker(.activity)
            VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xs)) {
                Button {
                    if let first = sources.first { onSelectItem(first) }
                } label: {
                    HStack(alignment: .top, spacing: AppSpacing.sm) {
                        appIcons(apps)
                        VStack(alignment: .leading, spacing: density.spacing(AppSpacing.xxs)) {
                            Text(displayedTitle)
                                .font(.system(size: 16, weight: .medium, design: .serif))
                                .foregroundStyle(Color.ink)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(displayedSummary)
                                .font(AppTypography.secondary())
                                .foregroundStyle(Color.secondaryInk)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: .trailing, spacing: density.spacing(AppSpacing.xxs)) {
                            Text(ActivityFormatter.timeRange(start, end))
                                .font(AppTypography.metadata().monospacedDigit())
                                .foregroundStyle(Color.tertiaryInk)
                                .lineLimit(1)
                            Text(ActivityFormatter.time(duration))
                                .font(AppTypography.micro().monospacedDigit())
                                .foregroundStyle(Color.tertiaryInk)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                HStack(spacing: AppSpacing.xs) {
                    Text(appNamesCaption(apps))
                        .font(AppTypography.micro())
                        .foregroundStyle(Color.tertiaryInk)
                    Text(isAI && hasDescribingSource ? "AI 整理" : "本机记录")
                        .font(AppTypography.micro().weight(.medium))
                        .foregroundStyle(isAI && hasDescribingSource ? AppTheme.accent : Color.secondaryInk)
                    if !hasDescribingSource {
                        Text("内容细节有限")
                            .font(AppTypography.micro())
                            .foregroundStyle(Color.tertiaryInk)
                    }
                    Spacer()
                }

                DisclosureGroup("查看依据 · \(sources.reduce(0) { $0 + max($1.sessions.count, $1.kind == .capture ? 1 : 0) }) 条") {
                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        ForEach(sources) { item in
                            Button {
                                onSelectItem(item)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                                    Text(item.start.formatted(date: .omitted, time: .shortened))
                                        .font(AppTypography.micro().monospacedDigit())
                                        .foregroundStyle(Color.tertiaryInk)
                                    Text(item.apps.map(\.name).joined(separator: "、"))
                                        .font(AppTypography.metadata())
                                        .foregroundStyle(Color.secondaryInk)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(AppTheme.accent)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, AppSpacing.xs)
                }
                .font(AppTypography.metadata())
                .tint(Color.secondaryInk)
            }
            .padding(.vertical, density.spacing(AppSpacing.sm))
            .padding(.horizontal, density.spacing(AppSpacing.md))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.strongSurface,
                in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous)
                    .stroke(Color.separator.opacity(0.55), lineWidth: 0.7)
            }
        }
    }

    @ViewBuilder
    private func sourceItemRow(_ item: ActivityTimelineItem) -> some View {
        HStack(alignment: .top, spacing: 0) {
            timeLabel(item.start)
            marker(item.kind == .gap ? .gap : (item.kind == .capture ? .capture : .activity))
            if item.kind == .gap {
                HStack {
                    Text("这一段没有记录")
                        .font(AppTypography.secondary())
                        .foregroundStyle(Color.secondaryInk)
                    Spacer()
                    Text(ActivityFormatter.timeRange(item.start, item.end))
                        .font(AppTypography.metadata().monospacedDigit())
                        .foregroundStyle(Color.tertiaryInk)
                }
                .padding(.vertical, AppSpacing.sm)
            } else if item.kind == .capture, let capture = item.capture {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("我写下的一句")
                        .font(AppTypography.micro().weight(.medium))
                    .foregroundStyle(AppTheme.warning)
                    Text(capture.text)
                        .font(.system(size: 16, weight: .regular, design: .serif))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.neutralSoft, in: RoundedRectangle(cornerRadius: AppRadius.panel, style: .continuous))
            }
        }
    }

    private enum MarkerKind { case activity, gap, capture }

    private func marker(_ kind: MarkerKind) -> some View {
        ZStack {
            Rectangle().fill(kind == .gap ? Color.strongSeparator : Color.timelineSpine).frame(width: 1.5)
            switch kind {
            case .activity:
                Circle().fill(Color.surface).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.timelineSpine, lineWidth: 1.3))
                    .overlay(Circle().fill(AppTheme.accent).frame(width: 10, height: 10))
            case .gap:
                Circle().fill(Color.surface).frame(width: 20, height: 20)
                    .overlay(Circle().stroke(AppTheme.neutral.opacity(0.5), lineWidth: 1.4))
            case .capture:
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.neutralSoft).frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(AppTheme.warning.opacity(0.7), lineWidth: 1.2))
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).fill(AppTheme.warning).frame(width: 7, height: 7))
            }
        }
        .frame(width: 28)
        .padding(.top, 9)
        .accessibilityHidden(true)
    }

    private func timeLabel(_ date: Date) -> some View {
        Text(date.formatted(date: .omitted, time: .shortened))
            .font(AppTypography.metadata().monospacedDigit())
            .foregroundStyle(Color.secondaryInk)
            .frame(width: 58, alignment: .trailing)
            .padding(.top, 12)
    }

    private func appTokens(_ items: [ActivityTimelineItem]) -> [TimelineAppToken] {
        struct Key: Hashable { let bundleID: String; let name: String }
        var totals: [Key: TimeInterval] = [:]
        for session in items.flatMap(\.sessions) {
            let key = Key(bundleID: session.bundleID, name: session.appName)
            totals[key, default: 0] += session.duration
        }
        return totals.map { TimelineAppToken(bundleID: $0.key.bundleID, name: $0.key.name, duration: $0.value) }
            .sorted { $0.duration > $1.duration }
    }

    private func appNamesCaption(_ apps: [TimelineAppToken]) -> String {
        let names = apps.prefix(2).map(\.name).joined(separator: " · ")
        guard apps.count > 2 else { return names }
        return names + " · +\(apps.count - 2)"
    }

    @ViewBuilder
    private func appIcons(_ apps: [TimelineAppToken]) -> some View {
        HStack(spacing: -5) {
            ForEach(Array(apps.prefix(2))) { app in
                TimelineAppLogo(token: app)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.surface, lineWidth: 1.2))
            }
            if apps.count > 2 {
                Text("+\(apps.count - 2)")
                    .font(AppTypography.micro().weight(.medium))
                    .foregroundStyle(Color.secondaryInk)
                    .padding(.leading, 7)
            }
        }
        .padding(.top, 1)
        .accessibilityHidden(true)
    }
}

private struct TimelineAppToken: Identifiable {
    let bundleID: String
    let name: String
    let duration: TimeInterval
    var id: String { bundleID.isEmpty ? name : bundleID }
}

private struct TimelineAppLogo: View {
    let token: TimelineAppToken
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Color.tertiaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chip)
            }
        }
        .frame(width: 21, height: 21)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: token.bundleID) {
            guard !token.bundleID.isEmpty,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: token.bundleID) else {
                image = nil
                return
            }
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
