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
                        .font(.editorial(32))
                        .foregroundStyle(Color.ink)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient.river())
                        .frame(width: 28, height: 3)
                        .offset(y: 6)
                }

                Text(caption)
                    .font(.ui(13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }

            Spacer(minLength: 16)

            HStack(spacing: 4) {
                ForEach(tabs, id: \.self) { tab in
                    let selected = selection == tab
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) {
                            selection = tab
                        }
                    } label: {
                        Text(titleFor(tab))
                            .font(.ui(12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.ink : Color.secondaryInk)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.strongSurface)
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.separator, lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.softPress)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.border.opacity(0.7), lineWidth: 1))
            .frame(width: min(CGFloat(tabs.count) * 112, 420))
        }
        .frame(maxWidth: AppLayout.contentMaxWidth, alignment: .leading)
        .padding(.bottom, 2)
    }
}

struct TimeFlowView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @Binding var selectedDate: Date
    @Binding var section: TimeSection
    var openDiary: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if section != .activity {
                FlowPageHeader(
                    title: "时间",
                    caption: "沿着时间，找回做过的事与当时的感受。",
                    selection: $section,
                    tabs: TimeSection.displayOrder,
                    titleFor: \.title
                )
            } else {
                HStack(spacing: 22) {
                    ForEach(TimeSection.displayOrder) { item in
                        Button { section = item } label: {
                            Text(item.title)
                                .font(.system(size: 12, weight: section == item ? .semibold : .regular))
                                .foregroundStyle(section == item ? Color.ink : Color.secondaryInk)
                                .padding(.bottom, 8)
                                .overlay(alignment: .bottom) {
                                    if section == item { Capsule().fill(Color.riverAmethyst).frame(height: 2) }
                                }
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Text("你的生活，自有节奏").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }

            switch section {
            case .river:
                RiverView(
                    entries: store.entries,
                    selectedDate: selectedDate,
                    ai: ai,
                    showsHeader: false
                )
            case .rhythm:
                RhythmView(
                    store: store,
                    activity: activity,
                    anchorDate: $selectedDate,
                    showsHeader: false
                )
            case .activity:
                ActivityView(
                    activity: activity,
                    selectedDate: $selectedDate,
                    ai: ai,
                    entries: store.entries,
                    quickCaptures: store.quickCaptures[DiaryEntry.dateFormatter.string(from: selectedDate)] ?? [],
                    showsHeader: false,
                    addCapture: {
                        store.addQuickCapture($0, for: selectedDate)
                        if case .failed(let message) = store.saveState {
                            throw NSError(domain: "RiverDiaryMac", code: 40, userInfo: [NSLocalizedDescriptionKey: message])
                        }
                    },
                    openDiary: openDiary,
                    annotations: store.timelineAnnotations,
                    saveAnnotation: { key, annotation in try store.saveTimelineAnnotation(annotation, for: key) },
                    additionalRecordedDays: Set(store.quickCaptures.filter { !$0.value.isEmpty }.keys)
                )
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: AppLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MemoryFlowView: View {
    @ObservedObject var ai: AIAssistantStore
    let entries: [DiaryEntry]
    let quickCaptures: [QuickCapture]
    var assignedCaptures: [String: [QuickCapture]] = [:]
    @Binding var section: MemorySection
    let openDate: (Date) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowPageHeader(
                title: "记忆",
                caption: "那些写下的、想过的，随时可以再翻一遍。",
                selection: $section,
                tabs: MemorySection.displayOrder,
                titleFor: \.title
            )

            MemoryView(
                ai: ai,
                entries: entries,
                quickCaptures: quickCaptures,
                assignedCaptures: assignedCaptures,
                section: $section,
                showsHeader: false
            ) { date in
                openDate(date)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: AppLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
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
            showsHeader: true
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
        VStack(alignment: .leading, spacing: 12) {
            FlowPageHeader(
                title: "设置",
                caption: "每一份记录，都由你决定如何留下。",
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
            case .data:
                DataExplorerView(
                    store: store,
                    ingestion: ingestion,
                    selectedDate: $selectedDate,
                    showsHeader: false
                )
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: AppLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}
