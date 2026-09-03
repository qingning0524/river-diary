import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var health: HealthKitStore
    @EnvironmentObject private var store: DiaryStore
    @EnvironmentObject private var drive: ICloudDriveStore
    @State private var showsScoreResetConfirmation = false
    @State private var showFolderPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section("系统集成") {
                    healthRow
                    screenTimeRowUnavailable
                    iCloudDriveRow
                }

                Section("数据") {
                    LabeledContent("记录天数", value: "\(store.entries.count)")
                    LabeledContent("数据生成时间", value: store.data?.generated ?? "—")
                    LabeledContent("本地存储", value: "心情评分仅本机")
                    Button {
                        showsScoreResetConfirmation = true
                    } label: {
                        Text("还原本地评分")
                            .foregroundStyle(.red)
                    }
                    .disabled(!store.hasLocalScoreEdits)
                }

                Section {
                    Text("HealthKit 只读取睡眠和运动数据的每日汇总，并同步到 iCloud Drive。屏幕时间不会上传。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("隐私原则")
                }
            }
            .navigationTitle("设置")
            .confirmationDialog(
                "还原本地评分",
                isPresented: $showsScoreResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("还原全部评分", role: .destructive) {
                    store.resetLocalScores()
                }
            } message: {
                Text("所有修改过的评分都会恢复为导入时的数值。")
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        drive.handlePickedFolder(url)
                    }
                case .failure(let error):
                    drive.lastError = error.localizedDescription
                }
            }
        }
    }

    private var healthRow: some View {
        HStack {
            Label("Apple 健康", systemImage: "heart.text.square.fill")
            Spacer()
            if health.isLoading {
                ProgressView()
            } else if health.isAuthorized {
                Button("已连接 · \(health.nights.count) 晚 · \(health.exerciseDays.count) 天") { health.loadHealth() }
            } else {
                Button("连接") { health.requestAuthorization() }
            }
        }
    }

    private var screenTimeRowUnavailable: some View {
        HStack {
            Label("屏幕使用时间", systemImage: "iphone.gen3.radiowaves.left.and.right")
            Spacer()
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
        }
    }

    private var iCloudDriveRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("iCloud Drive 同步", systemImage: "icloud")
                Spacer()
                if drive.isWriting {
                    ProgressView()
                } else if drive.hasAccess {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("选择文件夹") { showFolderPicker = true }
                }
            }

            if let error = drive.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if drive.hasAccess {
                Text("已连接。修改心情后会自动保存到 iCloud Drive。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("首次使用需选择一个 iCloud Drive 文件夹，之后自动同步。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
