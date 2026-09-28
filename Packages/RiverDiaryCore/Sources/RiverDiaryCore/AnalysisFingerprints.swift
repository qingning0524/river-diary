import CryptoKit
import Foundation

private struct RiverArtifactInputIdentity: Codable {
    let frontier: InputFrontier
    let systemPrompt: String
    let userPrompt: String
}

private struct RiverAnalysisRequestIdentity: Codable {
    let endpoint: String
    let model: String
    let systemPrompt: String
    let userPrompt: String
    let temperature: Double
    let maxTokens: Int
}

/// Stable hashes for the analytical input and the local request configuration.
/// Provider details affect job recovery identity, while only frontier and
/// prompt content affect the replicated Artifact's input identity.
public enum RiverAnalysisFingerprints {
    public static func artifactInput(
        frontier: InputFrontier,
        systemPrompt: String,
        userPrompt: String
    ) -> String {
        hash(RiverArtifactInputIdentity(
            frontier: frontier,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        ))
    }

    public static func request(
        endpoint: String,
        model: String,
        systemPrompt: String,
        userPrompt: String,
        temperature: Double,
        maxTokens: Int
    ) -> String {
        hash(RiverAnalysisRequestIdentity(
            endpoint: endpoint,
            model: model,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: temperature,
            maxTokens: maxTokens
        ))
    }

    private static func hash<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "invalid-analysis-fingerprint" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
