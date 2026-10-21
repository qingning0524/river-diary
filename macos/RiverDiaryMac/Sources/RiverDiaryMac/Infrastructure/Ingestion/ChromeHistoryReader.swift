import Foundation

/// 兼容入口。读取逻辑已扩展到 Safari/Arc/Edge/Brave，统一放在
/// `BrowserHistoryReader`；这里只保留旧的域名工具，避免外部调用断裂。
enum ChromeHistoryReader {
    static func extractDomain(from urlString: String) -> String {
        BrowserHistoryReader.extractDomain(from: urlString)
    }

    static func topDomains(from visits: [ChromeVisit], limit: Int = 5) -> [String] {
        BrowserHistoryReader.topDomains(from: visits, limit: limit)
    }
}
