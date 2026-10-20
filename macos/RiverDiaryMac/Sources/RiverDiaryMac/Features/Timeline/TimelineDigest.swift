import Foundation

/// A persisted, AI-authored reading layer over local timeline evidence.
/// Candidate IDs always resolve to local ActivityTimelineItems; the model never
/// supplies timestamps or evidence identifiers that the app would blindly trust.
struct TimelineDigest: Codable, Hashable {
    let schemaVersion: Int
    let dayKey: String
    let sourceFingerprint: String
    let overview: String
    let overviewCandidateIDs: [String]
    let overviewCaptureIDs: [String]
    let overviewDiaryDates: [String]
    let segments: [TimelineDigestSegment]
    var clarifications: [TimelineDigestClarification]? = nil

    var encodedJSON: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init(
        schemaVersion: Int = 1,
        dayKey: String,
        sourceFingerprint: String,
        overview: String,
        overviewCandidateIDs: [String],
        overviewCaptureIDs: [String],
        overviewDiaryDates: [String],
        segments: [TimelineDigestSegment],
        clarifications: [TimelineDigestClarification]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.dayKey = dayKey
        self.sourceFingerprint = sourceFingerprint
        self.overview = overview
        self.overviewCandidateIDs = overviewCandidateIDs
        self.overviewCaptureIDs = overviewCaptureIDs
        self.overviewDiaryDates = overviewDiaryDates
        self.segments = segments
        self.clarifications = clarifications
    }
}

struct TimelineDigestSegment: Codable, Hashable, Identifiable {
    let candidateIDs: [String]
    let title: String
    let summary: String
    /// Reconstructed locally from validated candidate IDs; never accepted from the model.
    let evidenceRefs: [String]
    let start: Date?
    let end: Date?

    var id: String { candidateIDs.joined(separator: "|") }

    init(
        candidateIDs: [String],
        title: String,
        summary: String,
        evidenceRefs: [String] = [],
        start: Date? = nil,
        end: Date? = nil
    ) {
        self.candidateIDs = candidateIDs
        self.title = title
        self.summary = summary
        self.evidenceRefs = evidenceRefs
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey {
        case candidateIDs, title, summary, evidenceRefs, start, end
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidateIDs = try container.decode([String].self, forKey: .candidateIDs)
        title = try container.decode(String.self, forKey: .title)
        summary = try container.decode(String.self, forKey: .summary)
        evidenceRefs = try container.decodeIfPresent([String].self, forKey: .evidenceRefs) ?? []
        start = try container.decodeIfPresent(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
    }
}

struct TimelineDigestClarification: Codable, Hashable, Identifiable {
    let candidateID: String
    let annotationKey: String?
    let observation: String
    let opening: String
    let evidenceRefs: [String]

    var id: String { candidateID }
}

/// The deliberately small response shape sent to the model. Dates and source
/// references are reconstructed from local data after these IDs are validated.
struct TimelineDigestAIResponse: Decodable {
    struct Segment: Decodable {
        let candidateIDs: [String]
        let title: String
        let summary: String
    }

    struct Clarification: Decodable {
        let candidateID: String
        let observation: String
        let opening: String
    }

    let overview: String
    let overviewCandidateIDs: [String]
    let overviewCaptureIDs: [String]
    let overviewDiaryDates: [String]
    let segments: [Segment]
    let clarifications: [Clarification]

    private enum CodingKeys: String, CodingKey {
        case overview, overviewCandidateIDs, overviewCaptureIDs, overviewDiaryDates, segments, clarifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overview = try container.decode(String.self, forKey: .overview)
        overviewCandidateIDs = try container.decodeIfPresent([String].self, forKey: .overviewCandidateIDs) ?? []
        overviewCaptureIDs = try container.decodeIfPresent([String].self, forKey: .overviewCaptureIDs) ?? []
        overviewDiaryDates = try container.decodeIfPresent([String].self, forKey: .overviewDiaryDates) ?? []
        segments = try container.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        clarifications = try container.decodeIfPresent([Clarification].self, forKey: .clarifications) ?? []
    }
}

enum TimelineDigestValidator {
    static func parse(
        _ raw: String,
        dayKey: String,
        fingerprint: String,
        candidates: [ActivityTimelineItem],
        captures: [QuickCapture],
        entries: [DiaryEntry],
        browserVisits: [ChromeVisit] = [],
        locationEvents: [RawEvent] = []
    ) -> TimelineDigest? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            json = String(trimmed[first...last])
        } else {
            return nil
        }
        guard let response = try? JSONDecoder().decode(TimelineDigestAIResponse.self, from: Data(json.utf8)) else {
            return nil
        }

        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let captureIDs = Set(captures.map { "capture:\($0.id.uuidString)" })
        let diaryDates = Set(entries.map(\.date))
        let cleanOverview = response.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (12...220).contains(cleanOverview.count),
              response.overviewCandidateIDs.allSatisfy({ candidateByID[$0] != nil }),
              Set(response.overviewCandidateIDs).count == response.overviewCandidateIDs.count,
              response.overviewCaptureIDs.allSatisfy(captureIDs.contains),
              Set(response.overviewCaptureIDs).count == response.overviewCaptureIDs.count,
              response.overviewDiaryDates.allSatisfy(diaryDates.contains),
              Set(response.overviewDiaryDates).count == response.overviewDiaryDates.count,
              !response.overviewCandidateIDs.isEmpty || !response.overviewCaptureIDs.isEmpty || !response.overviewDiaryDates.isEmpty,
              response.segments.count <= 48,
              response.clarifications.count <= 4 else {
            return nil
        }

        var claimedCandidateIDs = Set<String>()
        var segments: [TimelineDigestSegment] = []
        for candidate in response.segments {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = candidate.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let ids = candidate.candidateIDs
            guard !ids.isEmpty,
                  ids.count <= 24,
                  Set(ids).count == ids.count,
                  ids.allSatisfy({ candidateByID[$0] != nil }),
                  ids.allSatisfy({ !claimedCandidateIDs.contains($0) }),
                  (2...24).contains(title.count),
                  !summary.isEmpty,
                  summary.count <= 80 else { continue }

            let ordered = ids.compactMap { candidateByID[$0] }.sorted { $0.start < $1.start }
            guard ordered.count == ids.count,
                  zip(ordered, ordered.dropFirst()).allSatisfy({ pair in
                      pair.1.start.timeIntervalSince(pair.0.end) <= 30 * 60
                  }) else { continue }

            claimedCandidateIDs.formUnion(ids)
            var evidenceRefs = ordered.flatMap { item -> [String] in
                let sourceItems = item.isFragmentRun ? item.fragments : [item]
                return sourceItems.flatMap { source in
                    source.sessions.map { "raw:\($0.id.uuidString)" }
                }
            }
            let segmentStart = ordered.first?.start
            let segmentEnd = ordered.last?.end
            if let segmentStart, let segmentEnd {
                evidenceRefs.append(contentsOf: browserVisits
                    .filter { $0.visitedAt >= segmentStart && $0.visitedAt <= segmentEnd }
                    .map { "browser:\($0.evidenceID.uuidString)" })
                evidenceRefs.append(contentsOf: locationEvents
                    .filter { $0.timestamp >= segmentStart && $0.timestamp <= segmentEnd }
                    .map { "location:\($0.id.uuidString)" })
            }
            segments.append(TimelineDigestSegment(
                candidateIDs: ordered.map(\.id),
                title: title,
                summary: summary,
                evidenceRefs: Array(Set(evidenceRefs)).sorted(),
                start: segmentStart,
                end: segmentEnd
            ))
        }

        guard !segments.isEmpty else { return nil }
        var clarificationIDs = Set<String>()
        let clarifications = response.clarifications.compactMap { candidate -> TimelineDigestClarification? in
            let observation = candidate.observation.trimmingCharacters(in: .whitespacesAndNewlines)
            let opening = candidate.opening.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let item = candidateByID[candidate.candidateID],
                  item.kind == .activity,
                  item.reviewSpan >= ActivityTimelineItem.reviewMaterialityThreshold,
                  item.isAnnotatable,
                  item.annotation?.isReviewed != true,
                  clarificationIDs.insert(candidate.candidateID).inserted,
                  !observation.isEmpty,
                  !opening.isEmpty else { return nil }
            let sourceItems = item.isFragmentRun ? item.fragments : [item]
            var refs = sourceItems.flatMap { $0.sessions.map { "raw:\($0.id.uuidString)" } }
            refs.append(contentsOf: browserVisits
                .filter { $0.visitedAt >= item.start && $0.visitedAt <= item.end }
                .map { "browser:\($0.evidenceID.uuidString)" })
            refs.append(contentsOf: locationEvents
                .filter { $0.timestamp >= item.start && $0.timestamp <= item.end }
                .map { "location:\($0.id.uuidString)" })
            return TimelineDigestClarification(
                candidateID: item.id,
                annotationKey: item.annotationKey,
                observation: String(observation.prefix(300)),
                opening: String(opening.prefix(360)),
                evidenceRefs: Array(Set(refs)).sorted()
            )
        }
        return TimelineDigest(
            dayKey: dayKey,
            sourceFingerprint: fingerprint,
            overview: cleanOverview,
            overviewCandidateIDs: response.overviewCandidateIDs,
            overviewCaptureIDs: response.overviewCaptureIDs,
            overviewDiaryDates: response.overviewDiaryDates,
            segments: segments,
            clarifications: clarifications
        )
    }
}
