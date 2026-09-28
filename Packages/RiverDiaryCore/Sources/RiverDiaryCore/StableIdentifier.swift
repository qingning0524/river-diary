import CryptoKit
import Foundation

public enum RiverStableIdentifier {
    /// Derives an idempotency ID for collectors that may replay the same
    /// observation after relaunch or at a later HealthKit refresh.
    public static func uuid(namespace: String, key: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(namespace)|\(key)".utf8))
        let bytes = Array(digest.prefix(16))
        var tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
        tuple.6 = (tuple.6 & 0x0f) | 0x50
        tuple.8 = (tuple.8 & 0x3f) | 0x80
        return UUID(uuid: tuple)
    }
}
