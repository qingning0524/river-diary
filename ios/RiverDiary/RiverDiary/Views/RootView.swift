import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            RiverNodeTimelineView()
                .tabItem { Label("时间线", systemImage: "timeline.selection") }

            RiverReviewView()
                .tabItem { Label("回顾", systemImage: "checkmark.seal.fill") }

            TodayView()
                .tabItem { Label("今日", systemImage: "heart.text.square.fill") }

            RiverView()
                .tabItem { Label("河流", systemImage: "water.waves") }

            JournalView()
                .tabItem { Label("日记", systemImage: "book.closed.fill") }

            InsightsView()
                .tabItem { Label("洞察", systemImage: "chart.xyaxis.line") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
