import SwiftUI

struct SettingsRedesignView: View {
    @ObservedObject var store: DiaryStore
    @ObservedObject var activity: ActivityStore
    @ObservedObject var ai: AIAssistantStore
    @ObservedObject var ingestion: DataIngestionStore

    @State private var showsAI = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                statusOverview
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
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showsAI) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("AI 连接")
                        .font(.editorial(17, weight: .semibold))
                    Spacer()
                    Button("关闭") { showsAI = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
                AIConnectionCard(ai: ai)
            }
            .padding(24)
            .frame(width: 620)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.editorial(28, weight: .semibold))
                .foregroundStyle(Color.ink)
            Text("Every record is yours to decide how it stays.")
                .font(.ui(11))
                .foregroundStyle(Color.secondaryInk)
        }
    }

    private var statusOverview: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuietSectionHeader(title: "当前状态")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    StatusDot(
                        level: activity.isTracking ? .ok : .idle,
                        label: activity.isTracking ? "正在记录当前活动" : "记录已暂停"
                    )

                    HStack(spacing: 8) {
                        ingestionDot
                        Button {
                            ingestion.captureNow()
                        } label: {
                            Label("立即采集", systemImage: "arrow.down.circle")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(ingestion.isRunning)
                    }

                    HStack(spacing: 8) {
                        StatusDot(
                            level: ai.hasVerifiedConnection ? .ok : .idle,
                            label: ai.hasVerifiedConnection
                                ? "已连接 \(ai.profileName)"
                                : (ai.isConfigured ? "已配置，等待验证" : "未连接 AI（本地模式可用）")
                        )
                        Button {
                            showsAI = true
                        } label: {
                            Label("配置 AI", systemImage: "slider.horizontal.3")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }

    @ViewBuilder
    private var ingestionDot: some View {
        if let error = ingestion.lastError, !error.isEmpty {
            StatusDot(level: .error, label: "采集有问题：\(error)")
        } else if ingestion.isRunning {
            StatusDot(level: .running, label: "正在采集数据源")
        } else if ingestion.lastIngestedAt != nil {
            StatusDot(level: .ok, label: "上次采集 \(ingestion.lastIngestedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")")
        } else {
            StatusDot(level: .idle, label: "尚未采集")
        }
    }
}
