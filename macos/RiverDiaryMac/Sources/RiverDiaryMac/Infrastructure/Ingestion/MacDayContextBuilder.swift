import Foundation
import RiverDiaryCore

/// 把 Mac 今天采集到的各来源压成一份跨端可读的日上下文。
/// 只放摘要/标题/计数/短摘录，避免把 URL 全量、备忘录全文直接复制到手机和网页。
enum MacDayContextBuilder {
    static func build(
        day: String,
        now: Date = Date(),
        deviceID: String,
        deviceName: String,
        browser: BrowserHistoryReadResult?,
        notes: [DailyNoteEntry],
        markdown: [DailyNoteEntry],
        kindle: [DailyNoteEntry],
        calendar: CalendarContextSnapshot?,
        weather: WeatherContext?,
        git: GitActivityReadResult?,
        screen: ScreenTimeSnapshot?,
        shareBrowserURLs: Bool = false,
        shareNoteBodies: Bool = false,
        shareMarkdownBodies: Bool = false,
        shareKindleBodies: Bool = false
    ) -> DayContextSnapshot? {
        var sections: [DayContextSection] = []

        if let browser, !browser.visits.isEmpty {
            let domains = BrowserHistoryReader.topDomains(from: browser.visits, limit: 5)
            let pageTitles = browser.visits.prefix(10).compactMap { visit -> DayContextItem? in
                let title = visit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return DayContextItem(
                    title: title,
                    detail: shareBrowserURLs ? visit.url : [visit.browser, visit.domain].compactMap { $0 }.joined(separator: " · "),
                    at: visit.visitedAt
                )
            }
            sections.append(DayContextSection(
                kind: "browser",
                title: "浏览",
                summary: "\(browser.visits.count) 次访问 · \(domains.prefix(3).joined(separator: "/"))",
                items: pageTitles + domains.map { DayContextItem(title: $0, count: nil) }
            ))
        }

        appendNotes(notes, kind: "notes", title: "备忘录", includeBody: shareNoteBodies, sections: &sections)
        appendNotes(markdown, kind: "markdown", title: "Markdown", includeBody: shareMarkdownBodies, sections: &sections)
        appendNotes(kindle, kind: "kindle", title: "Kindle 划线", includeBody: shareKindleBodies, sections: &sections)

        if let calendar, !calendar.events.isEmpty || !calendar.reminders.isEmpty {
            var items: [DayContextItem] = calendar.events.prefix(10).map { event in
                DayContextItem(
                    title: event.title,
                    detail: event.isAllDay ? "全天" : "\(time(event.start))–\(time(event.end))",
                    at: event.start
                )
            }
            items += calendar.reminders.prefix(5).map { reminder in
                DayContextItem(title: "完成：\(reminder.title)", detail: reminder.listName, at: reminder.completedAt)
            }
            sections.append(DayContextSection(
                kind: "calendar",
                title: "日程与提醒",
                summary: "\(calendar.events.count) 个日程 · \(calendar.reminders.count) 个完成提醒",
                items: items
            ))
        }

        if let weather {
            sections.append(DayContextSection(
                kind: "weather",
                title: "天气",
                summary: weather.summary
            ))
        }

        if let git, !git.repos.isEmpty {
            sections.append(DayContextSection(
                kind: "git",
                title: "代码提交",
                summary: "\(git.totalCommits) 次提交 · \(git.repos.count) 个仓库",
                items: git.repos.prefix(10).map { repo in
                    DayContextItem(title: repo.name, count: repo.commits)
                }
            ))
        }

        if let screen {
            if screen.focusMinutes > 0 {
                let hours = Double(screen.focusMinutes) / 60
                sections.append(DayContextSection(
                    kind: "focus",
                    title: "专注",
                    summary: String(format: "%.1f 小时 · %d 段", hours, screen.focusBlocks)
                ))
            }
            if screen.totalMinutes > 0 {
                let hours = Double(screen.totalMinutes) / 60
                sections.append(DayContextSection(
                    kind: "screenTime",
                    title: "屏幕",
                    summary: String(format: "%.1f 小时", hours),
                    items: screen.topApps.prefix(3).map { DayContextItem(title: $0) }
                ))
            }
        }

        guard !sections.isEmpty else { return nil }
        return DayContextSnapshot(
            deviceID: deviceID,
            deviceName: deviceName,
            day: day,
            generatedAt: now,
            sections: sections
        )
    }

    private static func appendNotes(
        _ entries: [DailyNoteEntry],
        kind: String,
        title: String,
        includeBody: Bool,
        sections: inout [DayContextSection]
    ) {
        guard !entries.isEmpty else { return }
        let limit = includeBody ? 20_000 : 160
        let items = entries.prefix(20).map { note in
            DayContextItem(
                title: note.title,
                detail: note.body.map { String($0.prefix(limit)) },
                at: note.modifiedAt
            )
        }
        sections.append(DayContextSection(
            kind: kind,
            title: title,
            summary: "\(entries.count) 条",
            items: items
        ))
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
