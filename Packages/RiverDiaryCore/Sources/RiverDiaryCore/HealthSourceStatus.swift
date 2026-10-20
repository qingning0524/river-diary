import Foundation

/// 一个健康/采集来源当前能不能用、为什么不能用。
///
/// 关键取舍：
/// - `unknown` 与 `noSamples` 分开：前者是“无法确认权限/状态”，后者是“确认可用但没有样本”；
/// - `stale` 与 `noSamples` 分开：有样本但太久没更新，不能当成没有数据，也不能当成正常；
/// - `failed` 永远优先于授权状态：请求已经失败时，再说“已授权”会误导。
public struct HealthSourceStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        /// 设备或系统不支持该来源。
        case unsupported
        /// 无法确认权限或状态（例如 HealthKit 读权限无法查询）。
        case unknown
        case notAuthorized
        /// 已确认可用，但还没有任何样本。不是“零”，也不是失败。
        case noSamples
        case healthy
        /// 有样本，但最近一次样本已经超过阈值。
        case stale
        case failed

        public var isUsable: Bool { self == .healthy || self == .stale }
    }

    public let state: State
    public let lastSampleAt: Date?
    public let detail: String?

    public init(state: State, lastSampleAt: Date? = nil, detail: String? = nil) {
        self.state = state
        self.lastSampleAt = lastSampleAt
        self.detail = detail
    }
}

public struct HealthSourcePolicy: Sendable, Equatable {
    /// 超过这个时长没有新样本就标为陈旧。默认 36 小时：允许昨晚的睡眠到今天下午仍然是“正常”。
    public let staleAfter: TimeInterval

    public static let current = HealthSourcePolicy()

    public init(staleAfter: TimeInterval = 36 * 3600) {
        self.staleAfter = staleAfter
    }
}

public enum HealthSourceStatusEvaluator {
    /// - Parameters:
    ///   - isSupported: 设备/系统是否有这个来源（false 时其余参数忽略）。
    ///   - isAuthorized: `true`/`false` 只在能确知时传入；无法确认时传 `nil`，
    ///     不要因为一次请求成功就当成已授权。
    ///   - failure: 最近一次读取的真实错误；有值时优先于授权判断。
    public static func evaluate(
        isSupported: Bool = true,
        isAuthorized: Bool?,
        hasSamples: Bool,
        lastSampleAt: Date?,
        failure: String? = nil,
        now: Date,
        policy: HealthSourcePolicy = .current
    ) -> HealthSourceStatus {
        guard isSupported else {
            return HealthSourceStatus(state: .unsupported)
        }
        if let failure, !failure.isEmpty {
            return HealthSourceStatus(state: .failed, lastSampleAt: lastSampleAt, detail: failure)
        }
        if isAuthorized == false {
            return HealthSourceStatus(state: .notAuthorized, lastSampleAt: lastSampleAt)
        }
        if let lastSampleAt {
            if now.timeIntervalSince(lastSampleAt) > policy.staleAfter {
                return HealthSourceStatus(state: .stale, lastSampleAt: lastSampleAt)
            }
            return HealthSourceStatus(state: .healthy, lastSampleAt: lastSampleAt)
        }
        if hasSamples {
            // 有样本却拿不到时间无法判断新旧，如实标为未知。
            return HealthSourceStatus(state: .unknown, detail: "样本缺少时间戳")
        }
        if isAuthorized == true {
            return HealthSourceStatus(state: .noSamples)
        }
        return HealthSourceStatus(state: .unknown)
    }
}
