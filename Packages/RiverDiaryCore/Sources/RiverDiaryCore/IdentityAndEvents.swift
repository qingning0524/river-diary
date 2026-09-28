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
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?
    public var sessionEnd: Date?
    public var locationName: String?
    public var mapAddress: String?
    public var poiCategory: String?
    public var mapProvider: String?
    public var mapResultIdentifier: String?
    public var metrics: RiverEventMetrics?

    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil,
                url: String? = nil, text: String? = nil, latitude: Double? = nil,
                longitude: Double? = nil, horizontalAccuracy: Double? = nil, sessionEnd: Date? = nil,
                locationName: String? = nil, mapAddress: String? = nil,
                poiCategory: String? = nil, mapProvider: String? = nil,
                mapResultIdentifier: String? = nil,
                metrics: RiverEventMetrics? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.text = text
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.sessionEnd = sessionEnd
        self.locationName = locationName
        self.mapAddress = mapAddress
        self.poiCategory = poiCategory
        self.mapProvider = mapProvider
        self.mapResultIdentifier = mapResultIdentifier
        self.metrics = metrics
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

    public init(steps: Int? = nil, distanceKm: Double? = nil, activeEnergyKcal: Double? = nil,
                sleepHours: Double? = nil, coreSleepMinutes: Int? = nil, deepSleepMinutes: Int? = nil,
                remSleepMinutes: Int? = nil, awakeMinutes: Int? = nil, screenMinutes: Int? = nil) {
        self.steps = steps
        self.distanceKm = distanceKm
        self.activeEnergyKcal = activeEnergyKcal
        self.sleepHours = sleepHours
        self.coreSleepMinutes = coreSleepMinutes
        self.deepSleepMinutes = deepSleepMinutes
        self.remSleepMinutes = remSleepMinutes
        self.awakeMinutes = awakeMinutes
        self.screenMinutes = screenMinutes
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
