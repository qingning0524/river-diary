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

public struct RiverSessionProjectionSnapshot: Codable, Hashable, Sendable {
    public let deviceID: RiverDeviceID
    public let sessions: [RiverAppSession]
    /// The unprojected open lifecycle session. A two-hour capped row can still
    /// be active until a later app event supplies a real boundary.
    public let activeSession: RiverAppSession?
    public let lastSessionSequence: UInt64
    public let latestSessionObservedAt: Date?

    public init(
        deviceID: RiverDeviceID,
        sessions: [RiverAppSession],
        activeSession: RiverAppSession? = nil,
        lastSessionSequence: UInt64,
        latestSessionObservedAt: Date?
    ) {
        self.deviceID = deviceID
        self.sessions = sessions
        self.activeSession = activeSession
        self.lastSessionSequence = lastSessionSequence
        self.latestSessionObservedAt = latestSessionObservedAt
    }
}

public struct RiverSessionProjectionAppend: Hashable, Sendable {
    public let deviceID: RiverDeviceID
    public let changedSessions: [RiverAppSession]
    public let activeSession: RiverAppSession?
    public let lastSessionSequence: UInt64
    public let latestSessionObservedAt: Date?

    public init(deviceID: RiverDeviceID, changedSessions: [RiverAppSession], activeSession: RiverAppSession?,
                lastSessionSequence: UInt64, latestSessionObservedAt: Date?) {
        self.deviceID = deviceID
        self.changedSessions = changedSessions
        self.activeSession = activeSession
        self.lastSessionSequence = lastSessionSequence
        self.latestSessionObservedAt = latestSessionObservedAt
    }
}

public enum SessionBuilder {
    public static func isSessionEvent(_ event: RiverEvent) -> Bool {
        guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return false }
        let kind = event.kind.lowercased()
        return kind == "app.session" || (kind.hasPrefix("app.") && payload.sessionEnd != nil)
            || ["app.open", "app.opened", "app.close", "app.closed"].contains(kind)
    }

    private struct OpenSession {
        var event: RiverEvent
        var payload: RiverEventPayload
        var evidence: [UUID]
    }

    public static func snapshot(_ events: [RiverEvent], for deviceID: RiverDeviceID,
                                maximumUnclosedDuration: TimeInterval = 2 * 60 * 60) -> RiverSessionProjectionSnapshot {
        let inputs = events.filter { $0.originDeviceID == deviceID && isSessionEvent($0) }
        let bySequence = inputs.sorted { $0.originSequence < $1.originSequence }
        return RiverSessionProjectionSnapshot(
            deviceID: deviceID,
            sessions: build(inputs, maximumUnclosedDuration: maximumUnclosedDuration),
            activeSession: activeOpenSession(inputs, for: deviceID),
            lastSessionSequence: bySequence.last?.originSequence ?? 0,
            latestSessionObservedAt: bySequence.map(\.observedAt).max()
        )
    }

    /// Appends a monotonic tail to a per-device snapshot. Returns nil when the
    /// new input is late or otherwise cannot be applied without replaying the
    /// device's event history.
    public static func appending(
        _ events: [RiverEvent],
        to snapshot: RiverSessionProjectionSnapshot,
        maximumUnclosedDuration: TimeInterval = 2 * 60 * 60
    ) -> RiverSessionProjectionAppend? {
        if let activeSession = snapshot.activeSession {
            guard activeSession.originDeviceID == snapshot.deviceID, activeSession.end == nil else { return nil }
        }
        let ordered = events.sorted { $0.originSequence < $1.originSequence }
        guard Set(ordered.map(\.originSequence)).count == ordered.count else { return nil }

        var activeSession = snapshot.activeSession
        var changedSessions: [String: RiverAppSession] = [:]
        var lastSequence = snapshot.lastSessionSequence
        var latestObservedAt = snapshot.latestSessionObservedAt
        for event in ordered {
            guard event.originDeviceID == snapshot.deviceID,
                  isSessionEvent(event),
                  event.originSequence > lastSequence,
                  latestObservedAt.map({ event.observedAt >= $0 }) ?? true,
                  let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { return nil }
            append(event, payload: payload, to: &changedSessions, active: &activeSession,
                   maximumUnclosedDuration: maximumUnclosedDuration)
            lastSequence = event.originSequence
            latestObservedAt = event.observedAt
        }
        if let activeSession {
            let projected = projectedActiveSession(
                activeSession, asOf: latestObservedAt,
                maximumUnclosedDuration: maximumUnclosedDuration
            )
            changedSessions[projected.id] = projected
        }
        let sortedChanges = changedSessions.values.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.originDeviceID != $1.originDeviceID { return $0.originDeviceID.rawValue < $1.originDeviceID.rawValue }
            return $0.id < $1.id
        }
        return RiverSessionProjectionAppend(
            deviceID: snapshot.deviceID,
            changedSessions: sortedChanges,
            activeSession: activeSession,
            lastSessionSequence: lastSequence,
            latestSessionObservedAt: latestObservedAt
        )
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
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { continue }
            let kind = event.kind.lowercased()
            let hasObservedBoundary = kind == "app.session" || (kind.hasPrefix("app.") && payload.sessionEnd != nil)
            let isLifecycleEvent = ["app.open", "app.opened", "app.close", "app.closed"].contains(kind)
            guard hasObservedBoundary || isLifecycleEvent else { continue }
            latestByDevice[event.originDeviceID.rawValue] = max(
                latestByDevice[event.originDeviceID.rawValue] ?? .distantPast,
                event.observedAt
            )

            if hasObservedBoundary {
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

            guard isLifecycleEvent else { continue }
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

    private static func append(
        _ event: RiverEvent,
        payload: RiverEventPayload,
        to changedSessions: inout [String: RiverAppSession],
        active: inout RiverAppSession?,
        maximumUnclosedDuration: TimeInterval
    ) {
        let kind = event.kind.lowercased()
        let hasObservedBoundary = kind == "app.session" || (kind.hasPrefix("app.") && payload.sessionEnd != nil)
        let isOpen = kind == "app.open" || kind == "app.opened"
        let isClose = kind == "app.close" || kind == "app.closed"
        if hasObservedBoundary {
            if let name = payload.appName, !name.isEmpty {
                let end = payload.sessionEnd ?? event.observedAt
                if end >= event.observedAt {
                    let session = RiverAppSession(
                        id: "session:\(event.id.uuidString.lowercased())",
                        originDeviceID: event.originDeviceID,
                        applicationIdentifier: normalizedAppID(payload),
                        displayName: name,
                        start: event.observedAt,
                        end: end,
                        endReason: .observedSessionBoundary,
                        quality: .observed,
                        evidenceEventIDs: [event.id]
                    )
                    changedSessions[session.id] = session
                }
            }
        } else if isOpen {
            if let previous = active {
                let sameApp = previous.applicationIdentifier == normalizedAppID(payload)
                let elapsed = event.observedAt.timeIntervalSince(previous.start)
                if sameApp && elapsed <= 3 {
                    active = replacing(
                        previous, end: nil, endReason: .stillOpen,
                        quality: previous.quality, additionalEvidence: [event.id]
                    )
                    return
                }
                let cap = previous.start.addingTimeInterval(max(0, maximumUnclosedDuration))
                let inferredEnd = min(max(previous.start, event.observedAt), cap)
                let reason: RiverSessionEndReason = event.observedAt >= cap
                    ? .durationCapped
                    : (sameApp ? .repairedRepeatedOpen : .inferredNextApp)
                let ended = replacing(
                    previous, end: inferredEnd, endReason: reason,
                    quality: .inferred, additionalEvidence: [event.id]
                )
                changedSessions[ended.id] = ended
                active = nil
            }
            if let name = payload.appName, !name.isEmpty {
                active = RiverAppSession(
                    id: "session:\(event.id.uuidString.lowercased())",
                    originDeviceID: event.originDeviceID,
                    applicationIdentifier: normalizedAppID(payload),
                    displayName: name,
                    start: event.observedAt,
                    end: nil,
                    endReason: .stillOpen,
                    quality: .inferred,
                    evidenceEventIDs: [event.id]
                )
            }
        } else if isClose, let previous = active {
            let closeAppID = normalizedAppID(payload)
            if closeAppID.isEmpty || closeAppID == previous.applicationIdentifier {
                let ended = replacing(
                    previous,
                    end: max(previous.start, event.observedAt),
                    endReason: .observedClose,
                    quality: .observed,
                    additionalEvidence: [event.id]
                )
                changedSessions[ended.id] = ended
                active = nil
            }
        }
    }

    private static func activeOpenSession(_ events: [RiverEvent], for deviceID: RiverDeviceID) -> RiverAppSession? {
        let ordered = events.filter { $0.originDeviceID == deviceID }.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.originSequence < $1.originSequence
        }
        var active: OpenSession?
        for event in ordered {
            guard let payload = try? JSONDecoder().decode(RiverEventPayload.self, from: event.payload) else { continue }
            let kind = event.kind.lowercased()
            let isBoundary = kind == "app.session" || (kind.hasPrefix("app.") && payload.sessionEnd != nil)
            if isBoundary { continue }
            guard ["app.open", "app.opened", "app.close", "app.closed"].contains(kind) else { continue }
            if kind == "app.open" || kind == "app.opened" {
                if var previous = active {
                    let sameApp = normalizedAppID(previous.payload) == normalizedAppID(payload)
                    if sameApp && event.observedAt.timeIntervalSince(previous.event.observedAt) <= 3 {
                        previous.evidence.append(event.id)
                        active = previous
                        continue
                    }
                    active = nil
                }
                guard let name = payload.appName, !name.isEmpty else { continue }
                active = OpenSession(event: event, payload: payload, evidence: [event.id])
            } else if var previous = active {
                let closeAppID = normalizedAppID(payload)
                if closeAppID.isEmpty || closeAppID == normalizedAppID(previous.payload) {
                    previous.evidence.append(event.id)
                    active = nil
                }
            }
        }
        guard let active else { return nil }
        return makeSession(active, end: nil, reason: .stillOpen, quality: .inferred, additionalEvidence: [])
    }

    private static func projectedActiveSession(
        _ active: RiverAppSession,
        asOf: Date?,
        maximumUnclosedDuration: TimeInterval
    ) -> RiverAppSession {
        let cap = active.start.addingTimeInterval(maximumUnclosedDuration)
        guard let asOf, asOf >= cap else { return active }
        return replacing(active, end: cap, endReason: .durationCapped,
                         quality: .inferred, additionalEvidence: [])
    }

    private static func replacing(
        _ session: RiverAppSession,
        end: Date?,
        endReason: RiverSessionEndReason,
        quality: RiverSessionEvidenceQuality,
        additionalEvidence: [UUID]
    ) -> RiverAppSession {
        RiverAppSession(
            id: session.id,
            originDeviceID: session.originDeviceID,
            applicationIdentifier: session.applicationIdentifier,
            displayName: session.displayName,
            start: session.start,
            end: end,
            endReason: endReason,
            quality: quality,
            evidenceEventIDs: Array(Set(session.evidenceEventIDs + additionalEvidence)).sorted { $0.uuidString < $1.uuidString }
        )
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
