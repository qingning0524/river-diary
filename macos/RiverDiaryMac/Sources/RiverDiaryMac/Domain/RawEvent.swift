import Foundation

/// Where a raw observation came from. Collectors map system signals to these.
enum RawEventSource: String, Codable, Hashable, CaseIterable, Sendable {
    case systemApp
    case chrome
    case notes
    case iosHealth
    case ingestion
    case manual
    case location

    var displayName: String {
        switch self {
        case .systemApp: "系统活动"
        case .chrome: "浏览器"
        case .notes: "备忘录"
        case .iosHealth: "iOS 健康"
        case .ingestion: "数据管道"
        case .manual: "手动记录"
        case .location: "地点服务"
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
    var latitude: Double? = nil
    var longitude: Double? = nil
    var horizontalAccuracy: Double? = nil
    var locationName: String? = nil
    var metrics: RawEventMetrics?
}

struct RawEventMetrics: Codable, Hashable, Sendable {
    var steps: Int?
    var distanceKm: Double?
    var activeEnergyKcal: Double?
    var sleepHours: Double?
    var screenMinutes: Int?
}

/// Immutable evidence. Created only by collectors; appended only.
struct RawEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var timestamp: Date
    var source: RawEventSource
    var kind: RawEventKind
    var payload: RawEventPayload
    var sourceHash: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: RawEventSource,
        kind: RawEventKind,
        payload: RawEventPayload = RawEventPayload(),
        sourceHash: String = ""
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.kind = kind
        self.payload = payload
        self.sourceHash = sourceHash
    }
}
