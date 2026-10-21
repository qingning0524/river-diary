import Foundation
import RiverDiaryCore

/// 把 Mac 的笔记/Markdown/Kindle/浏览明细转成独立的 V2 Event。
///
/// 只有用户打开逐来源全文同步时才调用；这些事件是证据层，界面主要仍读
/// DayContext（避免手机时间线被几百条浏览记录刷屏）。
enum MacRawEventBuilder {
    static let maximumBrowserVisits = 500

    static func noteEvents(
        _ notes: [DailyNoteEntry],
        source: RawEventSource,
        namespace: String
    ) -> [RawEvent] {
        notes.compactMap { note in
            let body = note.body ?? ""
            let hash = SHA256Hex.hash(Data("\(note.title)|\(note.modifiedAt.timeIntervalSince1970)|\(body)".utf8))
            return RawEvent(
                id: RiverStableIdentifier.uuid(namespace: namespace, key: hash),
                timestamp: note.modifiedAt,
                source: source,
                kind: .noteModified,
                payload: RawEventPayload(text: body, title: note.title),
                sourceHash: hash
            )
        }
    }

    static func browserEvents(_ visits: [ChromeVisit], limit: Int = maximumBrowserVisits) -> [RawEvent] {
        visits.prefix(limit).map { visit in
            let key = "\(visit.url)|\(visit.visitedAt.timeIntervalSince1970)"
            let hash = SHA256Hex.hash(Data(key.utf8))
            return RawEvent(
                id: RiverStableIdentifier.uuid(namespace: "mac.browser.visit", key: key),
                timestamp: visit.visitedAt,
                source: .chrome,
                kind: .urlVisit,
                payload: RawEventPayload(url: visit.url, text: visit.title, title: visit.title),
                sourceHash: hash
            )
        }
    }
}
