import Foundation

public struct RiverDeviceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(kind: String, uuid: UUID = UUID()) {
        self.rawValue = "\(kind)_\(uuid.uuidString.lowercased())"
    }

    public var description: String { rawValue }
}

public struct RiverEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let originDeviceID: RiverDeviceID
    public let originSequence: UInt64
    public let observedAt: Date
    public let recordedAt: Date
    public let observedTimeZoneIdentifier: String?
    public let source: String
    public let kind: String
    public let sourceHash: String
    public let payload: Data

    public init(
        id: UUID = UUID(),
        originDeviceID: RiverDeviceID,
        originSequence: UInt64,
        observedAt: Date,
        recordedAt: Date = Date(),
        observedTimeZoneIdentifier: String? = TimeZone.current.identifier,
        source: String,
        kind: String,
        sourceHash: String = "",
        payload: Data
    ) {
        self.id = id
        self.originDeviceID = originDeviceID
        self.originSequence = originSequence
        self.observedAt = observedAt
        self.recordedAt = recordedAt
        self.observedTimeZoneIdentifier = observedTimeZoneIdentifier
        self.source = source
        self.kind = kind
        self.sourceHash = sourceHash
        self.payload = payload
    }
}

public struct RiverEventPayload: Codable, Hashable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var text: String?
    /// 笔记/页面标题；与正文分开。
    public var title: String?
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?
    public var sessionEnd: Date?
    public var locationName: String?
    public var mapAddress: String?
    public var poiCategory: String?
    public var mapProvider: String?
    public var mapResultIdentifier: String?
    public var mapCandidates: [RiverPlaceCandidate]?
    public var movementMode: String?
    public var movementConfidence: String?
    public var intervalEnd: Date?
    public var mediaSummary: String?
    public var mediaCategory: String?
    public var mediaGroupID: String?
    public var mediaSourceTokens: [String]?
    public var mediaAnalysisFingerprint: String?
    public var photoCount: Int?
    public var mealCaloriesLowerBound: Int?
    public var mealCaloriesUpperBound: Int?
    public var mealEstimateNote: String?
    /// 日历/提醒事项的容器名称（日历名或提醒列表名），不包含备注。
    public var calendarName: String?
    public var isAllDay: Bool?
    public var attendeeCount: Int?
    /// 本地 Git 仓库当天的提交数；不保存 commit message。
    public var commitCount: Int?
    /// `DayContextSnapshot` 的 JSON；用于跨端/网页展示设备日上下文。
    public var contextJSON: String?
    public var metrics: RiverEventMetrics?

    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil,
                url: String? = nil, text: String? = nil, title: String? = nil, latitude: Double? = nil,
                longitude: Double? = nil, horizontalAccuracy: Double? = nil, sessionEnd: Date? = nil,
                locationName: String? = nil, mapAddress: String? = nil,
                poiCategory: String? = nil, mapProvider: String? = nil,
                mapResultIdentifier: String? = nil, mapCandidates: [RiverPlaceCandidate]? = nil,
                movementMode: String? = nil, movementConfidence: String? = nil,
                intervalEnd: Date? = nil, mediaSummary: String? = nil, mediaCategory: String? = nil,
                mediaGroupID: String? = nil, mediaSourceTokens: [String]? = nil,
                mediaAnalysisFingerprint: String? = nil,
                photoCount: Int? = nil, mealCaloriesLowerBound: Int? = nil,
                mealCaloriesUpperBound: Int? = nil, mealEstimateNote: String? = nil,
                calendarName: String? = nil, isAllDay: Bool? = nil, attendeeCount: Int? = nil,
                commitCount: Int? = nil,
                contextJSON: String? = nil,
                metrics: RiverEventMetrics? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.text = text
        self.title = title
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.sessionEnd = sessionEnd
        self.locationName = locationName
        self.mapAddress = mapAddress
        self.poiCategory = poiCategory
        self.mapProvider = mapProvider
        self.mapResultIdentifier = mapResultIdentifier
        self.mapCandidates = mapCandidates
        self.movementMode = movementMode
        self.movementConfidence = movementConfidence
        self.intervalEnd = intervalEnd
        self.mediaSummary = mediaSummary
        self.mediaCategory = mediaCategory
        self.mediaGroupID = mediaGroupID
        self.mediaSourceTokens = mediaSourceTokens
        self.mediaAnalysisFingerprint = mediaAnalysisFingerprint
        self.photoCount = photoCount
        self.mealCaloriesLowerBound = mealCaloriesLowerBound
        self.mealCaloriesUpperBound = mealCaloriesUpperBound
        self.mealEstimateNote = mealEstimateNote
        self.calendarName = calendarName
        self.isAllDay = isAllDay
        self.attendeeCount = attendeeCount
        self.commitCount = commitCount
        self.contextJSON = contextJSON
        self.metrics = metrics
    }
}

/// A sync-safe nearby business candidate attached to one location observation.
public struct RiverPlaceCandidate: Codable, Hashable, Sendable, Identifiable {
    public let name: String
    public let address: String?
    public let category: String?
    public let provider: String
    public let resultIdentifier: String?
    public let distanceMeters: Double
    public let horizontalAccuracyMeters: Double

    public var id: String {
        if let resultIdentifier, !resultIdentifier.isEmpty { return "\(provider)|\(resultIdentifier)" }
        return "\(provider)|\(name.lowercased())|\(category ?? "")"
    }

    public var suggestedKind: String? {
        let value = "\(name) \(category ?? "")".lowercased()
        if ["网吧", "电竞", "pc bang", "internet cafe"].contains(where: value.contains) { return "网吧" }
        if ["蜜雪冰城", "奶茶", "茶饮", "bubble tea"].contains(where: value.contains) { return "奶茶店" }
        if ["理发", "发廊", "美发", "barber", "hair salon"].contains(where: value.contains) { return "理发店" }
        if ["restaurant", "food", "餐饮", "食堂"].contains(where: value.contains) { return "餐饮" }
        return nil
    }

    public var choiceLabel: String {
        guard let kind = suggestedKind, !name.localizedCaseInsensitiveContains(kind) else { return name }
        return "\(name) · \(kind)"
    }

    public init(name: String, address: String? = nil, category: String? = nil,
                provider: String, resultIdentifier: String? = nil,
                distanceMeters: Double, horizontalAccuracyMeters: Double) {
        self.name = name
        self.address = address
        self.category = category
        self.provider = provider
        self.resultIdentifier = resultIdentifier
        self.distanceMeters = distanceMeters
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
    }
}

public struct RiverEventMetrics: Codable, Hashable, Sendable {
    public var steps: Int?
    public var distanceKm: Double?
    public var activeEnergyKcal: Double?
    public var sleepHours: Double?
    public var coreSleepMinutes: Int?
    public var deepSleepMinutes: Int?
    public var remSleepMinutes: Int?
    public var awakeMinutes: Int?
    public var screenMinutes: Int?
    public var durationMinutes: Int?
    /// Apple 健康的 State of Mind 效价，-1…1；只有 iOS 18+ 设备会产生。
    public var valence: Double?

    public init(steps: Int? = nil, distanceKm: Double? = nil, activeEnergyKcal: Double? = nil,
                sleepHours: Double? = nil, coreSleepMinutes: Int? = nil, deepSleepMinutes: Int? = nil,
                remSleepMinutes: Int? = nil, awakeMinutes: Int? = nil, screenMinutes: Int? = nil,
                durationMinutes: Int? = nil, valence: Double? = nil) {
        self.steps = steps
        self.distanceKm = distanceKm
        self.activeEnergyKcal = activeEnergyKcal
        self.sleepHours = sleepHours
        self.coreSleepMinutes = coreSleepMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.screenMinutes = screenMinutes
        self.durationMinutes = durationMinutes
        self.valence = valence
    }
}

public struct RiverEventBatch: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let deviceID: RiverDeviceID
    public let protocolVersion: Int
    public let schemaVersion: Int
    public let events: [RiverEvent]

    public init(
        id: String? = nil,
        deviceID: RiverDeviceID,
        protocolVersion: Int = 1,
        schemaVersion: Int = 1,
        events: [RiverEvent]
    ) throws {
        guard !events.isEmpty else { throw RiverProtocolError.emptyBatch }
        guard events.allSatisfy({ $0.originDeviceID == deviceID }) else {
            throw RiverProtocolError.mixedDeviceBatch
        }
        guard events.allSatisfy({ $0.originSequence > 0 }) else {
            throw RiverProtocolError.nonContiguousBatch
        }
        let ordered = events.sorted { $0.originSequence < $1.originSequence }
        guard Set(ordered.map(\.id)).count == ordered.count else {
            throw RiverProtocolError.duplicateEventID
        }
        guard Set(ordered.map(\.originSequence)).count == ordered.count else {
            throw RiverProtocolError.duplicateSequence
        }
        for pair in zip(ordered, ordered.dropFirst())
        where pair.0.originSequence == UInt64.max || pair.1.originSequence != pair.0.originSequence + 1 {
            throw RiverProtocolError.nonContiguousBatch
        }
        self.id = id ?? "events_\(deviceID.rawValue)_\(ordered[0].originSequence)-\(ordered[ordered.count - 1].originSequence)"
        self.deviceID = deviceID
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.events = ordered
    }

    public var firstSequence: UInt64 { events[0].originSequence }
    public var lastSequence: UInt64 { events[events.count - 1].originSequence }
}

public enum RiverProtocolError: Error, Equatable {
    case emptyBatch
    case mixedDeviceBatch
    case duplicateEventID
    case duplicateSequence
    case nonContiguousBatch
    case invalidFrontier
    case invalidArtifactSet
}

public struct SequenceGap: Codable, Hashable, Sendable {
    public let first: UInt64
    public let last: UInt64

    public init(first: UInt64, last: UInt64) {
        self.first = first
        self.last = last
    }
}

public struct SequenceScan: Codable, Hashable, Sendable {
    public let highestObserved: UInt64
    public let contiguousThrough: UInt64
    public let gaps: [SequenceGap]

    public var isContiguous: Bool { gaps.isEmpty }

    public init(sequences: [UInt64], startingAfter watermark: UInt64 = 0) {
        let unique = Array(Set(sequences.filter { $0 > watermark })).sorted()
        highestObserved = unique.last ?? watermark
        var cursor = watermark
        var ranges: [SequenceGap] = []
        for sequence in unique {
            if sequence > cursor + 1 {
                ranges.append(SequenceGap(first: cursor + 1, last: sequence - 1))
                break
            }
            if sequence == cursor + 1 { cursor = sequence }
        }
        contiguousThrough = cursor
        gaps = ranges
    }
}
