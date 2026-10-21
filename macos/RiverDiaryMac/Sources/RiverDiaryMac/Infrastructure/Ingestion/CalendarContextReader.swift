import EventKit
import Foundation
import RiverDiaryCore

struct CalendarEventSnapshot: Equatable, Identifiable {
    var id: String
    var title: String
    var calendarName: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var attendeeCount: Int
}

struct ReminderSnapshot: Equatable, Identifiable {
    var id: String
    var title: String
    var listName: String
    var completedAt: Date
}

struct CalendarContextSnapshot: Equatable {
    var events: [CalendarEventSnapshot]
    var reminders: [ReminderSnapshot]
    var issue: String?
}

/// macOS 的日历与提醒事项只读适配器。
///
/// 关键取舍：
/// - 只读标题、时间、参与人数、容器名；不读备注、附件、地点和参与者姓名；
/// - 不在启动时弹授权；用户打开“日历与提醒事项”时才请求；
/// - 未授权时返回原因，不把空结果当成“今天没有安排”。
@MainActor
enum CalendarContextReader {
    static let store = EKEventStore()

    static func canReadEvents() -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    static func canReadReminders() -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    static func requestAccess() async -> String? {
        var issues: [String] = []
        if !canReadEvents() {
            do {
                if #available(macOS 14.0, *) {
                    if !(try await store.requestFullAccessToEvents()) {
                        issues.append("日历未授权")
                    }
                } else {
                    issues.append("系统版本不支持日历只读授权")
                }
            } catch {
                issues.append("日历授权失败：\(error.localizedDescription)")
            }
        }
        if !canReadReminders() {
            do {
                if #available(macOS 14.0, *) {
                    if !(try await store.requestFullAccessToReminders()) {
                        issues.append("提醒事项未授权")
                    }
                } else {
                    issues.append("系统版本不支持提醒事项只读授权")
                }
            } catch {
                issues.append("提醒事项授权失败：\(error.localizedDescription)")
            }
        }
        return issues.isEmpty ? nil : issues.joined(separator: "；")
    }

    static func readToday() async -> CalendarContextSnapshot {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var issues: [String] = []
        var events: [CalendarEventSnapshot] = []
        var reminders: [ReminderSnapshot] = []

        if canReadEvents() {
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            events = store.events(matching: predicate)
                .prefix(80)
                .compactMap { event in
                    let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, let eventStart = event.startDate, let eventEnd = event.endDate else {
                        return nil
                    }
                    let identifier = event.eventIdentifier
                        ?? "\(title)|\(eventStart.timeIntervalSince1970)|\(eventEnd.timeIntervalSince1970)"
                    return CalendarEventSnapshot(
                        id: identifier,
                        title: title,
                        calendarName: event.calendar?.title ?? "",
                        start: eventStart,
                        end: eventEnd,
                        isAllDay: event.isAllDay,
                        attendeeCount: event.attendees?.count ?? 0
                    )
                }
        } else {
            issues.append("日历未授权")
        }

        if canReadReminders() {
            let predicate = store.predicateForCompletedReminders(
                withCompletionDateStarting: start,
                ending: end,
                calendars: nil
            )
            let fetched: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    continuation.resume(returning: reminders ?? [])
                }
            }
            reminders = fetched
                .prefix(80)
                .compactMap { reminder in
                    let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, let completedAt = reminder.completionDate else { return nil }
                    return ReminderSnapshot(
                        id: reminder.calendarItemIdentifier,
                        title: title,
                        listName: reminder.calendar?.title ?? "",
                        completedAt: completedAt
                    )
                }
        } else {
            issues.append("提醒事项未授权")
        }

        return CalendarContextSnapshot(
            events: events.sorted { $0.start < $1.start },
            reminders: reminders.sorted { $0.completedAt < $1.completedAt },
            issue: issues.isEmpty ? nil : issues.joined(separator: "；")
        )
    }
}

/// 把快照变成 append-only 的 V2 证据。ID 由日历事件标识和开始时间派生，
/// 同一天重复采集不会制造重复日程。
enum CalendarContextEvents {
    static func makeEvents(from snapshot: CalendarContextSnapshot) -> [RawEvent] {
        var result: [RawEvent] = []

        for event in snapshot.events {
            let key = "\(event.id)|\(event.start.timeIntervalSince1970)"
            result.append(RawEvent(
                id: RiverStableIdentifier.uuid(namespace: "mac.calendar.event", key: key),
                timestamp: event.start,
                source: .calendar,
                kind: .calendarEvent,
                payload: RawEventPayload(
                    text: event.title,
                    sessionEnd: event.end,
                    calendarName: event.calendarName,
                    isAllDay: event.isAllDay,
                    attendeeCount: event.attendeeCount
                ),
                sourceHash: "\(key)|\(event.end.timeIntervalSince1970)"
            ))
        }

        for reminder in snapshot.reminders {
            let key = "\(reminder.id)|\(reminder.completedAt.timeIntervalSince1970)"
            result.append(RawEvent(
                id: RiverStableIdentifier.uuid(namespace: "mac.reminder.completed", key: key),
                timestamp: reminder.completedAt,
                source: .reminders,
                kind: .reminderCompleted,
                payload: RawEventPayload(text: reminder.title, calendarName: reminder.listName),
                sourceHash: key
            ))
        }

        return result
    }
}
