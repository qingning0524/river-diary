import Foundation

/// State of Mind 的效价口径。HealthKit 约定是 -1…1，但第三方/迁移数据可能越界；
/// 写入前夹紧，避免让 `0…100` 的日记评分和 `-1…1` 的效价混在一起。
public enum StateOfMindReading {
    public static func normalizedValence(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }
}
