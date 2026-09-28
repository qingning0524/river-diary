import Foundation

public struct RiverPlaceUserDecision: Codable, Hashable, Sendable {
    public let name: String
    public let semanticType: String
    public let isConfirmed: Bool

    public init(name: String, semanticType: String, isConfirmed: Bool) {
        self.name = name
        self.semanticType = semanticType
        self.isConfirmed = isConfirmed
    }
}

public struct RiverPlace: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let mapName: String?
    public let mapAddress: String?
    public let poiCategory: String?
    public let mapProvider: String?
    public let mapResultIdentifier: String?
    public let userDefinedName: String?
    public let semanticType: String?
    public let isUserConfirmed: Bool
    public let confidence: Double
    public let firstSeen: Date
    public let lastSeen: Date
    public let visitCount: Int
    public let totalDurationSeconds: TimeInterval

    public var displayName: String { userDefinedName ?? mapName ?? "未命名地点" }

    public init(id: String, latitude: Double, longitude: Double, radiusMeters: Double,
                mapName: String?, mapAddress: String?, poiCategory: String?, mapProvider: String?,
                mapResultIdentifier: String?, userDefinedName: String?, semanticType: String?,
                isUserConfirmed: Bool, confidence: Double, firstSeen: Date, lastSeen: Date,
                visitCount: Int, totalDurationSeconds: TimeInterval) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.mapName = mapName
        self.mapAddress = mapAddress
        self.poiCategory = poiCategory
        self.mapProvider = mapProvider
        self.mapResultIdentifier = mapResultIdentifier
        self.userDefinedName = userDefinedName
        self.semanticType = semanticType
        self.isUserConfirmed = isUserConfirmed
        self.confidence = confidence
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.visitCount = visitCount
        self.totalDurationSeconds = totalDurationSeconds
    }
}

public enum PlaceClusterEngine {
    private struct Observation {
        let event: RiverEvent
        let payload: RiverEventPayload
        let coordinate: Coordinate
    }

    private struct Coordinate {
        var latitude: Double
        var longitude: Double

        func distance(to other: Coordinate) -> Double {
            let earth = 6_371_000.0
            let lat1 = latitude * .pi / 180
            let lat2 = other.latitude * .pi / 180
            let dLat = (other.latitude - latitude) * .pi / 180
            let dLon = (other.longitude - longitude) * .pi / 180
            let a = sin(dLat / 2) * sin(dLat / 2)
                + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
            return earth * 2 * atan2(sqrt(a), sqrt(max(0, 1 - a)))
        }
    }

    private struct Cluster {
        let id: String
        var coordinates: [Coordinate]
        var observations: [Observation]
        var arrivalCount = 0

        var centroid: Coordinate {
            let latitude = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
            let longitude = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
            return Coordinate(latitude: latitude, longitude: longitude)
        }

        var radius: Double {
            let center = centroid
            return coordinates.map { $0.distance(to: center) }.max() ?? 0
        }

        var firstSeen: Date { observations.map { $0.event.observedAt }.min() ?? .distantPast }
        var lastSeen: Date { observations.map { $0.event.observedAt }.max() ?? .distantPast }
    }

    public static func build(events: [RiverEvent], userOperations: [StateOperation] = [], clusterRadiusMeters: Double = 250) -> [RiverPlace] {
        let observations: [Observation] = events.compactMap { event in
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload),
                  let latitude = payload.latitude, let longitude = payload.longitude,
                  latitude.isFinite, longitude.isFinite,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
            return Observation(event: event, payload: payload, coordinate: Coordinate(latitude: latitude, longitude: longitude))
        }.sorted {
            if $0.event.observedAt != $1.event.observedAt { return $0.event.observedAt < $1.event.observedAt }
            if $0.event.originDeviceID != $1.event.originDeviceID {
                return $0.event.originDeviceID.rawValue < $1.event.originDeviceID.rawValue
            }
            return $0.event.id.uuidString < $1.event.id.uuidString
        }

        var clusters: [Cluster] = []
        var eventToCluster: [UUID: String] = [:]
        for observation in observations {
            let matches = clusters.enumerated().compactMap { index, cluster -> (Int, Double)? in
                let distance = cluster.centroid.distance(to: observation.coordinate)
                return distance <= clusterRadiusMeters ? (index, distance) : nil
            }.sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return clusters[$0.0].id < clusters[$1.0].id
            }
            let index: Int
            if let match = matches.first {
                index = match.0
                clusters[index].coordinates.append(observation.coordinate)
                clusters[index].observations.append(observation)
            } else {
                index = clusters.count
                clusters.append(Cluster(
                    id: "place:\(observation.event.id.uuidString.lowercased())",
                    coordinates: [observation.coordinate],
                    observations: [observation]
                ))
            }
            eventToCluster[observation.event.id] = clusters[index].id
            if observation.event.kind == "location.visit.arrival" { clusters[index].arrivalCount += 1 }
        }

        let operationResolution = StateOperationResolver.resolve(userOperations.filter { $0.targetID.hasPrefix("place:") })
        var arrivals: [String: (placeID: String, date: Date)] = [:]
        var durations: [String: TimeInterval] = [:]
        for observation in observations {
            let event = observation.event
            let placeID = eventToCluster[event.id]
            let device = event.originDeviceID.rawValue
            if event.kind == "location.visit.arrival", let placeID {
                arrivals[device] = (placeID, event.observedAt)
            } else if event.kind == "location.visit.departure", let arrival = arrivals[device], arrival.placeID == placeID {
                durations[arrival.placeID, default: 0] += max(0, event.observedAt.timeIntervalSince(arrival.date))
                arrivals.removeValue(forKey: device)
            }
        }

        return clusters.map { cluster in
            let mapObservation = cluster.observations
                .filter {
                    $0.event.kind == "location.placeCandidate"
                        || $0.event.source == "mapkit"
                        || $0.payload.locationName != nil
                }
                .max { $0.event.observedAt < $1.event.observedAt }
            let latestLocationName = mapObservation?.payload.locationName
            let latestAddress = mapObservation?.payload.mapAddress
            let category = mapObservation?.payload.poiCategory
            let resultID = mapObservation?.payload.mapResultIdentifier
            let identityOperation = operationResolution.currentByField["\(cluster.id)\u{1f}identity"]
            let identity = identityOperation.flatMap { try? JSONDecoder().decode(RiverPlaceUserDecision.self, from: $0.payload) }
            let userName = identity?.name ?? resolvedString(operationResolution.currentByField, targetID: cluster.id, field: "userDefinedName")
            let semanticType = identity?.semanticType ?? resolvedString(operationResolution.currentByField, targetID: cluster.id, field: "semanticType")
            let isConfirmed = identity?.isConfirmed ?? resolvedBool(operationResolution.currentByField, targetID: cluster.id, field: "confirmation") ?? false
            let confidence = isConfirmed ? 1.0 : (latestLocationName == nil ? 0.35 : 0.75)
            return RiverPlace(
                id: cluster.id,
                latitude: cluster.centroid.latitude,
                longitude: cluster.centroid.longitude,
                radiusMeters: cluster.radius,
                mapName: latestLocationName,
                mapAddress: latestAddress,
                poiCategory: category,
                mapProvider: mapObservation.map { $0.payload.mapProvider ?? ($0.event.source == "mapkit" ? "MapKit" : "Apple Geocoder") },
                mapResultIdentifier: resultID,
                userDefinedName: userName,
                semanticType: semanticType,
                isUserConfirmed: isConfirmed,
                confidence: confidence,
                firstSeen: cluster.firstSeen,
                lastSeen: cluster.lastSeen,
                visitCount: cluster.arrivalCount,
                totalDurationSeconds: durations[cluster.id, default: 0]
            )
        }.sorted {
            if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
            return $0.id < $1.id
        }
    }

    private static func resolvedString(_ fields: [String: StateOperation], targetID: String, field: String) -> String? {
        guard let operation = fields["\(targetID)\u{1f}\(field)"] else { return nil }
        return (try? JSONDecoder().decode(String.self, from: operation.payload))
    }

    private static func resolvedBool(_ fields: [String: StateOperation], targetID: String, field: String) -> Bool? {
        guard let operation = fields["\(targetID)\u{1f}\(field)"] else { return nil }
        return try? JSONDecoder().decode(Bool.self, from: operation.payload)
    }
}
