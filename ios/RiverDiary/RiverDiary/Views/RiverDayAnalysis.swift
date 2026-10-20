import Foundation
import RiverDiaryCore

/// Structured model output is validated against the exact events supplied to the model.
struct RiverDayAnalysisResponse: Decodable {
    struct Moment: Decodable {
        let title: String
        let summary: String
        let eventIDs: [String]
        enum CodingKeys: String, CodingKey { case title, summary; case eventIDs = "event_ids" }
    }
    let overview: String
    let moments: [Moment]

    static func decode(_ text: String) -> Self? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            let lines = value.components(separatedBy: "\n")
            value = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return value.data(using: .utf8).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    var readableReview: String {
        ([overview.trimmingCharacters(in: .whitespacesAndNewlines)] + moments.prefix(8).map { $0.title + "\n" + $0.summary })
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    func digest(dayKey: String, events: [RiverEvent]) -> RiverDayAnalysisDigest {
        let allowed = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var used = Set<UUID>()
        let segments = moments.prefix(8).compactMap { moment -> RiverDayAnalysisDigest.Segment? in
            let title = moment.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = moment.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...120).contains(title.count), (1...220).contains(summary.count), !moment.eventIDs.isEmpty else { return nil }
            let ids = moment.eventIDs.compactMap(UUID.init(uuidString:))
            guard ids.count == moment.eventIDs.count, Set(ids).count == ids.count,
                  ids.allSatisfy({ allowed[$0] != nil && !used.contains($0) }) else { return nil }
            let evidence = ids.compactMap { allowed[$0] }.sorted { $0.observedAt < $1.observedAt }
            guard let first = evidence.first, let last = evidence.last else { return nil }
            used.formUnion(ids)
            // Times come from local evidence, never from a model-provided timestamp.
            return .init(candidateIDs: ids.map { "event:\($0.uuidString)" }, title: title, summary: summary,
                         evidenceRefs: ids.map { "event:\($0.uuidString)" }, start: first.observedAt, end: last.observedAt)
        }
        return RiverDayAnalysisDigest(dayKey: dayKey, segments: segments.sorted { $0.start < $1.start })
    }
}

struct RiverDayAnalysisDigest: Codable {
    struct Segment: Codable {
        let candidateIDs: [String]
        let title: String
        let summary: String
        let evidenceRefs: [String]
        let start: Date
        let end: Date
    }
    let dayKey: String
    let segments: [Segment]
}

struct RiverDayAnalysisSnapshot {
    var overview: String?
    var fullReview: String?
    var status: ArtifactStatus?
    var moments: [IOSActivityRow] = []
    var statusText: String {
        switch status {
        case .current: "AI 已整理"
        case .provisional: "AI 分析 · 待合并核对"
        case .stale: "依据有更新"
        default: "等待分析"
        }
    }
    @MainActor static func load(database: RiverLocalDatabase?, date: Date) -> Self {
        guard let database else { return Self() }
        let key = RiverCanonicalArtifactKey.dailyReview(dayKey: RiverIOSProjection.dayKey(date))
        let revision = (try? database.canonicalArtifactRevisions())?.first { $0.kind == .dailyReview && $0.logicalKey == key && $0.status != .superseded }
        let text = revision.flatMap { String(data: $0.content, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        let moments = RiverIOSProjection.timelineInsights(database: database, date: date)
        let fallback = moments.isEmpty ? nil : moments.map { $0.title + "\n" + $0.detail }.joined(separator: "\n\n")
        let fallbackStatus: ArtifactStatus? = moments.first.map { row in
            row.sourceLabel.contains("依据有更新") ? .stale : row.sourceLabel.contains("等待其他设备") ? .provisional : .current
        }
        return Self(overview: text?.components(separatedBy: "\n\n").first
                        ?? (moments.isEmpty ? nil : moments.prefix(3).map(\.title).joined(separator: "；")),
                    fullReview: text?.isEmpty == false ? text : fallback,
                    status: revision?.status ?? fallbackStatus, moments: moments)
    }
}
