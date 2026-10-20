import Combine
import CoreMotion
import CryptoKit
import Foundation
import RiverDiaryCore

@MainActor
final class IPhoneMotionCollector: ObservableObject {
    private static let preferenceKey = "river.motion.enabled"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: preferenceKey)
    @Published private(set) var status = "未开启运动识别"

    private let manager = CMMotionActivityManager()
    private let database: RiverLocalDatabase
    private var lastRecordedMode: String?
    private var isCollecting = false

    init(database: RiverLocalDatabase) {
        self.database = database
        if isEnabled { start() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        if enabled { start() } else { stop() }
    }

    func start() {
        guard isEnabled else { return }
        guard CMMotionActivityManager.isActivityAvailable() else {
            status = "此设备暂不支持运动识别"
            return
        }
        guard CMMotionActivityManager.authorizationStatus() != .denied,
              CMMotionActivityManager.authorizationStatus() != .restricted else {
            status = "运动识别权限未开启"
            return
        }
        guard !isCollecting else { return }
        isCollecting = true
        status = "正在整理步行、骑行和车辆活动线索"
        let now = Date()
        let start = Calendar.current.date(byAdding: .hour, value: -36, to: now) ?? now.addingTimeInterval(-129_600)
        manager.queryActivityStarting(from: start, to: now, to: .main) { [weak self] activities, _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.isCollecting else { return }
                for item in (activities ?? []).sorted(by: { $0.startDate < $1.startDate }) {
                    self.record(item)
                }
                guard self.isEnabled, self.isCollecting else { return }
                self.manager.startActivityUpdates(to: .main) { [weak self] activity in
                    guard let activity else { return }
                    Task { @MainActor [weak self] in self?.record(activity) }
                }
            }
        }
    }

    func stop() {
        isCollecting = false
        manager.stopActivityUpdates()
        status = "运动识别已暂停"
    }

    private func record(_ activity: CMMotionActivity) {
        guard isEnabled, isCollecting else { return }
        let confidence: String
        switch activity.confidence {
        case .high: confidence = "high"
        case .medium: confidence = "medium"
        default: confidence = "low"
        }
        let mode: String
        if confidence == "low" {
            mode = "unknown"
        } else if activity.cycling {
            mode = "cycling"
        } else if activity.walking {
            mode = "walking"
        } else if activity.running {
            mode = "running"
        } else if activity.automotive {
            mode = "automotive"
        } else if activity.stationary {
            mode = "stationary"
        } else {
            mode = "unknown"
        }
        guard mode != lastRecordedMode else { return }
        let deviceID = database.deviceID
        let minute = Int(activity.startDate.timeIntervalSince1970 / 60)
        let sourceKey = "motion|\(minute)|\(mode)|\(confidence)"
        do {
            let payload = RiverEventPayload(movementMode: mode, movementConfidence: confidence)
            _ = try database.append(
                id: RiverStableIdentifier.uuid(namespace: deviceID.rawValue, key: sourceKey),
                source: "core_motion",
                kind: "mobility.activity",
                payload: payload,
                observedAt: activity.startDate,
                sourceHash: Self.sha256(Data(sourceKey.utf8))
            )
            lastRecordedMode = mode
            database.refreshTimeline(for: activity.startDate)
            status = "最近识别：\(Self.label(for: mode)) · \(activity.startDate.formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "运动记录保存失败：\(error.localizedDescription)"
        }
    }

    static func label(for mode: String) -> String {
        switch mode {
        case "walking": "步行"
        case "running": "跑步"
        case "cycling": "骑行"
        case "automotive": "乘车"
        case "stationary": "停留"
        default: "方式未知"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
