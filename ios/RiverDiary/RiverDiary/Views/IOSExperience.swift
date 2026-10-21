import Combine
import CoreLocation
import Foundation
import RiverDiaryCore
import SwiftUI

enum RiverAppTab: String, Hashable {
    case timeline
    case footprints
    case confirmations
    case river
    case me
}

enum RiverAppRoute: Hashable {
    case activity(UUID)
    case place(String)
    case confirmations
    case memory(UUID)
    case settings
}

struct RiverJournalPresentation: Identifiable {
    let id = UUID()
    let date: Date
}

@MainActor
final class RiverAppCoordinator: ObservableObject {
    @Published var selectedTab: RiverAppTab = .timeline
    @Published var riverComposerFocused = false
    @Published var selectedDate = Calendar.current.startOfDay(for: .now)
    @Published var timelinePath: [RiverAppRoute] = []
    @Published var footprintsPath: [RiverAppRoute] = []
    @Published var confirmationsPath: [RiverAppRoute] = []
    @Published var riverPath: [RiverAppRoute] = []
    @Published var mePath: [RiverAppRoute] = []
    @Published var journalPresentation: RiverJournalPresentation?
    @Published var journalSaveRevision: UInt64 = 0
    private var lastSystemDay = Calendar.current.startOfDay(for: Date())

    func followDayBoundaryIfNeeded() {
        let today = Calendar.current.startOfDay(for: Date())
        if selectedDate == lastSystemDay { selectedDate = today }
        lastSystemDay = today
    }

    func presentJournal(on date: Date) {
        journalPresentation = RiverJournalPresentation(date: Calendar.current.startOfDay(for: date))
    }

    func openTimeline(eventID: UUID, date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        timelinePath.append(.activity(eventID))
        selectedTab = .timeline
    }

    func openTimeline(day date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        timelinePath.removeAll()
        selectedTab = .timeline
    }

    func openPlace(_ placeID: String, date: Date? = nil) {
        if let date { selectedDate = Calendar.current.startOfDay(for: date) }
        selectedPlaceRoute(placeID)
    }

    private func selectedPlaceRoute(_ placeID: String) {
        footprintsPath.append(.place(placeID))
        selectedTab = .footprints
    }

    func openConfirmations() {
        selectedTab = .confirmations
    }

    func returnToRiver() {
        if riverPath.last == .confirmations {
            riverPath.removeLast()
        } else {
            selectedTab = .river
        }
    }

    func openFootprints(day date: Date? = nil) {
        if let date { selectedDate = Calendar.current.startOfDay(for: date) }
        footprintsPath.removeAll()
        selectedTab = .footprints
    }

    func openMemory(_ id: UUID) {
        mePath.append(.memory(id))
        selectedTab = .me
    }
}

struct RiverIOSPanel<Content: View>: View {
    @Environment(\.riverTheme) private var theme
    var padding: CGFloat = 16
    var fill: Color? = nil
    var referenceGradient = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .multilineTextAlignment(.leading)
            .padding(padding)
            .foregroundStyle(theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .riverNeumorphic(radius: theme.panelRadius, referenceGradient: referenceGradient)
    }
}

struct RiverIOSPageHeader: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(theme.titleFont).foregroundStyle(theme.ink).accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(theme.secondaryInk).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 16).padding(.bottom, 8)
    }
}

struct RiverIOSSectionHeading: View {
    @Environment(\.riverTheme) private var theme
    let title: String
    var detail: String? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.sectionFont)
                    .accessibilityAddTraits(.isHeader)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(theme.sectionFont)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryInk)
                }
            }
        }
    }
}

struct RiverIOSDatabaseUnavailablePanel: View {
    @Environment(\.riverTheme) private var theme
    let message: String?
    let onRetry: () -> Void

    var body: some View {
        RiverIOSPanel {
            VStack(alignment: .leading, spacing: 10) {
                Label("本机记录暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.headline)
                Text(message ?? "本机记录库尚未准备好。你可以重试；已保存内容不会因此被清除。")
                    .font(.subheadline)
                    .foregroundStyle(theme.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("重试") { onRetry() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct RiverIOSRouteDestination: View {
    @Environment(\.riverTheme) private var theme
    let route: RiverAppRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .activity(let id): RiverActivityDetailView(eventID: id)
        case .place(let id): RiverPlaceDetailView(placeID: id)
        case .confirmations: RiverConfirmationsView()
        case .memory(let id): RiverMemoryDetailView(memoryID: id)
        case .settings: SettingsView(embedded: true)
        }
    }
}

struct IOSActivityRow: Identifiable, Hashable {
    enum Kind: Hashable { case app, place, health, photo, note, riverInsight, other }

    let id: String
    let date: Date
    let title: String
    let detail: String
    let sourceLabel: String
    let kind: Kind
    let eventIDs: [UUID]
    let placeID: String?
    let duration: TimeInterval?
    let isInferred: Bool
    var timeLabel: String? = nil

    var routeEventID: UUID? { eventIDs.first }
}

private struct IOSSemanticTimelineDigest: Decodable {
    struct Segment: Decodable {
        let candidateIDs: [String]
        let title: String
        let summary: String
        let evidenceRefs: [String]?
        let start: Date?
        let end: Date?
    }

    let dayKey: String
    let segments: [Segment]
}

struct RiverFootprintStop: Identifiable {
    let id: String
    let latitude: Double
    let longitude: Double
    let title: String
    let subtitle: String
    let horizontalAccuracyMeters: Double?
    let eventIDs: [UUID]
    let firstSeen: Date
    let lastSeen: Date
    let placeID: String?
    let isNameCandidate: Bool

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var displayTitle: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "未命名地点" { return "待确认地点" }
        return isNameCandidate ? "可能是 \(title)" : title
    }
}

enum RiverIOSProjection {
    private struct TimelineRowCacheEntry {
        let dataRevision: UInt64
        let rows: [IOSActivityRow]
    }

    @MainActor private static var timelineRowCache: [ObjectIdentifier: [String: TimelineRowCacheEntry]] = [:]

    static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor
    static func timelineRows(database: RiverLocalDatabase, date: Date) -> [IOSActivityRow] {
        let cacheKey = ObjectIdentifier(database)
        let day = dayKey(date)
        let revision = database.dataRevision
        if let cached = timelineRowCache[cacheKey]?[day], cached.dataRevision == revision {
            return cached.rows
        }

        let rows = computeTimelineRows(database: database, date: date)
        var perDatabase = timelineRowCache[cacheKey] ?? [:]
        perDatabase[day] = TimelineRowCacheEntry(dataRevision: database.dataRevision, rows: rows)
        if perDatabase.count > 14 {
            for oldDay in perDatabase.keys.sorted().prefix(perDatabase.count - 14) {
                perDatabase.removeValue(forKey: oldDay)
            }
        }
        timelineRowCache[cacheKey] = perDatabase
        if timelineRowCache.count > 4, let oldDatabase = timelineRowCache.keys.first(where: { $0 != cacheKey }) {
            timelineRowCache.removeValue(forKey: oldDatabase)
        }
        return rows
    }

    @MainActor
    private static func computeTimelineRows(database: RiverLocalDatabase, date: Date) -> [IOSActivityRow] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let dayEvents = database.timelineEvents.filter { $0.event.observedAt >= dayStart && $0.event.observedAt < dayEnd }
        let eventsByID = Dictionary(uniqueKeysWithValues: dayEvents.map { ($0.id, $0) })
        let sessions = database.timelineSessions.filter { session in
            let end = session.end ?? Date()
            return session.start < dayEnd && end >= dayStart
        }
        var consumedIDs = Set<UUID>()
        var rows: [IOSActivityRow] = SessionFusionEngine.fuse(sessions).map { group in
            let session = group.primary
            let allSessions = [group.primary] + group.secondary
            let eventIDs = allSessions.flatMap(\.evidenceEventIDs)
            consumedIDs.formUnion(eventIDs)
            let firstPayload = group.primary.evidenceEventIDs.compactMap { eventsByID[$0]?.payload }.first
            let title = session.displayName.isEmpty ? "应用活动" : "使用 \(session.displayName)"
            let windowTitle = firstPayload?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let otherActivities = group.secondary.map { "\($0.displayName)（\($0.originDeviceID.rawValue.hasPrefix("mac") ? "Mac" : "iPhone")）" }
            let baseDetail = windowTitle.isEmpty ? "应用活动记录" : windowTitle
            let detail = otherActivities.isEmpty
                ? baseDetail
                : "\(baseDetail) · 同时记录：\(otherActivities.joined(separator: "、"))"
            let devices = Set(allSessions.map { $0.originDeviceID.rawValue.hasPrefix("mac") ? "Mac" : "iPhone" })
            return IOSActivityRow(
                id: "session:\(session.id)",
                date: max(session.start, dayStart),
                title: title,
                detail: detail,
                sourceLabel: devices.count > 1 ? "iPhone 与 Mac 的重叠活动" : (devices.first == "Mac" ? "Mac 应用活动" : "iPhone 应用活动"),
                kind: .app,
                eventIDs: eventIDs,
                placeID: nil,
                duration: session.duration,
                isInferred: session.quality == .inferred || session.end == nil
            )
        }

        let latestSleepSnapshot = dayEvents
            .filter { $0.event.kind == "health.sleep.snapshot" }
            .max { lhs, rhs in
                lhs.event.recordedAt == rhs.event.recordedAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.event.recordedAt < rhs.event.recordedAt
            }
        let latestExerciseSnapshot = dayEvents
            .filter { $0.event.kind == "health.exercise.snapshot" }
            .max { lhs, rhs in
                lhs.event.recordedAt == rhs.event.recordedAt
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.event.recordedAt < rhs.event.recordedAt
            }
        let healthSummaryEvents = [latestSleepSnapshot, latestExerciseSnapshot].compactMap { $0 }
        if !healthSummaryEvents.isEmpty {
            let sleep = latestSleepSnapshot?.payload.metrics?.sleepHours
                .map { "睡眠 \(String(format: "%.1f", $0)) 小时" }
            let exerciseMetrics = latestExerciseSnapshot?.payload.metrics
            let exercise = [
                exerciseMetrics?.steps.map { "步数 \($0.formatted())" },
                exerciseMetrics?.distanceKm.map { String(format: "%.1f 公里", $0) },
                exerciseMetrics?.activeEnergyKcal.map { "活动能量 \(Int($0.rounded())) 千卡" }
            ].compactMap { $0 }.joined(separator: " · ")
            let detail = [sleep, exercise.isEmpty ? nil : exercise].compactMap { $0 }.joined(separator: " · ")
            rows.append(IOSActivityRow(
                id: "health-day-summary:\(dayKey(dayStart))",
                date: dayStart,
                title: "全天健康汇总",
                detail: detail,
                sourceLabel: "Apple 健康 · 全天汇总",
                kind: .health,
                eventIDs: healthSummaryEvents.map(\.id),
                placeID: nil,
                duration: nil,
                isInferred: false,
                timeLabel: "全天"
            ))
        }

        let latestContexts = Dictionary(grouping: dayEvents.filter { $0.event.kind == "dayContextSnapshot" }, by: { item in
            item.payload.contextJSON.flatMap(DayContextSnapshot.decodeJSON)?.deviceID ?? item.event.originDeviceID.rawValue
        }).values.compactMap { items in
            items.max { $0.event.recordedAt < $1.event.recordedAt }
        }
        for item in latestContexts {
            guard let json = item.payload.contextJSON,
                  let snapshot = DayContextSnapshot.decodeJSON(json),
                  !snapshot.isEmpty,
                  snapshot.deviceID != database.deviceID.rawValue else { continue }
            rows.append(IOSActivityRow(
                id: "day-context:\(snapshot.deviceID)",
                date: snapshot.generatedAt,
                title: "\(snapshot.deviceName) 的一天",
                detail: snapshot.searchText,
                sourceLabel: "\(snapshot.deviceName) · 设备上下文",
                kind: .other,
                eventIDs: [item.id],
                placeID: nil,
                duration: nil,
                isInferred: false
            ))
        }

        let rawSourceLabels = ["chrome": "浏览器", "notes": "备忘录", "markdown": "Markdown", "kindle": "Kindle"]
        let rawGroups = Dictionary(grouping: dayEvents.filter { rawSourceLabels[$0.event.source] != nil }) { $0.event.source }
        for (source, items) in rawGroups {
            let sorted = items.sorted { $0.event.observedAt < $1.event.observedAt }
            let label = rawSourceLabels[source] ?? source
            let snippets = sorted.prefix(6).compactMap { item -> String? in
                let title = item.payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = item.payload.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let piece: String
                if title.isEmpty {
                    piece = String(text.prefix(120))
                } else if title == text || text.isEmpty {
                    piece = String(title.prefix(120))
                } else {
                    piece = "\(title)：\(String(text.prefix(80)))"
                }
                return piece.isEmpty ? nil : piece
            }
            let more = sorted.count > snippets.count ? " 等 \(sorted.count) 条" : ""
            rows.append(IOSActivityRow(
                id: "raw-source:\(source):\(dayKey(dayStart))",
                date: sorted.first?.event.observedAt ?? dayStart,
                title: "Mac \(label)（\(sorted.count)）",
                detail: snippets.joined(separator: " · ") + more,
                sourceLabel: "Mac · \(label)原始记录",
                kind: .other,
                eventIDs: sorted.map(\.id),
                placeID: nil,
                duration: nil,
                isInferred: false
            ))
        }

        for item in dayEvents where !consumedIDs.contains(item.id) {
            let payload = item.payload
            let kind: IOSActivityRow.Kind
            let title: String
            let detail: String
            if item.event.kind.hasPrefix("location.") {
                // Location observations are projected below as a stay or a
                // compact route. Raw arrival/significant-change rows created
                // one visually meaningless item per sensor callback.
                continue
            } else if item.event.kind == "media.photoObservation" || item.event.kind == "media.analysis"
                || item.event.kind == "meal.estimate" {
                // Photo observations and meal estimates are grouped with a
                // nearby stay or a compact photo moment below.
                continue
            } else if item.event.kind == "mobility.activity" || item.event.kind == "health.exercise.interval" {
                continue
            } else if item.event.kind == "health.sleep.snapshot" || item.event.kind == "health.exercise.snapshot" {
                // These are rolling daily totals, not events that happened at midnight.
                continue
            } else if item.event.kind == "dayContextSnapshot" {
                continue
            } else if ["chrome", "notes", "markdown", "kindle"].contains(item.event.source) {
                // Raw detail events are evidence for search/export; the phone
                // reads the coalesced DayContext card instead of flooding the
                // timeline with hundreds of browser rows.
                continue
            } else if item.event.kind.hasPrefix("health.") || payload.metrics != nil {
                kind = .health
                title = healthTitle(payload.metrics)
                detail = healthDetail(payload.metrics)
            } else if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                kind = .note
                title = text
                detail = "你写下的记录"
            } else if let app = payload.appName?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
                kind = .app
                title = "使用 \(app)"
                detail = payload.windowTitle ?? "应用活动记录"
            } else {
                kind = .other
                title = "一条生活线索"
                detail = sourceLabel(item.event.source)
            }
            rows.append(IOSActivityRow(
                id: "event:\(item.id.uuidString)",
                date: item.event.observedAt,
                title: title,
                detail: detail,
                sourceLabel: sourceLabel(item.event.source),
                kind: kind,
                eventIDs: [item.id],
                placeID: placeID(for: payload, places: database.places),
                duration: nil,
                isInferred: false
            ))
        }
        rows.append(contentsOf: locationRows(database: database, events: dayEvents))
        rows.append(contentsOf: timelineInsights(database: database, date: date))
        return rows.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.id < $1.id
        }
    }

    @MainActor
    private static func locationRows(database: RiverLocalDatabase, events: [RiverTimelineEvent]) -> [IOSActivityRow] {
        let locations = events.filter { $0.event.kind.hasPrefix("location.") }
            .sorted { $0.event.observedAt < $1.event.observedAt }
        let photoAnalyses = Dictionary(grouping: events.filter {
            $0.event.kind == "media.analysis" || $0.event.kind == "meal.estimate"
        }, by: { $0.payload.mediaGroupID ?? $0.id.uuidString })
            .values.compactMap { $0.max(by: { $0.event.recordedAt < $1.event.recordedAt }) }
        let analyzedPhotoTokens = Set(photoAnalyses.flatMap { $0.payload.mediaSourceTokens ?? [] })
        let localPhotos = events.filter { $0.event.kind == "media.photoObservation" }
            .filter { !analyzedPhotoTokens.contains($0.payload.mediaGroupID ?? "") }
        let photos = (localPhotos + photoAnalyses).sorted { $0.event.observedAt < $1.event.observedAt }
        let mobility = events.filter { $0.event.kind == "mobility.activity" }
            .sorted { $0.event.observedAt < $1.event.observedAt }
        guard !locations.isEmpty || !photos.isEmpty || !mobility.isEmpty else { return [] }

        let locationPlaceIDs = Dictionary(uniqueKeysWithValues: locations.compactMap { item in
            placeID(for: item.payload, places: database.places).map { (item.id, $0) }
        })
        let photoPlaceIDs = Dictionary(uniqueKeysWithValues: photos.compactMap { item in
            placeID(for: item.payload, places: database.places).map { (item.id, $0) }
        })
        var byPlace: [String: [RiverTimelineEvent]] = [:]
        var unvisited: [RiverTimelineEvent] = []
        for item in locations {
            let placeID = locationPlaceIDs[item.id]
            if let placeID { byPlace[placeID, default: []].append(item) }
            unvisited.append(item)
        }

        let pendingPlaces = Dictionary(uniqueKeysWithValues: database.sharedUserRecords.compactMap { record -> (String, RiverPendingConfirmationContent)? in
            guard record.kind == .pendingConfirmation, record.status == "pending",
                  let content = record.pendingConfirmationContent,
                  content.targetType == "place", let placeID = content.targetID,
                  (content.choices?.count ?? 0) >= 2 else { return nil }
            return (placeID, content)
        })
        var consumedLocationIDs = Set<UUID>()
        var consumedPhotoIDs = Set<UUID>()
        var rows: [IOSActivityRow] = []

        let orderedMobility = mobility.filter { $0.payload.movementMode != nil }
        var movementSpans: [(start: RiverTimelineEvent, end: RiverTimelineEvent, mode: String, duration: TimeInterval)] = []
        if orderedMobility.count > 1 {
            for index in 0..<(orderedMobility.count - 1) {
                let start = orderedMobility[index]
                let end = orderedMobility[index + 1]
                guard let mode = start.payload.movementMode,
                      let nextMode = end.payload.movementMode,
                      !["stationary", "unknown"].contains(mode), nextMode != mode else { continue }
                let duration = end.event.observedAt.timeIntervalSince(start.event.observedAt)
                guard duration >= 2 * 60 else { continue }
                movementSpans.append((start, end, mode, duration))
            }
        }
        let locationCoveredByMotion = Set(locations.filter { location in
            movementSpans.contains {
                location.event.observedAt >= $0.start.event.observedAt
                    && location.event.observedAt <= $0.end.event.observedAt
            }
        }.map(\.id))

        for place in database.places {
            let evidence = byPlace[place.id] ?? []
            let arrivals = evidence.filter { $0.event.kind == "location.visit.arrival" }
            guard !arrivals.isEmpty else { continue }
            consumedLocationIDs.formUnion(evidence.map(\.id))

            var openArrival: [String: Date] = [:]
            var duration: TimeInterval = 0
            for item in evidence.sorted(by: { $0.event.observedAt < $1.event.observedAt }) {
                let device = item.event.originDeviceID.rawValue
                if item.event.kind == "location.visit.arrival" {
                    openArrival[device] = item.event.observedAt
                } else if item.event.kind == "location.visit.departure",
                          let start = openArrival.removeValue(forKey: device) {
                    duration += max(0, item.event.observedAt.timeIntervalSince(start))
                }
            }
            let content = pendingPlaces[place.id]
            let ambiguous = content?.choices?.isEmpty == false
            let firstArrival = arrivals.map(\.event.observedAt).min() ?? place.firstSeen
            let lastDeparture = evidence.filter { $0.event.kind == "location.visit.departure" }
                .map(\.event.observedAt).max() ?? firstArrival.addingTimeInterval(90 * 60)
            let attachedPhotos = photos.filter { photo in
                if photoPlaceIDs[photo.id] == place.id { return true }
                return photo.event.observedAt >= firstArrival.addingTimeInterval(-10 * 60)
                    && photo.event.observedAt <= lastDeparture.addingTimeInterval(10 * 60)
            }
            consumedPhotoIDs.formUnion(attachedPhotos.map(\.id))
            let displayPlace = place.userDefinedName ?? place.mapName
            let title: String
            if ambiguous {
                title = "附近停留 · 商户待选"
            } else if let displayPlace, !displayPlace.isEmpty {
                title = place.isUserConfirmed ? "到访 \(displayPlace)" : "在 \(displayPlace) 附近停留"
            } else {
                title = "附近停留"
            }
            let detail: String
            if ambiguous {
                let choices = (content?.choices ?? []).prefix(4).map(\.choiceLabel)
                let nearby = choices.isEmpty ? "附近识别到多家商户" : "附近有：\(choices.joined(separator: "、"))"
                detail = "\(nearby)；在 River 的确认中心选定名称后，这里会同步更新。"
            } else if duration > 0 {
                detail = "\(arrivals.count) 次到访线索 · 停留约 \(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"
            } else if !openArrival.isEmpty {
                detail = place.mapAddress ?? "仍在停留；离开后再整理时长。"
            } else {
                detail = place.mapAddress ?? "位置到访记录"
            }
            let photoSummary = attachedPhotos.compactMap { $0.payload.mediaSummary }.first
            let mealEstimate = attachedPhotos.first(where: { $0.event.kind == "meal.estimate" })?.payload
            let enrichedDetail = [
                detail,
                photoSummary.map { "照片：\($0)" },
                mealEstimate.flatMap { lowerUpperDescription($0) }
            ].compactMap { $0 }.joined(separator: " · ")
            rows.append(IOSActivityRow(
                id: "location-stay:\(place.id)",
                date: arrivals.first?.event.observedAt ?? place.firstSeen,
                title: title,
                detail: enrichedDetail,
                sourceLabel: place.isUserConfirmed ? "你确认的地点" : "位置与地图线索",
                kind: .place,
                eventIDs: evidence.map(\.id) + attachedPhotos.map(\.id),
                placeID: place.id,
                duration: duration > 0 ? duration : nil,
                isInferred: !place.isUserConfirmed,
            ))
        }

        // Significant-location updates describe a route, not separate visits.
        // Keep a small number of movement summaries and leave raw points in
        // Footprints for people who want to inspect the full trace.
        var segment: [RiverTimelineEvent] = []
        func appendSegment() {
            guard segment.count >= 2,
                  let first = segment.first, let last = segment.last else { segment.removeAll(); return }
            let ids = segment.map(\.id)
            let span = max(0, last.event.observedAt.timeIntervalSince(first.event.observedAt))
            rows.append(IOSActivityRow(
                id: "location-route:\(first.id.uuidString):\(last.id.uuidString)",
                date: first.event.observedAt,
                title: "途中移动记录",
                detail: "合并了 \(segment.count) 个位置变化；出行方式暂时无法确认。",
                sourceLabel: "位置轨迹",
                kind: .place,
                eventIDs: ids,
                placeID: nil,
                duration: span > 0 ? span : nil,
                isInferred: true
            ))
            consumedLocationIDs.formUnion(ids)
            segment.removeAll()
        }
        for item in unvisited where !consumedLocationIDs.contains(item.id)
            && !locationCoveredByMotion.contains(item.id) {
            if let last = segment.last,
               item.event.observedAt.timeIntervalSince(last.event.observedAt) > 20 * 60 {
                appendSegment()
            }
            segment.append(item)
        }
        appendSegment()

        var photoGroup: [RiverTimelineEvent] = []
        func appendPhotoGroup() {
            guard let first = photoGroup.first else { return }
            let ids = photoGroup.map(\.id)
            let categories = Set(photoGroup.compactMap { $0.payload.mediaCategory })
            let category = categories.count == 1 ? categories.first : nil
            let title = category == "food" ? "餐食照片" : category == "landmark" ? "景点照片" : "照片记录"
            let summaries = photoGroup.compactMap { $0.payload.mediaSummary }
            let count = photoGroup.reduce(0) { total, event in
                total + (event.payload.photoCount ?? 1)
            }
            let mealEstimate = photoGroup.first(where: { $0.event.kind == "meal.estimate" })?.payload
            let detail = [
                "\(count) 张照片",
                summaries.last.map { "\($0)" },
                mealEstimate.flatMap { lowerUpperDescription($0) }
            ].compactMap { $0 }.joined(separator: " · ")
            let last = photoGroup.last ?? first
            rows.append(IOSActivityRow(
                id: "photo-moment:\(first.id.uuidString):\(last.id.uuidString)",
                date: first.event.observedAt,
                title: title,
                detail: detail,
                sourceLabel: "本机照片线索",
                kind: .photo,
                eventIDs: ids,
                placeID: nil,
                duration: last.event.observedAt.timeIntervalSince(first.event.observedAt),
                isInferred: true
            ))
            consumedPhotoIDs.formUnion(ids)
            photoGroup.removeAll()
        }
        for photo in photos where !consumedPhotoIDs.contains(photo.id) {
            if let last = photoGroup.last,
               photo.event.observedAt.timeIntervalSince(last.event.observedAt) > 20 * 60 {
                appendPhotoGroup()
            }
            photoGroup.append(photo)
        }
        appendPhotoGroup()

        for movement in movementSpans {
            let current = movement.start
            let next = movement.end
            let mode = movement.mode
            let span = movement.duration
            let intervalEvidence = locations.filter {
                $0.event.observedAt >= current.event.observedAt && $0.event.observedAt <= next.event.observedAt
            }
            let relatedPhotos = photos.filter {
                $0.event.observedAt >= current.event.observedAt && $0.event.observedAt <= next.event.observedAt
            }
            let label = IPhoneMotionCollector.label(for: mode)
            let steps = healthSteps(from: events, start: current.event.observedAt, end: next.event.observedAt)
            let detail = [
                "\(label)约 \(Duration.seconds(span).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))",
                steps.map { "约 \($0.formatted()) 步" },
                relatedPhotos.isEmpty ? nil : "沿途拍了 \(relatedPhotos.reduce(0) { $0 + ($1.payload.photoCount ?? 1) } ) 张照片"
            ].compactMap { $0 }.joined(separator: " · ")
            rows.append(IOSActivityRow(
                id: "movement:\(current.id.uuidString):\(next.id.uuidString)",
                date: current.event.observedAt,
                title: mode == "walking" ? "散步" : mode == "running" ? "跑步" : mode == "cycling" ? "骑行" : "乘车",
                detail: detail,
                sourceLabel: "运动与位置记录",
                kind: .place,
                eventIDs: [current.id, next.id] + intervalEvidence.map(\.id) + relatedPhotos.map(\.id),
                placeID: nil,
                duration: span,
                isInferred: current.payload.movementConfidence != "high"
            ))
        }
        return rows
    }

    private static func lowerUpperDescription(_ payload: RiverEventPayload) -> String? {
        guard let lower = payload.mealCaloriesLowerBound, let upper = payload.mealCaloriesUpperBound else { return nil }
        return "照片估算 \(lower)–\(upper) 千卡\(payload.mealEstimateNote.map { "（\($0)）" } ?? "")"
    }

    private static func healthSteps(from events: [RiverTimelineEvent], start: Date, end: Date) -> Int? {
        let samples = events.filter {
            $0.event.kind == "health.exercise.interval"
                && $0.event.observedAt < end
                && ($0.payload.intervalEnd ?? $0.event.observedAt) > start
        }
        guard !samples.isEmpty else { return nil }
        let newestPerInterval = Dictionary(grouping: samples) {
            Int($0.event.observedAt.timeIntervalSince1970 / 900)
        }.values.compactMap { $0.max(by: { $0.event.recordedAt < $1.event.recordedAt }) }
        let weighted = newestPerInterval.compactMap { sample -> Double? in
            guard let steps = sample.payload.metrics?.steps else { return nil }
            let sampleEnd = sample.payload.intervalEnd ?? sample.event.observedAt.addingTimeInterval(15 * 60)
            let overlap = max(0, min(end, sampleEnd).timeIntervalSince(max(start, sample.event.observedAt)))
            let duration = sampleEnd.timeIntervalSince(sample.event.observedAt)
            guard overlap > 0, duration > 0 else { return nil }
            return Double(steps) * min(1, overlap / duration)
        }
        guard !weighted.isEmpty else { return nil }
        return Int(weighted.reduce(0, +).rounded())
    }

    @MainActor
    static func timelineInsights(database: RiverLocalDatabase, date: Date) -> [IOSActivityRow] {
        let dayKey = dayKey(date)
        guard let artifacts = try? database.canonicalArtifactRevisions(),
              let artifact = artifacts.filter({
                  $0.kind == .semanticTimeline && $0.logicalKey.hasSuffix("|d-\(dayKey)") && $0.status != .superseded
              }).max(by: { $0.clock == $1.clock ? $0.id < $1.id : $0.clock < $1.clock }),
              artifact.status != .superseded,
              let raw = String(data: artifact.content, encoding: .utf8),
              let digest = try? JSONDecoder().decode(IOSSemanticTimelineDigest.self, from: Data(raw.utf8)),
              digest.dayKey == dayKey else { return [] }

        let dayEventIDs = Set(database.timelineEvents.map(\.id))
        return digest.segments.compactMap { segment in
            let eventIDs = Array(Set((segment.evidenceRefs ?? []).compactMap(eventID(from:)).filter(dayEventIDs.contains)))
            let events = database.timelineEvents.filter { eventIDs.contains($0.id) }.sorted {
                $0.event.observedAt < $1.event.observedAt
            }
            let title = segment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = segment.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let firstEvent = events.first, let lastEvent = events.last,
                  !segment.candidateIDs.isEmpty,
                  (2...120).contains(title.count), !summary.isEmpty, summary.count <= 220 else { return nil }
            let start = segment.start ?? firstEvent.event.observedAt
            let end = segment.end ?? lastEvent.event.observedAt
            let dayStart = Calendar.current.startOfDay(for: date)
            let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
            guard end >= start, start < dayEnd, end >= dayStart else { return nil }
            let statusLabel: String
            switch artifact.status {
            case .stale: statusLabel = "River 暂定理解 · 依据有更新"
            case .provisional: statusLabel = "River 暂定理解 · 等待其他设备核对"
            case .current: statusLabel = "River 暂定理解"
            case .superseded: return nil
            }
            return IOSActivityRow(
                id: "insight:\(artifact.id):\(segment.candidateIDs.joined(separator: "|"))",
                date: max(start, dayStart),
                title: title,
                detail: summary,
                sourceLabel: statusLabel,
                kind: .riverInsight,
                eventIDs: events.map(\.id),
                placeID: nil,
                duration: end.timeIntervalSince(start),
                isInferred: false
            )
        }
    }

    private static func eventID(from evidenceRef: String) -> UUID? {
        guard let separator = evidenceRef.firstIndex(of: ":") else { return nil }
        let type = String(evidenceRef[..<separator])
        guard type == "raw" || type == "location" || type == "event" else { return nil }
        return UUID(uuidString: String(evidenceRef[evidenceRef.index(after: separator)...]))
    }

    static func footprintStops(events: [RiverTimelineEvent], places: [RiverPlace]) -> [RiverFootprintStop] {
        struct Draft {
            var coordinates: [(Double, Double)]
            var events: [RiverTimelineEvent]
        }
        let locationEvents = events.filter {
            $0.event.kind.hasPrefix("location.") && $0.payload.latitude != nil && $0.payload.longitude != nil
        }.sorted { $0.event.observedAt < $1.event.observedAt }
        var drafts: [Draft] = []
        for event in locationEvents {
            guard let latitude = event.payload.latitude, let longitude = event.payload.longitude else { continue }
            let lastDraft = drafts.indices.last
            let previous = lastDraft.flatMap { drafts[$0].events.last }
            let startsNewVisit: Bool
            if let lastDraft, let previous {
                let gap = event.event.observedAt.timeIntervalSince(previous.event.observedAt)
                let previousLatitude = previous.payload.latitude ?? latitude
                let previousLongitude = previous.payload.longitude ?? longitude
                let distanceMeters = distance(
                    (previousLatitude, previousLongitude),
                    latitude, longitude
                )
                startsNewVisit = previous.event.kind.hasSuffix("departure")
                    || (event.event.kind.hasSuffix("arrival") && !drafts[lastDraft].events.isEmpty)
                    || gap > 3 * 60 * 60
                    || distanceMeters > 250
            } else {
                startsNewVisit = true
            }
            if startsNewVisit {
                drafts.append(Draft(coordinates: [(latitude, longitude)], events: [event]))
            } else if let lastDraft {
                drafts[lastDraft].coordinates.append((latitude, longitude))
                drafts[lastDraft].events.append(event)
            }
        }
        return drafts.enumerated().compactMap { index, draft in
            guard let first = draft.events.first, let latest = draft.events.last else { return nil }
            let bestPosition = draft.events.compactMap { event -> (latitude: Double, longitude: Double, accuracy: Double)? in
                guard let latitude = event.payload.latitude,
                      let longitude = event.payload.longitude,
                      let accuracy = event.payload.horizontalAccuracy,
                      latitude.isFinite, longitude.isFinite,
                      accuracy.isFinite, accuracy >= 0 else { return nil }
                return (latitude, longitude, accuracy)
            }.min { $0.accuracy < $1.accuracy }
            let latitude = bestPosition?.latitude
                ?? draft.coordinates.map(\.0).reduce(0, +) / Double(draft.coordinates.count)
            let longitude = bestPosition?.longitude
                ?? draft.coordinates.map(\.1).reduce(0, +) / Double(draft.coordinates.count)
            let place = places.min {
                meters(latitude, longitude, $0.latitude, $0.longitude) < meters(latitude, longitude, $1.latitude, $1.longitude)
            }.flatMap { meters(latitude, longitude, $0.latitude, $0.longitude) <= max($0.radiusMeters + 100, 350) ? $0 : nil }
            let eventLocationName = draft.events.compactMap { event in
                event.payload.locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.first { !$0.isEmpty }
            let label = place?.displayName
                ?? eventLocationName
                ?? "位置线索 \(index + 1)"
            let address = place?.mapAddress
                ?? draft.events.compactMap { $0.payload.mapAddress }.first
                ?? (place == nil ? "位置名称未能确定" : "")
            let stableID = "visit:\(first.id.uuidString.lowercased())"
            return RiverFootprintStop(
                id: stableID,
                latitude: latitude,
                longitude: longitude,
                title: label,
                subtitle: address,
                horizontalAccuracyMeters: bestPosition?.accuracy,
                eventIDs: draft.events.map(\.id),
                firstSeen: first.event.observedAt,
                lastSeen: latest.event.observedAt,
                placeID: place?.id,
                isNameCandidate: place.map { !$0.isUserConfirmed } ?? (eventLocationName != nil)
            )
        }
    }

    static func sourceLabel(_ source: String) -> String {
        switch source {
        case "core_location": "位置记录"
        case "healthkit": "Apple 健康"
        case "shortcuts": "快捷指令"
        case "manual", "user": "你记录的"
        default: source.lowercased().contains("mac") ? "Mac 记录" : "已保存的记录"
        }
    }

    static func memoryText(_ record: RiverSharedStateRecord, key: String) -> String? {
        guard let data = record.payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object[key] as? String
    }

    static func memoryKind(_ record: RiverSharedStateRecord) -> String {
        guard let data = record.payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "other" }
        return object["kind"] as? String ?? "other"
    }

    static func memorySourceCount(_ record: RiverSharedStateRecord) -> Int {
        guard let data = record.payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return (object["sourceEpisodeIDs"] as? [String])?.count ?? 0
    }

    private static func placeID(for payload: RiverEventPayload, places: [RiverPlace]) -> String? {
        guard let latitude = payload.latitude, let longitude = payload.longitude else { return nil }
        return places.min {
            meters(latitude, longitude, $0.latitude, $0.longitude) < meters(latitude, longitude, $1.latitude, $1.longitude)
        }.flatMap { meters(latitude, longitude, $0.latitude, $0.longitude) <= max($0.radiusMeters + 100, 350) ? $0.id : nil }
    }

    private static func healthTitle(_ metrics: RiverEventMetrics?) -> String {
        if let hours = metrics?.sleepHours { return String(format: "睡眠 %.1f 小时", hours) }
        if let steps = metrics?.steps { return "走了 \(steps.formatted()) 步" }
        if let energy = metrics?.activeEnergyKcal { return "活动能量 \(Int(energy.rounded())) 千卡" }
        if let minutes = metrics?.screenMinutes { return "记录了 \(minutes) 分钟屏幕活动" }
        return "一条健康记录"
    }

    private static func healthDetail(_ metrics: RiverEventMetrics?) -> String {
        guard let metrics else { return "Apple 健康记录" }
        let parts = [
            metrics.distanceKm.map { String(format: "%.1f 公里", $0) },
            metrics.activeEnergyKcal.map { "活动能量 \(Int($0.rounded())) 千卡" },
            metrics.deepSleepMinutes.map { "深睡 \($0) 分钟" }
        ].compactMap { $0 }
        return parts.isEmpty ? "Apple 健康记录" : parts.joined(separator: " · ")
    }

    private static func distance(_ coordinate: (Double, Double), _ latitude: Double, _ longitude: Double) -> Double {
        meters(coordinate.0, coordinate.1, latitude, longitude)
    }

    private static func meters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return radius * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}
