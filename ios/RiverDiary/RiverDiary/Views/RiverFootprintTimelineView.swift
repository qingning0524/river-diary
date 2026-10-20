import SwiftUI
import RiverDiaryCore
import UIKit

struct RiverFootprintTimelineView: View {
    @Environment(\.riverTheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let date: Date
    let rows: [IOSActivityRow]
    var searchQuery = ""
    var isPreview = false
    var accessibilityPrefix = "river.footprints.timeline"
    var onOpen: (IOSActivityRow) -> Void = { _ in }
    var canLocate: (IOSActivityRow) -> Bool = { _ in false }
    var onLocate: (IOSActivityRow) -> Void = { _ in }
    var filterSelection: Binding<FootprintFilter>? = nil
    var pendingCount = 0
    var onPending: () -> Void = {}
    @State private var newestFirst = true
    private var filter: FootprintFilter { filterSelection?.wrappedValue ?? .all }
    private var chronology: [IOSActivityRow] { RiverFootprintPresentation.chronology(rows, filter: filter).filter(matchesSearch) }
    private var untimed: [IOSActivityRow] { rows.filter { ["全天", "当天手记"].contains($0.timeLabel ?? "") && filter.matches($0.kind) && matchesSearch($0) } }

    var body: some View {
        let ordered = newestFirst ? Array(chronology.reversed()) : chronology
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("时间线").font(.system(size: 14, weight: .bold))
                Text("共 \(chronology.count) 段生活片段").font(.system(size: 11)).foregroundStyle(theme.secondaryInk)
                Spacer(minLength: 0)
                Button(newestFirst ? "按时间倒序" : "按时间正序") { withAnimation(reduceMotion ? nil : .riverSpring) { newestFirst.toggle() } }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accentText).frame(minHeight: 44)
            }.accessibilityIdentifier("\(accessibilityPrefix).style")
            if pendingCount > 0 {
                Button(action: onPending) {
                    HStack(spacing: 7) {
                        Text("✦").foregroundStyle(.orange)
                        Text("\(pendingCount) 条 AI 理解待确认").fontWeight(.semibold)
                        Spacer(minLength: 0)
                        Text("查看全部 ›").fontWeight(.medium)
                    }.font(.system(size: 11)).foregroundStyle(theme.warning).padding(12)
                        .background(Color(hex: "#FFFBEB").opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: "#FDE68A").opacity(0.55), lineWidth: 0.7))
                }.buttonStyle(.plain)
            }
            if ordered.isEmpty && untimed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(searchQuery.isEmpty ? "生活片段会自动留在这里" : "没有找到相关片段").font(.subheadline.weight(.medium))
                    Text(searchQuery.isEmpty ? "开启记录来源后，River 会按时间整理走过的路与生活片段。" : "换一个词或日期试试。").font(.caption).foregroundStyle(theme.secondaryInk)
                }.padding(16).riverNeumorphic(referenceGradient: true).accessibilityIdentifier("\(accessibilityPrefix).empty")
            }
            VStack(spacing: 20) {
                ForEach(ordered) { row in
                    fragmentCard(row).id(row.id).transition(.opacity)
                        .overlay(alignment: .topLeading) {
                            Text(nodeIcon(row)).font(.system(size: 12)).frame(width: 28, height: 28)
                                .riverNeumorphic(radius: 14).offset(x: -28, y: 12).accessibilityHidden(true)
                        }
                }
            }
            .padding(.leading, 24)
            .background(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1).fill(LinearGradient(colors: [.orange, .yellow, .purple, Color(hex: "#60A5FA"), .cyan], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5).padding(.leading, 9).padding(.vertical, 14).accessibilityHidden(true)
            }
            if !untimed.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 12) { ForEach(untimed) { fragmentCard($0) } }.padding(.top, 12)
                } label: {
                    Label("当日手记与健康 · \(untimed.count) 项", systemImage: "book.closed").font(.caption).foregroundStyle(theme.secondaryInk)
                }.padding(.top, 4)
            }
        }.foregroundStyle(theme.ink).accessibilityIdentifier(accessibilityPrefix)
            .onChange(of: date) { _, _ in newestFirst = true }
    }

    private func fragmentCard(_ row: IOSActivityRow) -> some View {
        RiverIOSPanel(padding: 15, referenceGradient: true) {
            VStack(alignment: .leading, spacing: 10) {
                Button { onOpen(row) } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(displayTitle(row)).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.ink).lineLimit(textSize.isAccessibilitySize ? nil : 2)
                            Spacer(minLength: 0)
                            Text(status(row)).font(.system(size: 10, weight: .medium)).foregroundStyle(row.isInferred ? theme.warning : row.kind == .riverInsight ? .purple : theme.success)
                        }
                        HStack(spacing: 8) {
                            Text(clock(row)).monospacedDigit()
                            if row.kind == .app, let duration = row.duration, duration.isFinite, duration > 0 { Text("· " + RiverDayReadingMath.timeText(seconds: duration)) }
                        }.font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryInk)
                    }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).contentShape(Rectangle())
                }.riverTactile().accessibilityIdentifier("\(accessibilityPrefix).record.\(row.id)")
                    .accessibilityHint("查看完整片段和原始依据")
                if let detail = displayDetail(row) {
                    Text(detail).font(.system(size: 12)).foregroundStyle(theme.secondaryInk).lineSpacing(3)
                        .lineLimit(textSize.isAccessibilitySize ? nil : 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(row.isInferred ? 10 : 0)
                        .background { if row.isInferred { Color.clear.riverNeumorphic(inset: true, radius: 12) } }
                        .accessibilityIdentifier("\(accessibilityPrefix).body.\(row.id)")
                }
                RiverTimelinePhoto(row: row)
                if (row.kind != .app && row.duration.map({ $0.isFinite && $0 > 0 }) == true) || canLocate(row) || row.isInferred {
                    HStack(spacing: 8) {
                        if row.kind != .app, let duration = row.duration, duration.isFinite, duration > 0 {
                            Text((row.isInferred ? "约 " : "") + RiverDayReadingMath.timeText(seconds: duration))
                                .font(.system(size: 10)).foregroundStyle(theme.secondaryInk).padding(.horizontal, 8).padding(.vertical, 5).riverNeumorphic(radius: 11)
                        }
                        Spacer(minLength: 0)
                        if canLocate(row) {
                            Button { onLocate(row) } label: { Label("地点", systemImage: "mappin.and.ellipse").font(.system(size: 11)).frame(minHeight: 36) }
                                .foregroundStyle(theme.secondaryInk).accessibilityIdentifier("\(accessibilityPrefix).locate.\(row.id)")
                        }
                        if row.isInferred { Button("核对理解 ›") { onOpen(row) }.font(.system(size: 11, weight: .medium)).foregroundStyle(theme.accentText).frame(minHeight: 36) }
                    }
                }
            }
        }
    }
    private func displayTitle(_ row: IOSActivityRow) -> String { row.kind == .note ? "随手记 · 生活片段" : row.title }
    private func displayDetail(_ row: IOSActivityRow) -> String? {
        if row.kind == .note { return row.title }
        return row.detail.isEmpty || ["应用活动记录", "你写下的记录"].contains(row.detail) ? nil : row.detail
    }
    private func status(_ row: IOSActivityRow) -> String {
        if row.isInferred { return "推测 · 可核对" }
        if row.kind == .riverInsight { return "AI 已整理" }
        return row.kind == .note ? "手动补充" : "✓ 已记录"
    }
    private func clock(_ row: IOSActivityRow) -> String { row.timeLabel ?? row.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
    private func matchesSearch(_ row: IOSActivityRow) -> Bool {
        let term = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || [row.title, row.detail, row.sourceLabel].contains { $0.localizedCaseInsensitiveContains(term) }
    }
    private func nodeIcon(_ row: IOSActivityRow) -> String {
        if row.title.localizedCaseInsensitiveContains("coffee") || row.title.contains("咖啡") { return "☕" }
        switch row.kind { case .app: return "📱"; case .place: return "📍"; case .health: return "🚶"; case .photo: return "🖼"; case .note: return "✍️"; case .riverInsight: return "✨"; case .other: return "🌿" }
    }
}

/// Display only a photo that is actually linked to the event and available under Photos permission.
private struct RiverTimelinePhoto: View {
    @EnvironmentObject private var node: RiverNodeStore
    let row: IOSActivityRow
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 155).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .accessibilityLabel("与这段生活记录关联的本机照片")
            }
        }.task(id: row.id) {
            thumbnail = nil
            guard let database = node.database, let analyzer = node.photoAnalyzer else { return }
            let events = (try? database.events(ids: row.eventIDs)) ?? []
            for event in events where event.kind == "media.photoObservation" {
                guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload), let token = payload.mediaGroupID else { continue }
                if let image = await analyzer.localThumbnail(for: token, capturedAt: event.observedAt) { if !Task.isCancelled { thumbnail = image }; return }
            }
        }
    }
}
enum FootprintFilter: String, CaseIterable, Identifiable {
    case all, app, place, photo, note, health
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部"; case .app: "应用"; case .place: "地点"; case .photo: "影像"; case .note: "文字"; case .health: "健康" } }
    func matches(_ kind: IOSActivityRow.Kind) -> Bool {
        switch self { case .all: true; case .app: kind == .app; case .place: kind == .place; case .photo: kind == .photo; case .note: kind == .note; case .health: kind == .health }
    }
}

