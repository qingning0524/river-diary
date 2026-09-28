import Foundation

public struct DecryptedReplicationObject: Sendable {
    public let deviceID: RiverDeviceID
    public let stream: String
    public let envelope: EncryptedReplicationObject
    public let plaintext: Data
}

/// Transport-neutral encrypted object exchange over a user-selected folder.
/// iCloud Drive and LAN may both move the same immutable object bytes.
public struct EncryptedFileReplication: Sendable {
    public let deviceID: RiverDeviceID
    public let directory: ReplicationDirectory
    private let key: SyncEncryptionKey

    public init(deviceID: RiverDeviceID, directory: ReplicationDirectory, key: SyncEncryptionKey) {
        self.deviceID = deviceID
        self.directory = directory
        self.key = key
    }

    @discardableResult
    public func publish<T: Encodable>(_ value: T, objectID: String, kind: String, stream: String) throws -> EncryptedReplicationObject {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(value)
        if let existing = try directory.readObject(id: objectID, stream: stream, deviceID: deviceID) {
            guard existing.kind == kind, try existing.open(using: key) == plaintext else {
                throw ReplicationIOError.immutableObjectCollision(objectID)
            }
            return existing
        }
        let encrypted = try EncryptedReplicationObject.seal(plaintext, id: objectID, kind: kind, using: key)
        do {
            _ = try directory.publish(encrypted, stream: stream, deviceID: deviceID)
        } catch ReplicationIOError.immutableObjectCollision(_) {
            // Two same-device processes can finalize the same immutable batch
            // at once. Reuse the winner only when it authenticates to exactly
            // the same plaintext; otherwise preserve the collision as an error.
            if let existing = try directory.readObject(id: objectID, stream: stream, deviceID: deviceID),
               existing.kind == kind, try existing.open(using: key) == plaintext {
                return existing
            }
            throw ReplicationIOError.immutableObjectCollision(objectID)
        }
        return encrypted
    }

    public func scanAndDecrypt() throws -> [DecryptedReplicationObject] {
        try directory.scanFiles().map { located in
            let plaintext = try located.object.open(using: key)
            return DecryptedReplicationObject(
                deviceID: located.deviceID,
                stream: located.stream,
                envelope: located.object,
                plaintext: plaintext
            )
        }
    }
}
