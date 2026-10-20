import CryptoKit
import Foundation

// MARK: - SHA256

enum SHA256Hex {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
