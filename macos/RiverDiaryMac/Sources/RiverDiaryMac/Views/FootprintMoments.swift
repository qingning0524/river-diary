import SwiftUI
import MapKit

enum FootprintMomentScope: String, CaseIterable, Identifiable {
    case all, focus, life, movement
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部片刻"
        case .focus: "学习与创作"
        case .life: "生活"
        case .movement: "运动"
        }
    }
}

/// Presentation over existing evidence. No additional activity, duration or place is inferred.
enum FootprintMoments {
    static func scope(of item: ActivityTimelineItem) -> FootprintMomentScope {
        let explicitLabels = [item.category, item.annotation?.normalized.activityLabel ?? "", item.capture?.tag ?? ""]
        let movementLabels = ["运动", "跑步", "步行", "散步", "徒步", "骑行", "健身", "游泳", "瑜伽"]
        if explicitLabels.contains(where: { label in movementLabels.contains(where: { label.localizedStandardContains($0) }) }) {
            return .movement
        }
        if explicitLabels.contains(where: ActivityClassifier.isFocus) { return .focus }
        return .life
    }

    static func items(in timeline: ActivityTimeline, scope: FootprintMomentScope, query: String,
                      favoritesOnly: Bool = false, pendingOnly: Bool = false,
                      pendingTargets: Set<String> = []) -> [ActivityTimelineItem] {
        let filtering = scope != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || favoritesOnly || pendingOnly
        let source = filtering ? ActivityTimelineEngine.flattenFragments(timeline.foldedItems) : timeline.foldedItems
        return source.filter { item in
            guard item.kind != .gap, item.matches(query: query, category: nil) else { return false }
            guard scope == .all || self.scope(of: item) == scope else { return false }
            guard !favoritesOnly || item.isFavorite else { return false }
            return !pendingOnly || isPending(item, targets: pendingTargets)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start }
    }

    static func isPending(_ item: ActivityTimelineItem, targets: Set<String>) -> Bool {
        var ids = [item.id, item.annotationKey].compactMap { $0 }
        if let marker = item.placeMarker { ids.append(marker.id.uuidString) }
        return item.needsReview || ids.contains(where: targets.contains)
    }

    static func title(_ item: ActivityTimelineItem) -> String {
        if let capture = item.capture {
            let tag = (capture.tag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return tag.isEmpty ? "写下的片刻" : tag
        }
        return item.title
    }

    static func body(_ item: ActivityTimelineItem) -> String {
        item.capture?.text ?? item.evidenceLine
    }

    static func place(_ item: ActivityTimelineItem) -> String? {
        if let name = item.annotation?.normalized.placeName, !name.isEmpty { return name }
        return item.placeMarker?.title
    }

    static func source(_ item: ActivityTimelineItem) -> String {
        if let capture = item.capture { return capture.source }
        if item.placeMarker != nil { return "地点记录" }
        return item.apps.isEmpty ? "活动记录" : item.apps.prefix(2).map(\.name).joined(separator: "、")
    }

    static func symbol(_ item: ActivityTimelineItem) -> String {
        if item.capture != nil { return "square.and.pencil" }
        if item.placeMarker != nil { return "mappin.and.ellipse" }
        switch scope(of: item) {
        case .focus: return "laptopcomputer"
        case .movement: return "figure.walk"
        default: return "leaf"
        }
    }

    struct PlaceStop: Identifiable {
        let item: ActivityTimelineItem
        let name: String
        var id: String { item.id }
        var coordinate: CLLocationCoordinate2D? {
            guard let latitude = item.placeMarker?.latitude, let longitude = item.placeMarker?.longitude,
                  latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    static func places(in timeline: ActivityTimeline) -> [PlaceStop] {
        timeline.items.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }.compactMap { item in
            guard let name = place(item), !name.isEmpty else { return nil }
            return PlaceStop(item: item, name: name)
        }
    }
}

struct FootprintMomentCard: View {
    let item: ActivityTimelineItem
    let pending: Bool
    let selected: Bool
    let onOpen: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: String {
        if pending { return "待确认" }
        if item.capture != nil { return "手动记录" }
        if item.annotation?.isReviewed == true { return "已确认" }
        return item.placeMarker == nil ? "本机记录" : "地点记录"
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 17) {
                HStack(spacing: 10) {
                    RiverIconWell(systemImage: FootprintMoments.symbol(item),
                                  tint: FootprintMoments.scope(of: item) == .movement ? AppTheme.ok : AppTheme.accent, size: 34)
                        .accessibilityHidden(true)
                    Text(item.start.formatted(date: .omitted, time: .shortened)
                         + (item.kind == .activity ? " · " + ActivityFormatter.time(item.duration) : ""))
                        .font(AppTypography.metadata().monospacedDigit()).foregroundStyle(Color.secondaryInk)
                    Spacer(minLength: 8)
                    if item.isFavorite {
                        Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(AppTheme.accent)
                            .accessibilityHidden(true)
                    }
                    StatusBadge(status, tone: pending ? .attention : item.capture != nil || item.annotation?.isReviewed == true ? .positive : .neutral)
                }
                VStack(alignment: .leading, spacing: 9) {
                    Text(FootprintMoments.title(item)).font(AppTypography.sheetTitle()).foregroundStyle(Color.ink).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !FootprintMoments.body(item).isEmpty {
                        Text(FootprintMoments.body(item)).font(AppTypography.secondary()).foregroundStyle(Color.secondaryInk)
                            .lineSpacing(5).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { placeLabel; sourceLabel }
                        VStack(alignment: .leading, spacing: 7) { placeLabel; sourceLabel }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(hovered || selected ? AppTheme.accent : Color.tertiaryInk)
                }.font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
            }
            .padding(23).frame(maxWidth: .infinity, alignment: .leading)
            .riverSoftSurface()
            .overlay(RoundedRectangle(cornerRadius: AppRadius.panel)
                .strokeBorder(hovered || selected ? AppTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.panel))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: AppMotion.quick), value: hovered)
        .accessibilityLabel("查看片刻，\(FootprintMoments.title(item))，\(item.start.formatted(date: .omitted, time: .shortened))，\(status)")
        .accessibilityValue(selected ? "已打开详情" : "")
        .help("查看片刻详情与原始依据")
    }

    @ViewBuilder private var placeLabel: some View {
        if let place = FootprintMoments.place(item) {
            Label(place, systemImage: "mappin.and.ellipse").lineLimit(1)
        }
    }
    private var sourceLabel: some View {
        Label(FootprintMoments.source(item), systemImage: "square.3.layers.3d").lineLimit(1)
    }
}

struct FootprintPlacesOverview: View {
    let stops: [FootprintMoments.PlaceStop]
    let onSelect: (ActivityTimelineItem) -> Void
    let onOpenPlaces: () -> Void

    var body: some View {
        RiverPanel(title: "这一天的地点", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
            VStack(alignment: .leading, spacing: 18) {
                if stops.isEmpty {
                    Text("还没有地点记录")
                        .font(AppTypography.rowTitle()).foregroundStyle(Color.ink)
                    Text("连接地点来源，或在片刻详情里补充地点后，会按时间显示在这里。")
                        .font(AppTypography.metadata()).foregroundStyle(Color.secondaryInk).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if stops.contains(where: { $0.coordinate != nil }) {
                        FootprintPlacesMap(stops: stops, onSelect: onSelect)
                    }
                    Text("按记录时间排列")
                        .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                    ForEach(Array(stops.prefix(8).enumerated()), id: \.element.id) { index, stop in
                        Button { onSelect(stop.item) } label: {
                            HStack(alignment: .top, spacing: 11) {
                                VStack(spacing: 5) {
                                    Circle().fill(AppTheme.accent).frame(width: 7, height: 7)
                                    if index < min(stops.count, 8) - 1 {
                                        Rectangle().fill(Color.separator).frame(width: 1, height: 27)
                                    }
                                }.padding(.top, 5).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(stop.name).font(AppTypography.rowTitle()).foregroundStyle(Color.ink).lineLimit(2)
                                    Text(stop.item.start.formatted(date: .omitted, time: .shortened))
                                        .font(AppTypography.micro().monospacedDigit()).foregroundStyle(Color.secondaryInk)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("查看地点片刻与依据")
                    }
                    Text("地点顺序来自实际记录，不代表已测量的行走路线。")
                        .font(AppTypography.micro()).foregroundStyle(Color.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(stops.isEmpty ? "查看地点与连接" : "全部地点记录", action: onOpenPlaces).linkAction()
                    .font(AppTypography.metadata())
            }
        }
    }
}

private struct FootprintPlacesMap: View {
    let stops: [FootprintMoments.PlaceStop]
    let onSelect: (ActivityTimelineItem) -> Void
    var body: some View {
        Map(interactionModes: [.pan, .zoom]) {
            ForEach(stops) { stop in
                if let coordinate = stop.coordinate {
                    Annotation(stop.name, coordinate: coordinate) {
                        Button { onSelect(stop.item) } label: {
                            Image(systemName: "mappin.circle.fill")
                                .font(.system(size: 24)).foregroundStyle(AppTheme.accent)
                                .padding(4).background(Color.surface, in: Circle())
                        }.buttonStyle(.plain).accessibilityLabel("查看地图记录点，\(stop.name)")
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .frame(height: 160)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.row))
        .accessibilityLabel("实际坐标记录点地图")
    }
}
