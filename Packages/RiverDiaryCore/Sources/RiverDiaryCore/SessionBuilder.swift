import Foundation

public enum RiverSessionEndReason: String, Codable, Hashable, Sendable {
    case observedClose
    case inferredNextApp
    case repairedRepeatedOpen
    case durationCapped
    case stillOpen
    case observedSessionBoundary
}

public enum RiverSessionEvidenceQuality: Int, Codable, Hashable, Sendable {
    case inferred = 1
    case observed = 2
}

public struct RiverAppSession: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let originDeviceID: RiverDeviceID
    public let applicationIdentifier: String
    public let displayName: String
    public let start: Date
    public let end: Date?
    public let endReason: RiverSessionEndReason
    public let quality: RiverSessionEvidenceQuality
    public let evidenceEventIDs: [UUID]

    public init(
        id: String,
        originDeviceID: RiverDeviceID,
        applicationIdentifier: String,
        displayName: String,
        start: Date,
        end: Date?,
        endReason: RiverSessionEndReason,
        quality: RiverSessionEvidenceQuality,
        evidenceEventIDs: [UUID]
    ) {
        self.id = id
        self.originDeviceID = originDeviceID
        self.applicationIdentifier = applicationIdentifier
        self.displayName = displayName
        self.start = start
        self.end = end
        self.endReason = endReason
        self.quality = quality
        self.evidenceEventIDs = evidenceEventIDs
    }

    public var duration: TimeInterval? {
        guard let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    public var isComplete: Bool { end != nil }
}

public enum SessionBuilder {
    private struct OpenSession {
        var event: RiverEvent
        var payload: RiverEventPayload
        var evidence: [UUID]
    }

    public static func build(_ events: [RiverEvent], maximumUnclosedDuration: TimeInterval = 2 * 60 * 60) -> [RiverAppSession] {
        let ordered = events.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            if $0.originDeviceID != $1.originDeviceID { return $0.originDeviceID.rawValue < $1.originDeviceID.rawValue }
            return $0.originSequence < $1.originSequence
        }
        var active: [String: OpenSession] = [:]
        var sessions: [RiverAppSession] = []
        var latestByDevice: [String: Date] = [:]

        for event in ordered {
            latestByDevice[event.originDeviceID.rawValue] = max(
                latestByDevice[event.originDeviceID.rawValue] ?? .distantPast,
                event.observedAt
            )
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { continue }
            let kind = event.kind.lowercased()

            if kind == "app.session" || payload.sessionEnd != nil {
                guard let name = payload.appName, !name.isEmpty else { continue }
                let end = payload.sessionEnd ?? event.observedAt
                guard end >= event.observedAt else { continue }
                sessions.append(RiverAppSession(
                    id: "session:\(event.id.uuidString.lowercased())",
                    originDeviceID: event.originDeviceID,
                    applicationIdentifier: normalizedAppID(payload),
                    displayName: name,
                    start: event.observedAt,
                    end: end,
                    endReason: .observedSessionBoundary,
                    quality: .observed,
                    evidenceEventIDs: [event.id]
                ))
                continue
            }

            guard kind == "app.open" || kind == "app.opened" || kind == "app.close" || kind == "app.closed" else { continue }
            let deviceKey = event.originDeviceID.rawValue
            if kind == "app.open" || kind == "app.opened" {
                if var previous = active[deviceKey] {
                    let sameApp = normalizedAppID(previous.payload) == normalizedAppID(payload)
                    if sameApp && event.observedAt.timeIntervalSince(previous.event.observedAt) <= 3 {
                        previous.evidence.append(event.id)
                        active[deviceKey] = previous
                        continue
                    }
                    let cap = previous.event.observedAt.addingTimeInterval(max(0, maximumUnclosedDuration))
                    let inferredEnd = min(max(previous.event.observedAt, event.observedAt), cap)
                    let capped = event.observedAt >= cap
                    let reason: RiverSessionEndReason = capped
                        ? .durationCapped
                        : (sameApp ? .repairedRepeatedOpen : .inferredNextApp)
                    sessions.append(makeSession(previous, end: inferredEnd,
                                                reason: reason, quality: .inferred, additionalEvidence: [event.id]))
                    active.removeValue(forKey: deviceKey)
                }
                guard let name = payload.appName, !name.isEmpty else { continue }
                active[deviceKey] = OpenSession(event: event, payload: payload, evidence: [event.id])
            } else {
                guard var previous = active[deviceKey] else { continue }
                let closeAppID = normalizedAppID(payload)
                if !closeAppID.isEmpty, closeAppID != normalizedAppID(previous.payload) { continue }
                previous.evidence.append(event.id)
                sessions.append(makeSession(previous,
                                            end: max(previous.event.observedAt, event.observedAt),
                                            reason: .observedClose,
                                            quality: .observed,
                                            additionalEvidence: []))
                active.removeValue(forKey: deviceKey)
            }
        }

        for (deviceID, open) in active {
            let asOf = latestByDevice[deviceID] ?? open.event.observedAt
            let cap = open.event.observedAt.addingTimeInterval(maximumUnclosedDuration)
            if asOf >= cap {
                sessions.append(makeSession(open, end: cap, reason: .durationCapped, quality: .inferred, additionalEvidence: []))
            } else {
                sessions.append(makeSession(open, end: nil, reason: .stillOpen, quality: .inferred, additionalEvidence: []))
            }
        }
        return sessions.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.originDeviceID != $1.originDeviceID { return $0.originDeviceID.rawValue < $1.originDeviceID.rawValue }
            return $0.id < $1.id
        }
    }

    private static func makeSession(
        _ open: OpenSession,
        end: Date?,
        reason: RiverSessionEndReason,
        quality: RiverSessionEvidenceQuality,
        additionalEvidence: [UUID]
    ) -> RiverAppSession {
        RiverAppSession(
            id: "session:\(open.event.id.uuidString.lowercased())",
            originDeviceID: open.event.originDeviceID,
            applicationIdentifier: normalizedAppID(open.payload),
            displayName: open.payload.appName ?? "应用",
            start: open.event.observedAt,
            end: end,
            endReason: reason,
            quality: quality,
            evidenceEventIDs: Array(Set(open.evidence + additionalEvidence)).sorted { $0.uuidString < $1.uuidString }
        )
    }

    private static func normalizedAppID(_ payload: RiverEventPayload) -> String {
        (payload.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
         ?? payload.appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
         ?? "")
    }
}
