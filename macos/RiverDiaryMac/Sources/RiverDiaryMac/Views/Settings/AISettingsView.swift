import SwiftUI

struct AISettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    var body: some View {
        // 与其余三个分类一致地走 SettingsPage：提供滚动容器与页边距。
        // 裸放卡片时它没有滚动容器（内容超出 620pt 窗口高会被裁掉够不着），
        // 且 920pt 的版心上限在设置窗口里没有意义。
        SettingsPage {
            AIConnectionCard(ai: ai)
        }
    }
}
