import Foundation

public struct RiverFusedSessionGroup: Hashable, Sendable {
    public let primary: RiverAppSession
    public let secondary: [RiverAppSession]

    public init(primary: RiverAppSession, secondary: [RiverAppSession]) {
        self.primary = primary
        self.secondary = secondary
    }
}

public enum SessionFusionEngine {
    private struct WorkingGroup {
        var primary: RiverAppSession
        var secondary: [RiverAppSession]
    }

    /// Nests shorter activity from another device inside the longest overlapping
    /// block. It never combines durations, so a phone interruption cannot inflate
    /// the Mac's primary activity total.
    public static func fuse(_ sessions: [RiverAppSession], minimumOverlap: TimeInterval = 60) -> [RiverFusedSessionGroup] {
        let ordered = sessions.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.originDeviceID != $1.originDeviceID { return $0.originDeviceID.rawValue < $1.originDeviceID.rawValue }
            return $0.id < $1.id
        }
        var groups: [WorkingGroup] = []
        for session in ordered {
            guard let sessionEnd = session.end, let sessionDuration = session.duration, sessionDuration > 0 else {
                groups.append(WorkingGroup(primary: session, secondary: []))
                continue
            }
            let candidates = groups.indices.compactMap { index -> (Int, TimeInterval)? in
                let group = groups[index]
                guard group.primary.originDeviceID != session.originDeviceID,
                      let primaryEnd = group.primary.end else { return nil }
                let overlap = min(sessionEnd, primaryEnd).timeIntervalSince(max(session.start, group.primary.start))
                guard overlap >= minimumOverlap else { return nil }
                return (index, overlap)
            }.sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return groups[$0.0].primary.id < groups[$1.0].primary.id
            }
            guard let match = candidates.first else {
                groups.append(WorkingGroup(primary: session, secondary: []))
                continue
            }
            let index = match.0
            let current = groups[index].primary
            let currentDuration = current.duration ?? 0
            if outranks(session, duration: sessionDuration, current, duration: currentDuration) {
                groups[index].secondary.append(current)
                groups[index].primary = session
            } else {
                groups[index].secondary.append(session)
            }
            groups[index].secondary.sort {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
        }
        return groups.map { RiverFusedSessionGroup(primary: $0.primary, secondary: $0.secondary) }
            .sorted {
                if $0.primary.start != $1.primary.start { return $0.primary.start < $1.primary.start }
                return $0.primary.id < $1.primary.id
            }
    }

    private static func outranks(_ lhs: RiverAppSession, duration lhsDuration: TimeInterval,
                                 _ rhs: RiverAppSession, duration rhsDuration: TimeInterval) -> Bool {
        if lhsDuration != rhsDuration { return lhsDuration > rhsDuration }
        if lhs.originDeviceID != rhs.originDeviceID { return lhs.originDeviceID.rawValue < rhs.originDeviceID.rawValue }
        return lhs.id < rhs.id
    }
}
