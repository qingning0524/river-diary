import Foundation
import UserNotifications

/// 晚间写作提醒——与 iPhone 端 `RiverReminderStore` 同一条产品线：
/// 同一时刻（21:30）、同一文案口径。授权只在用户打开开关时申请，
/// 不在启动时打扰；已排定的提醒在每次启动时自愈重排（idempotent）。
@MainActor
final class EveningReminderStore: ObservableObject {
    private static let key = "river.reminder.evening.enabled"
    private static let requestID = "river.evening-journal"

    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: key)
    @Published private(set) var message: String?

    func setEnabled(_ enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Self.key)
            message = nil
            return
        }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                isEnabled = false
                UserDefaults.standard.set(false, forKey: Self.key)
                message = "系统通知未允许，提醒尚未开启。可在系统设置 → 通知里打开。"
                return
            }
            try await schedule(center)
            isEnabled = true
            UserDefaults.standard.set(true, forKey: Self.key)
            message = "已开启：每天 21:30 温和地提醒一次。"
        } catch {
            message = "提醒尚未保存：\(error.localizedDescription)"
        }
    }

    /// 退出登录时调用：撤掉已排定的提醒，但不改用户偏好；
    /// 再次登录会由 `reinstateIfEnabled()` 按原偏好补排。
    func cancelScheduled() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.requestID])
    }

    /// 启动时调用：开关是开的但排定丢失（重装/通知被系统清空）时补排一次。
    func reinstateIfEnabled() async {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard !pending.contains(where: { $0.identifier == Self.requestID }) else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        try? await schedule(center)
    }

    private func schedule(_ center: UNUserNotificationCenter) async throws {
        let content = UNMutableNotificationContent()
        content.title = "留给自己的话"
        content.body = "今晚，有什么想记下的？"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 21, minute: 30), repeats: true)
        try await center.add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger))
    }
}
