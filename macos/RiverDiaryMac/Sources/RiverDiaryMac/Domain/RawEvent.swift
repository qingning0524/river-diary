import Foundation
import RiverDiaryCore

/// Where a raw observation came from. Collectors map system signals to these.
enum RawEventSource: String, Codable, Hashable, CaseIterable, Sendable {
    case systemApp
    case chrome
    case notes
    case iosHealth
    case ingestion
    case manual
    case location
    case calendar
    case reminders
    case weather
    case git
    case dayContext
    case markdown
    case kindle

    var displayName: String {
        switch self {
        case .systemApp: "系统活动"
        case .chrome: "浏览器"
        case .notes: "备忘录"
        case .iosHealth: "iOS 健康"
        case .ingestion: "数据管道"
        case .manual: "手动记录"
        case .location: "地点服务"
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .weather: "天气"
        case .git: "代码提交"
        case .dayContext: "设备上下文"
        case .markdown: "Markdown"
        case .kindle: "Kindle"
        }
    }
}

/// What kind of raw observation this is. Kept narrow and structured;
/// human-readable text lives in `payload` fields, never in `kind`.
enum RawEventKind: String, Codable, Hashable, CaseIterable, Sendable {
    case appForeground
    case screenLock
    case windowTitle
    case urlVisit
    case noteModified
    case healthSnapshot
    case quickCapture
    case ingestionSnapshot
    case locationUpdate
    case calendarEvent
    case reminderCompleted
    case weatherDaily
    case gitCommitDaily
    case dayContextSnapshot

    var displayName: String {
        switch self {
        case .appForeground: "应用活动"
        case .screenLock: "屏幕锁定"
        case .windowTitle: "窗口标题"
        case .urlVisit: "浏览访问"
        case .noteModified: "备忘录更新"
        case .healthSnapshot: "健康快照"
        case .quickCapture: "快记"
        case .ingestionSnapshot: "采集快照"
        case .locationUpdate: "位置更新"
        case .calendarEvent: "日程"
        case .reminderCompleted: "完成提醒"
        case .weatherDaily: "每日天气"
        case .gitCommitDaily: "每日提交"
        case .dayContextSnapshot: "设备日上下文"
        }
    }
}

/// Structured, JSON-friendly payload. Sensitive columns are intentionally
/// optional; collectors decide what they are allowed to fill.
struct RawEventPayload: Codable, Hashable, Sendable {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var text: String?
    var title: String?
    var latitude: Double? = nil
    var longitude: Double? = nil
    var horizontalAccuracy: Double? = nil
    var sessionEnd: Date? = nil
    var locationName: String? = nil
    var mapAddress: String? = nil
    var poiCategory: String? = nil
    var mapProvider: String? = nil
    var mapResultIdentifier: String? = nil
    var calendarName: String? = nil
    var isAllDay: Bool? = nil
    var attendeeCount: Int? = nil
    var commitCount: Int? = nil
    var contextJSON: String? = nil
    var metrics: RawEventMetrics?
}

struct RawEventMetrics: Codable, Hashable, Sendable {
    var steps: Int?
    var distanceKm: Double?
    var activeEnergyKcal: Double?
    var sleepHours: Double?
    var coreSleepMinutes: Int?
    var deepSleepMinutes: Int?
    var remSleepMinutes: Int?
    var awakeMinutes: Int?
    var screenMinutes: Int?
    var durationMinutes: Int?
    var valence: Double?
}

/// Immutable evidence. Created only by collectors; appended only.
struct RawEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var originDeviceID: RiverDeviceID?
    var originSequence: UInt64
    var timestamp: Date
    var recordedAt: Date
    var observedTimeZoneIdentifier: String?
    var source: RawEventSource
    var sourceRawValue: String?
    var kind: RawEventKind
    var kindRawValue: String?
    var payload: RawEventPayload
    var sourceHash: String

    var persistedSource: String { sourceRawValue ?? source.rawValue }
    var persistedKind: String { kindRawValue ?? kind.rawValue }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: RawEventSource,
        kind: RawEventKind,
        payload: RawEventPayload = RawEventPayload(),
        sourceHash: String = "",
        originDeviceID: RiverDeviceID? = nil,
        originSequence: UInt64 = 0,
        recordedAt: Date = Date(),
        observedTimeZoneIdentifier: String? = TimeZone.current.identifier,
        sourceRawValue: String? = nil,
        kindRawValue: String? = nil
    ) {
        self.id = id
        self.originDeviceID = originDeviceID
        self.originSequence = originSequence
        self.timestamp = timestamp
        self.recordedAt = recordedAt
        self.observedTimeZoneIdentifier = observedTimeZoneIdentifier
        self.source = source
        self.sourceRawValue = sourceRawValue
        self.kind = kind
        self.kindRawValue = kindRawValue
        self.payload = payload
        self.sourceHash = sourceHash
    }

    init(replica event: RiverEvent) {
        let decodedPayload = (try? JSONDecoder().decode(RawEventPayload.self, from: event.payload)) ?? RawEventPayload()
        self.init(
            id: event.id,
            timestamp: event.observedAt,
            source: RawEventSource(rawValue: event.source) ?? .manual,
            kind: RawEventKind(rawValue: event.kind) ?? .quickCapture,
            payload: decodedPayload,
            sourceHash: event.sourceHash,
            originDeviceID: event.originDeviceID,
            originSequence: event.originSequence,
            recordedAt: event.recordedAt,
            observedTimeZoneIdentifier: event.observedTimeZoneIdentifier,
            sourceRawValue: RawEventSource(rawValue: event.source) == nil ? event.source : nil,
            kindRawValue: RawEventKind(rawValue: event.kind) == nil ? event.kind : nil
        )
    }

    func replica() -> RiverEvent? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let originDeviceID, originSequence > 0,
              let payloadData = try? encoder.encode(payload) else { return nil }
        return RiverEvent(
            id: id,
            originDeviceID: originDeviceID,
            originSequence: originSequence,
            observedAt: timestamp,
            recordedAt: recordedAt,
            observedTimeZoneIdentifier: observedTimeZoneIdentifier,
            source: persistedSource,
            kind: persistedKind,
            sourceHash: sourceHash,
            payload: payloadData
        )
    }
}
