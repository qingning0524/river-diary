import SwiftUI

struct FlowPageHeader<Tab: Hashable>: View {
    let title: String
    let caption: String
    @Binding var selection: Tab
    let tabs: [Tab]
    let titleFor: (Tab) -> String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(title)
                        .font(.editorial(34))
                        .foregroundStyle(Color.ink)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient.river())
                        .frame(width: 28, height: 3)
                        .offset(y: 6)
                }

                Text(caption)
                    .font(.ui(12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Spacer(minLength: 16)

            Picker(title, selection: $selection.animation(.easeOut(duration: 0.2))) {
                ForEach(tabs, id: \.self) { tab in
                    Text(titleFor(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.riverAmethyst)
            .controlSize(.large)
            .frame(width: min(CGFloat(tabs.count) * 122, 460))
        }
        .frame(maxWidth: 1280, alignment: .leading)
    }
}

struct TimeFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    @Binding var section: TimeSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FlowPageHeader(
                    title: "时间",
                    caption: "过去发生了什么：感受、状态和屏幕足迹。",
                    selection: $section,
                    tabs: TimeSection.allCases,
                    titleFor: \.title
                )

                switch section {
                case .river:
                    RiverView(
                        entries: store.entries,
                        selectedDate: selectedDate,
                        ai: ai,
                        showsHeader: false
                    )
                    .background(.clear)
                case .rhythm:
                    RhythmView(
                        store: store,
                        activity: activity,
                        anchorDate: $selectedDate,
                        showsHeader: false
                    )
                    .background(.clear)
                case .activity:
                    ActivityView(
                        activity: activity,
                        selectedDate: $selectedDate,
                        ai: ai,
                        entries: store.entries,
                        quickCaptures: store.quickCaptures[DiaryEntry.dateFormatter.string(from: selectedDate)] ?? [],
                        showsHeader: false
                    )
                    .background(.clear)
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }
}

struct MemoryFlowView: View {
    @ObservedObject var ai: AIAssistantStore
    let entries: [DiaryEntry]
    let quickCaptures: [QuickCapture]
    @Binding var section: MemorySection
    let openDate: (Date) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FlowPageHeader(
                    title: "记忆",
                    caption: "找回以前的字句、随笔和重复出现的感受。",
                    selection: $section,
                    tabs: MemorySection.displayOrder,
                    titleFor: \.title
                )

                MemoryView(
                    ai: ai,
                    entries: entries,
                    quickCaptures: quickCaptures,
                    section: $section,
                    showsHeader: false
                ) { date in
                    openDate(date)
                }
                .background(.clear)
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }
}

struct InsightFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date

    var body: some View {
        AIAnalysisView(
            store: store,
            activity: activity,
            ai: ai,
            anchorDate: $selectedDate,
            showsHeader: false
        )
        .background(.clear)
    }
}

struct SystemFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore
    @Binding var selectedDate: Date
    @Binding var section: SystemSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                FlowPageHeader(
                    title: "系统",
                    caption: "管理数据源、实时采集、AI 连接和本地备份。",
                    selection: $section,
                    tabs: SystemSection.allCases,
                    titleFor: \.title
                )

                switch section {
                case .controls:
                    PrivacyView(
                        store: store,
                        activity: activity,
                        ai: ai,
                        ingestion: ingestion,
                        showsHeader: false
                    )
                    .background(.clear)
                case .data:
                    DataExplorerView(
                        ingestion: ingestion,
                        selectedDate: $selectedDate,
                        showsHeader: false
                    )
                    .background(.clear)
                }
            }
            .frame(maxWidth: 1280, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
    }
}
