import SwiftUI

struct SettingsRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings")
                    .font(.editorial(28, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Every record is yours to decide how it stays.")
                    .font(.ui(11))
                    .foregroundStyle(Color.secondaryInk)

                PrivacyView(
                    store: store,
                    activity: activity,
                    ai: ai,
                    ingestion: ingestion,
                    showsHeader: false
                )
                .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
