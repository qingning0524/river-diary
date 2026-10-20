import Combine
import Foundation
import UserNotifications

@MainActor final class RiverReminderStore: ObservableObject {
    private static let key = "river.reminder.evening.enabled"
    private static let requestID = "river.evening-journal"
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: key)
    @Published private(set) var message: String?
    func setEnabled(_ enabled: Bool) async {
        let center = UNUserNotificationCenter.current()
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
            isEnabled = false; UserDefaults.standard.set(false, forKey: Self.key); message = nil; return
        }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { message = "系统通知未允许，提醒尚未开启。"; return }
            let content = UNMutableNotificationContent()
            content.title = "留给自己的话"; content.body = "今晚，有什么想记下的？"; content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 21, minute: 30), repeats: true)
            try await center.add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: trigger))
            isEnabled = true; UserDefaults.standard.set(true, forKey: Self.key); message = nil
        } catch { message = "提醒尚未保存：\(error.localizedDescription)" }
    }
}
