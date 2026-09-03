import SwiftUI

struct EntryDetailView: View {
    let entry: DiaryEntry
    @State private var section: DetailSection = .overview

    enum DetailSection: String, CaseIterable, Identifiable {
        case overview, thoughts, activity, data, plan
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "概览"
            case .thoughts: "想法"
            case .activity: "事项"
            case .data: "数据"
            case .plan: "计划"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                Picker("内容", selection: $section) {
                    ForEach(DetailSection.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                switch section {
                case .overview: overview
                case .thoughts: thoughts
                case .activity: activity
                case .data: dataSection
                case .plan: plan
                }
            }
            .padding(16)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(entry.shortDate)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(entry.entryDate, style: .date)
                        .font(.title3.weight(.bold))
                    Spacer()
                    Text(entry.score.map { String(format: "%.0f", $0) } ?? "—")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(entry.stageColor)
                }
                Text("\(entry.stageLabel) · 成长 \(Int(entry.metrics?.growth ?? 0))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let tags = entry.tags, !tags.isEmpty {
                    HStack(spacing: 7) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(.quaternary.opacity(0.6), in: .capsule)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var overview: some View {
        GlassCard {
            Text(entry.overview ?? "这一天没有概览。")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thoughts: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                if (entry.thoughts ?? []).isEmpty && (entry.memos ?? []).isEmpty {
                    Text("没有想法记录。").foregroundStyle(.secondary)
                }
                ForEach(entry.thoughts ?? [], id: \.self) { thought in
                    Label {
                        Text(thought).font(.callout)
                    } icon: {
                        Image(systemName: "text.quote")
                    }
                }
                ForEach(entry.memos ?? [], id: \.self) { memo in
                    Label {
                        Text(memo).font(.callout)
                    } icon: {
                        Image(systemName: "note.text")
                    }
                }
            }
        }
    }

    private var activity: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(entry.activities ?? []) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.subtitle).font(.headline)
                        ForEach(group.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle().fill(.indigo).frame(width: 5, height: 5).padding(.top, 7)
                                Text(item).font(.callout)
                            }
                        }
                    }
                }
                if (entry.activities ?? []).isEmpty {
                    Text("没有事项记录。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dataSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    dataStat("屏幕", value: entry.screenHours.map { String(format: "%.1f 小时", $0) } ?? "—")
                    dataStat("浏览", value: entry.views.map { "\($0) 次" } ?? "—")
                    dataStat("应用", value: "\(entry.screenApps?.count ?? 0) 个")
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("常用应用").font(.headline)
                    let apps = (entry.screenApps ?? []).prefix(6)
                    if apps.isEmpty {
                        Text("没有屏幕数据。").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(apps)) { app in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(app.app)
                                    Spacer()
                                    Text(app.time ?? "\(app.resolvedMinutes)m")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                                ProgressView(value: Double(app.resolvedMinutes), total: Double(max(240, app.resolvedMinutes)))
                                    .tint(.indigo)
                            }
                        }
                    }
                }

                let sites = (entry.browseSites ?? []).prefix(6)
                if !sites.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("常访站点").font(.headline)
                        ForEach(Array(sites)) { site in
                            HStack {
                                Text(site.site)
                                    .font(.footnote)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(site.count) 次")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let note = entry.screenNote, !note.isEmpty {
                    noteBlock("屏幕观察", note)
                }

                if let note = entry.browseNote, !note.isEmpty {
                    noteBlock("浏览观察", note)
                }
            }
        }
    }

    private var plan: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.plan?.isEmpty == true ? "没有明日计划。" : (entry.plan ?? "没有明日计划。"))
                    .font(.callout)
                    .foregroundStyle(entry.plan == nil || entry.plan?.isEmpty == true ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let buddy = entry.workBuddy, !buddy.isEmpty {
                    Label(buddy, systemImage: "person.2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func dataStat(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 14, style: .continuous))
    }

    private func noteBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary)
                        }
    }
}
