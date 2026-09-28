import Foundation

/// Portable snapshot of a River Node's canonical and source records. The
/// containing file is encrypted by the app with the user's shared sync key.
public struct RiverNodeBackup: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = 1
    public static let currentSchemaVersion = 1

    public let format: String
    public let protocolVersion: Int
    public let schemaVersion: Int
    public let exportedAt: Date
    public let sourceDeviceID: RiverDeviceID
    public let events: [RiverEvent]
    public let stateOperations: [StateOperation]
    public let artifactRevisions: [RiverArtifactRevision]
    public let deviceRegistrations: [DeviceRegistration]

    public init(
        protocolVersion: Int = RiverNodeBackup.currentProtocolVersion,
        schemaVersion: Int = RiverNodeBackup.currentSchemaVersion,
        exportedAt: Date = Date(),
        sourceDeviceID: RiverDeviceID,
        events: [RiverEvent],
        stateOperations: [StateOperation],
        artifactRevisions: [RiverArtifactRevision],
        deviceRegistrations: [DeviceRegistration]
    ) {
        self.format = "river-node-backup"
        self.protocolVersion = protocolVersion
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.sourceDeviceID = sourceDeviceID
        self.events = events
        self.stateOperations = stateOperations
        self.artifactRevisions = artifactRevisions
        self.deviceRegistrations = deviceRegistrations
    }

    public var isSupported: Bool {
        format == "river-node-backup"
            && protocolVersion == Self.currentProtocolVersion
            && schemaVersion == Self.currentSchemaVersion
    }
}
