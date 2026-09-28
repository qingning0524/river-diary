import Foundation

public enum RiverAnalysisJobStatus: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case superseded
}

/// Durable description of one requested AI computation. Jobs are local queue
/// records; the resulting Artifact remains the replicated canonical object.
public struct RiverAnalysisJob: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let logicalKey: String
    public let artifactType: RiverArtifactKind
    public let inputFrontier: InputFrontier
    public let priority: Int
    public let status: RiverAnalysisJobStatus
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let attempt: Int
    public let originDeviceID: RiverDeviceID
    public let pipelineVersion: String
    public let promptVersion: String
    public let lastError: String?

    public init(
        id: UUID,
        logicalKey: String,
        artifactType: RiverArtifactKind,
        inputFrontier: InputFrontier,
        priority: Int = 0,
        status: RiverAnalysisJobStatus = .queued,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        attempt: Int = 0,
        originDeviceID: RiverDeviceID,
        pipelineVersion: String,
        promptVersion: String,
        lastError: String? = nil
    ) {
        self.id = id
        self.logicalKey = logicalKey
        self.artifactType = artifactType
        self.inputFrontier = inputFrontier
        self.priority = priority
        self.status = status
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.attempt = attempt
        self.originDeviceID = originDeviceID
        self.pipelineVersion = pipelineVersion
        self.promptVersion = promptVersion
        self.lastError = lastError
    }

    public func transitioning(to next: RiverAnalysisJobStatus, at date: Date = Date(), error: String? = nil) -> Self {
        Self(
            id: id,
            logicalKey: logicalKey,
            artifactType: artifactType,
            inputFrontier: inputFrontier,
            priority: priority,
            status: next,
            createdAt: createdAt,
            startedAt: next == .running ? date : startedAt,
            finishedAt: next == .succeeded || next == .failed || next == .superseded ? date : nil,
            attempt: attempt + (next == .running ? 1 : 0),
            originDeviceID: originDeviceID,
            pipelineVersion: pipelineVersion,
            promptVersion: promptVersion,
            lastError: error
        )
    }
}

public enum RiverAnalysisJobScheduler {
    public static func jobID(deviceID: RiverDeviceID, logicalKey: String, artifactType: RiverArtifactKind,
                             inputFrontier: InputFrontier, pipelineVersion: String, promptVersion: String) -> UUID {
        RiverStableIdentifier.uuid(
            namespace: "analysis-job.\(deviceID.rawValue)",
            key: "\(logicalKey)|\(artifactType.rawValue)|\(inputFrontier.stableKey)|\(pipelineVersion)|\(promptVersion)"
        )
    }

    public static func canonicalArtifactSatisfies(
        _ job: RiverAnalysisJob,
        artifact: RiverArtifactRevision?
    ) -> Bool {
        guard let artifact else { return false }
        return artifact.logicalKey == job.logicalKey
            && artifact.kind == job.artifactType
            && artifact.inputFrontier == job.inputFrontier
            && artifact.pipelineVersion == job.pipelineVersion
            && artifact.promptVersion == job.promptVersion
            && artifact.status != .stale
    }

    public static func nextQueuedJob(from jobs: [RiverAnalysisJob]) -> RiverAnalysisJob? {
        jobs.filter { $0.status == .queued }.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }.first
    }
}
