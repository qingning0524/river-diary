import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The wire envelope shared with the web console and the account service.
///
/// The server validates and stores this object verbatim. It never receives the
/// passphrase, a derived key, or plaintext. `summary` is a deliberately small
/// allowlist so the server can show "3 段 · 2 天" without learning the content.
public struct CloudMirrorEnvelope: Codable, Equatable, Sendable {
    public struct KDF: Codable, Equatable, Sendable {
        public var name: String
        public var iterations: Int
        public var salt: String

        public init(name: String = CloudMirrorCrypto.kdfName, iterations: Int, salt: String) {
            self.name = name
            self.iterations = iterations
            self.salt = salt
        }
    }

    public struct Cipher: Codable, Equatable, Sendable {
        public var name: String
        public var iv: String

        public init(name: String = CloudMirrorCrypto.cipherName, iv: String) {
            self.name = name
            self.iv = iv
        }
    }

    public static let currentFormat = "river.cloud-mirror"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var kdf: KDF
    public var cipher: Cipher
    /// Base64 of AES-GCM ciphertext followed by the 16-byte authentication tag.
    /// The nonce is carried separately in `cipher.iv`, matching the web client.
    public var ciphertext: String
    public var clientUpdatedAt: String
    public var summary: CloudMirrorSummary

    enum CodingKeys: String, CodingKey {
        case format, version, kdf, cipher, ciphertext
        case clientUpdatedAt = "client_updated_at"
        case summary
    }

    public init(
        format: String = CloudMirrorEnvelope.currentFormat,
        version: Int = CloudMirrorEnvelope.currentVersion,
        kdf: KDF,
        cipher: Cipher,
        ciphertext: String,
        clientUpdatedAt: String,
        summary: CloudMirrorSummary
    ) {
        self.format = format
        self.version = version
        self.kdf = kdf
        self.cipher = cipher
        self.ciphertext = ciphertext
        self.clientUpdatedAt = clientUpdatedAt
        self.summary = summary
    }
}

/// The only metadata the account service stores in a readable form.
public struct CloudMirrorSummary: Codable, Equatable, Sendable {
    public var entries: Int
    public var days: Int
    public var places: Int
    public var collections: Int
    public var understandings: Int
    public var first: String
    public var last: String
    /// Client-declared consent metadata. `false` means "not declared", not a
    /// server-side guarantee; the ciphertext is the authority.
    public var includesHealth: Bool

    public init(
        entries: Int = 0, days: Int = 0, places: Int = 0, collections: Int = 0,
        understandings: Int = 0, first: String = "", last: String = "",
        includesHealth: Bool = false
    ) {
        self.entries = entries
        self.days = days
        self.places = places
        self.collections = collections
        self.understandings = understandings
        self.first = first
        self.last = last
        self.includesHealth = includesHealth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode(Int.self, forKey: .entries)
        days = try container.decode(Int.self, forKey: .days)
        places = try container.decode(Int.self, forKey: .places)
        collections = try container.decode(Int.self, forKey: .collections)
        understandings = try container.decode(Int.self, forKey: .understandings)
        first = try container.decode(String.self, forKey: .first)
        last = try container.decode(String.self, forKey: .last)
        // Envelopes written before 2026-10-22 did not carry consent metadata.
        includesHealth = try container.decodeIfPresent(Bool.self, forKey: .includesHealth) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case entries, days, places, collections, understandings, first, last
        case includesHealth = "includes_health"
    }

}

public enum CloudMirrorError: LocalizedError, Equatable {
    case passphraseTooShort
    case passphraseTooLong
    case invalidEnvelope
    case cryptoUnavailable
    case tooLarge
    case badPassphrase

    public var errorDescription: String? {
        switch self {
        case .passphraseTooShort: "口令至少需要 12 个字符。"
        case .passphraseTooLong: "口令不能超过 128 个字符。"
        case .invalidEnvelope: "云副本格式不正确。"
        case .cryptoUnavailable: "这台设备无法使用系统加密。"
        case .tooLarge: "加密后的云副本超过 8 MB，请先精简。"
        case .badPassphrase: "口令不正确，或云副本已损坏。"
        }
    }
}

public enum CloudMirrorCrypto {
    public static let kdfName = "PBKDF2-SHA-256"
    public static let cipherName = "AES-GCM-256"
    public static let iterations = 600_000
    public static let minIterations = 100_000
    public static let maxIterations = 600_000
    public static let minPassphraseCharacters = 12
    public static let maxPassphraseCharacters = 128
    public static let maxCiphertextBytes = 8 << 20

    private static let associatedData = Data("river.cloud-mirror:v1".utf8)

    /// Encrypts a mirror for upload. Health sections are removed unless the
    /// caller explicitly opted in for this upload. The summary is computed
    /// after filtering, so it never declares health that was not included.
    public static func buildEnvelope(
        archive: MemoryMirrorArchive,
        passphrase: String,
        includeHealth: Bool = false,
        now: Date = Date(),
        iterations: Int = CloudMirrorCrypto.iterations,
        randomBytes: (Int) throws -> Data = { count in
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard status == errSecSuccess else { throw CloudMirrorError.cryptoUnavailable }
            return Data(bytes)
        }
    ) throws -> CloudMirrorEnvelope {
        let characters = passphrase.count
        guard characters >= minPassphraseCharacters else { throw CloudMirrorError.passphraseTooShort }
        guard characters <= maxPassphraseCharacters else { throw CloudMirrorError.passphraseTooLong }
        guard iterations >= minIterations, iterations <= maxIterations else {
            throw CloudMirrorError.invalidEnvelope
        }
        let uploadArchive = includeHealth ? archive : archive.withoutHealthSections()
        let payload = CloudMirrorPayload(
            format: MemoryMirrorArchive.currentFormat,
            version: 2,
            exportedAt: iso8601(now),
            persona: uploadArchive.persona,
            entries: uploadArchive.entries,
            contexts: uploadArchive.contexts,
            collections: uploadArchive.collections,
            understandings: uploadArchive.understandings
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(payload)
        let salt = try randomBytes(16)
        let iv = try randomBytes(12)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce = try AES.GCM.Nonce(data: iv)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: associatedData)
        var combined = sealed.ciphertext
        combined.append(sealed.tag)
        guard combined.count <= maxCiphertextBytes else { throw CloudMirrorError.tooLarge }
        return CloudMirrorEnvelope(
            kdf: .init(iterations: iterations, salt: salt.base64EncodedString()),
            cipher: .init(iv: iv.base64EncodedString()),
            ciphertext: combined.base64EncodedString(),
            clientUpdatedAt: iso8601(now),
            summary: summary(for: uploadArchive)
        )
    }

    /// Decrypts a downloaded envelope. Any failure is reported as the same
    /// `badPassphrase` error: AES-GCM cannot distinguish a wrong key from
    /// tampering, and the UI should not pretend otherwise.
    public static func decrypt(_ envelope: CloudMirrorEnvelope, passphrase: String) throws -> MemoryMirrorArchive {
        guard envelope.format == CloudMirrorEnvelope.currentFormat,
              envelope.version == CloudMirrorEnvelope.currentVersion,
              envelope.kdf.name == kdfName,
              envelope.cipher.name == cipherName,
              envelope.kdf.iterations >= minIterations,
              envelope.kdf.iterations <= maxIterations,
              let salt = Data(base64Encoded: envelope.kdf.salt), salt.count == 16,
              let iv = Data(base64Encoded: envelope.cipher.iv), iv.count == 12,
              let combined = Data(base64Encoded: envelope.ciphertext), combined.count > 16
        else { throw CloudMirrorError.invalidEnvelope }

        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: envelope.kdf.iterations)
        let ciphertext = combined.prefix(combined.count - 16)
        let tag = combined.suffix(16)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: ciphertext, tag: tag)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: associatedData)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(CloudMirrorPayload.self, from: plaintext)
            guard payload.format == MemoryMirrorArchive.currentFormat,
                  (1...MemoryMirrorArchive.currentVersion).contains(payload.version)
            else { throw CloudMirrorError.badPassphrase }
            return MemoryMirrorArchive(
                format: payload.format,
                version: payload.version,
                exportedAt: payload.exportedAt,
                persona: payload.persona,
                entries: payload.entries,
                contexts: payload.contexts,
                collections: payload.collections,
                understandings: payload.understandings
            )
        } catch let error as CloudMirrorError {
            throw error
        } catch {
            throw CloudMirrorError.badPassphrase
        }
    }

    public static func summary(for archive: MemoryMirrorArchive) -> CloudMirrorSummary {
        var days = Set<String>()
        var places = Set<String>()
        for entry in archive.entries {
            if let date = Self.validDatePrefix(entry.occurredAt) { days.insert(date) }
            let place = entry.place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !place.isEmpty { places.insert(place) }
        }
        let sortedDays = days.sorted()
        return CloudMirrorSummary(
            entries: archive.entries.count,
            days: days.count,
            places: places.count,
            collections: archive.collections.count,
            understandings: archive.understandings.count,
            first: sortedDays.first ?? "",
            last: sortedDays.last ?? "",
            includesHealth: archive.containsHealthSections
        )
    }

    private static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let password = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw CloudMirrorError.cryptoUnavailable }
        return SymmetricKey(data: Data(derived))
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func validDatePrefix(_ value: String) -> String? {
        let prefix = String(value.prefix(10))
        guard prefix.count == 10,
              prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
              prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-"
        else { return nil }
        let digits = prefix.replacingOccurrences(of: "-", with: "")
        guard digits.count == 8, digits.allSatisfy(\.isNumber) else { return nil }
        return prefix
    }
}

/// Mirrors the web console's `river.memory-mirror` v2 payload. The archive's
/// `exportedAt` is deliberately replaced with the snapshot time, matching the
/// browser's `exported_at: now` behaviour.
private struct CloudMirrorPayload: Codable {
    var format: String
    var version: Int
    var exportedAt: String
    var persona: MemoryMirrorPersona?
    var entries: [MemoryMirrorEntry]
    var contexts: [DayContextSnapshot]
    var collections: [MemoryMirrorCollection]
    var understandings: [MemoryMirrorUnderstanding]

    enum CodingKeys: String, CodingKey {
        case format, version, persona, entries, contexts, collections, understandings
        case exportedAt = "exported_at"
    }
}

public extension MemoryMirrorArchive {
    public static let healthSectionKinds: Set<String> = ["health", "workout", "stateOfMind"]

    var containsHealthSections: Bool {
        contexts.contains { context in
            context.sections.contains { Self.healthSectionKinds.contains($0.kind) }
        }
    }

    /// Drops health-bearing sections and any context left empty. Used before
    /// encryption unless the user checked the per-upload consent box.
    func withoutHealthSections() -> MemoryMirrorArchive {
        var copy = self
        copy.contexts = contexts.compactMap { context in
            var filtered = context
            filtered.sections = context.sections.filter { !Self.healthSectionKinds.contains($0.kind) }
            return filtered.sections.isEmpty ? nil : filtered
        }
        return copy
    }
}
