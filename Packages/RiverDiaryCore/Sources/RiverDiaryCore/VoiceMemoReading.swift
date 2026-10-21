import Foundation

/// 语音速记只保存转写文本，不保存音频。这里统一做去空白、空文本拒绝和长度上限，
/// 让 Shortcut、App Intent 与未来的本机录音共用同一口径。
public enum VoiceMemoReading {
    public static let maximumCharacters = 20_000

    public static func normalizedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maximumCharacters {
            return String(trimmed.prefix(maximumCharacters))
        }
        return trimmed
    }
}
