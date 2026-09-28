import CryptoKit
import Foundation

public enum ReplicationCryptoError: Error, Equatable {
    case invalidKey
    case malformedKey
    case digestMismatch
    case malformedCiphertext
}

public struct SyncEncryptionKey: Sendable, Equatable {
    private let bytes: Data

    public init() {
        var generator = SystemRandomNumberGenerator()
        bytes = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else { throw ReplicationCryptoError.invalidKey }
        bytes = rawRepresentation
    }

    public init(importCode: String) throws {
        let prefix = "river-sync-v1:"
        guard importCode.hasPrefix(prefix),
              let data = Data(base64Encoded: String(importCode.dropFirst(prefix.count))) else {
            throw ReplicationCryptoError.malformedKey
        }
        try self.init(rawRepresentation: data)
    }

    public var exportCode: String {
        "river-sync-v1:" + bytes.base64EncodedString()
    }

    public var rawRepresentation: Data { bytes }

    fileprivate var symmetricKey: SymmetricKey { SymmetricKey(data: bytes) }
}

public struct EncryptedReplicationObject: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: String
    public let protocolVersion: Int
    public let ciphertext: Data
    public let ciphertextSHA256: String

    private enum CodingKeys: String, CodingKey {
        case id, kind, protocolVersion, ciphertext, ciphertextSHA256
    }

    public init(id: String, kind: String, protocolVersion: Int = 1, ciphertext: Data, ciphertextSHA256: String) {
        self.id = id
        self.kind = kind
        self.protocolVersion = protocolVersion
        self.ciphertext = ciphertext
        self.ciphertextSHA256 = ciphertextSHA256
    }

    public static func seal(
        _ plaintext: Data,
        id: String,
        kind: String,
        using key: SyncEncryptionKey
    ) throws -> EncryptedReplicationObject {
        let associatedData = Data("river-replication-v1|\(id)|\(kind)".utf8)
        let box = try AES.GCM.seal(plaintext, using: key.symmetricKey, authenticating: associatedData)
        guard let combined = box.combined else { throw ReplicationCryptoError.malformedCiphertext }
        return EncryptedReplicationObject(
            id: id,
            kind: kind,
            ciphertext: combined,
            ciphertextSHA256: SHA256.hash(data: combined).hexString
        )
    }

    public func open(using key: SyncEncryptionKey) throws -> Data {
        guard SHA256.hash(data: ciphertext).hexString == ciphertextSHA256 else {
            throw ReplicationCryptoError.digestMismatch
        }
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else {
            throw ReplicationCryptoError.malformedCiphertext
        }
        let associatedData = Data("river-replication-v1|\(id)|\(kind)".utf8)
        return try AES.GCM.open(box, using: key.symmetricKey, authenticating: associatedData)
    }
}

public enum CanonicalStateDigest {
    public static func make(
        events: [RiverEvent],
        stateOperations: [StateOperation],
        canonicalArtifactDigests: [String],
        deviceFrontiers: [String: UInt64]
    ) -> String {
        var lines = ["river-canonical-state-v1"]
        lines.append(contentsOf: events.map { event in
            let observedAt = String(event.observedAt.timeIntervalSince1970.bitPattern, radix: 16)
            let recordedAt = String(event.recordedAt.timeIntervalSince1970.bitPattern, radix: 16)
            let payloadHash = SHA256.hash(data: event.payload).hexString
            let fields = [
                event.id.uuidString.lowercased(), event.originDeviceID.rawValue, String(event.originSequence),
                observedAt, recordedAt, event.observedTimeZoneIdentifier ?? "<nil>", event.source,
                event.kind, event.sourceHash, payloadHash
            ]
            return "event|" + fields.map { "\($0.utf8.count):\($0)" }.joined()
        }.sorted())
        lines.append(contentsOf: stateOperations.map { operation in
            let payloadHash = SHA256.hash(data: operation.payload).hexString
            let fields = [
                operation.id.uuidString.lowercased(), operation.actorDeviceID.rawValue,
                String(operation.originSequence), String(operation.clock.physicalMilliseconds),
                String(operation.clock.logicalCounter), operation.clock.deviceID.rawValue,
                operation.targetID, operation.fieldKey, operation.operationType,
                operation.causalFrontier.stableKey, payloadHash
            ]
            return "operation|" + fields.map { "\($0.utf8.count):\($0)" }.joined()
        }.sorted())
        lines.append(contentsOf: canonicalArtifactDigests.sorted().map { "artifact|\($0)" })
        lines.append(contentsOf: deviceFrontiers.keys.sorted().map { "frontier|\($0)|\(deviceFrontiers[$0, default: 0])" })
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).hexString
    }

    public static func make(
        eventIDs: [String],
        operationIDs: [String],
        canonicalArtifactIDs: [String],
        deviceFrontiers: [String: UInt64]
    ) -> String {
        var lines = ["river-canonical-state-v1"]
        lines.append(contentsOf: eventIDs.sorted().map { "event|\($0)" })
        lines.append(contentsOf: operationIDs.sorted().map { "operation|\($0)" })
        lines.append(contentsOf: canonicalArtifactIDs.sorted().map { "artifact|\($0)" })
        lines.append(contentsOf: deviceFrontiers.keys.sorted().map { "frontier|\($0)|\(deviceFrontiers[$0, default: 0])" })
        return SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).hexString
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
