import SwiftUI

struct AISettingsView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    var body: some View {
        AIConnectionCard(ai: ai)
            .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
    }
}
