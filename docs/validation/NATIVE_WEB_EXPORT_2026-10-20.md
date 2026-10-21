# 原生网页副本导出验收 · 2026-10-20

状态：**Mac app 构建通过；iOS 全部 Swift 源码通过 SwiftPM 编译（Xcode app bundle/安装受本机 SwiftPM 清单缓存权限阻塞）；完整 V2 字段（长期记忆/随手记/合集/理解卡）与真实数据导入待验（T12/T44）**。

## 1. 为什么补这个入口

此前网页控制台要求用户导入 JSON，但原生 App 没有清楚的“给网页看的副本”入口。Mac 的隐私设置里有一个藏在“恢复备份”行内的“可读 JSON”按钮，iPhone 只有加密备份。用户无法从正常路径把真实日记带到网页；控制台因此只能看示例或手动构造的 JSON。

本次把 Mac/iOS 的“网页控制台副本”作为明确入口加入源码：

- Mac：设置 → 隐私与备份 → 网页控制台副本 → 导出 JSON。
- iPhone：设置 → 导出我的记录 → 网页控制台 → 导出网页可读 JSON。
- 导出内容是 `river.memory-mirror` v1 信封；条目由当前本机可读的 `DiaryData` 转换而来，合集/理解卡暂为空。不是加密备份，不含同步密钥。
- 共享转换器 `MemoryMirrorArchive.legacy(fromDiaryJSON:)` 负责字段映射；4 项 core 测试通过，并用生成的 mirror JSON 在 Node 网页侧 `normalizeArchive` 验证可读。

## 2. 代码路径

- macOS：`PrivacyBackupSettingsView` 新增“网页控制台副本”面板行；`exportReadableJSON(filenamePrefix:)` 调用 `DiaryStore.webMirrorData()`，由 core 转换并写出 `.json`。
- iOS：`SettingsView` 新增“网页控制台”Section、`ReadableDiaryDocument` 与 `.fileExporter`；`exportReadableDiary()` 调用 `store.webMirrorData()`。没有可读日记时禁用按钮并提示。
- 共享模型：`Packages/RiverDiaryCore/Sources/RiverDiaryCore/MemoryMirrorExport.swift`，测试 `MemoryMirrorExportTests.swift`。
- 网页：空态/来源说明改为给出双端路径，不再笼统写“导出入口仍在接入”；仍保留“完整记忆镜像仍在接入（T12）”。

## 3. 构建与验证

### 3.1 macOS

```sh
DEVELOPER_DIR=/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer \
RIVER_BUILD_CONFIG=debug CODESIGN_IDENTITY=- \
RIVER_APP_OUTPUT_DIR=/tmp/RiverDiaryMirror.app \
./macos/RiverDiaryMac/make_app.sh
```

结果：**Build complete! (14.19 秒)**，生成的临时 app 位于 `/tmp/RiverDiaryMirror.app`（未签名开发包，仅验证编译与打包路径，不是分发产物）。可执行文件 SHA-256 `bd1e01244c1f223472102deca86fc6cef8b647f1838e8a884c931c89a399543e`。源代码编译通过，core 转换与新增面板行已参与构建。

### 3.2 iOS

- 用 macOS SwiftPM 运行 `RiverDiaryCore` 全部测试：**67 项通过**，其中 `MemoryMirrorExportTests` 4 项。
- 用 iOS 模拟器 SDK 构建包含转换器的共享 `RiverDiaryCore` 成功。
- 用临时 SwiftPM 包把 `ios/RiverDiary/RiverDiary` 的全部 Swift 源文件编译为 iOS simulator 可执行目标：**Build complete! (10.46 秒)**。`SettingsView`、`DiaryStore` 和转换器均通过编译/类型检查；这不是完整 app bundle，未处理 Info.plist、entitlements、资源打包、签名或安装。
- 完整 `xcodebuild` 未完成：本机 `~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/riverdiarycore.dia` 受系统 provenance/沙箱限制，报 `Operation not permitted`；这是本机构建缓存权限问题，不是源码编译错误。不能据此宣称 iOS app 已构建。

### 3.3 网页导入兼容

用共享转换器把同形状合成 `DiaryData` 转成实际 `river.memory-mirror` JSON（样本见 [native-mirror-sample.json](evidence/2026-10-20/native-mirror-sample.json)），再调用网页 `normalizeArchive`：

- `format: river.memory-mirror`、`ok: true`，1 段；
- `persona.name` 为“林岸”；
- `title` 保留；
- `overview + thoughts` 合成正文；
- `did[].items` 成为 facts；
- `tags`、`mood` 保留；
- 页面按只读 mirror 读取，不把示例当真实数据。

并在生产预览 `https://user.flowriver.xyz/?preview=1` 把该文件实际导入：首页显示“窗边的十分钟”和正文，无 `compose` 按钮，无控制台错误。截图见 [26-native-mirror-imported-desktop](../../output/qa/user-console-2026-10-20/26-native-mirror-imported-desktop.png)。

该验证是合成样本，不是“真实用户日记导入”证据。

## 4. 明确未完成

- 当前 mirror 的 entries 来自旧版 `DiaryData`；V2 长期记忆、随手记、合集/理解卡尚未映射，`collections`/`understandings` 仍为空。
- iOS 源码编译通过，但完整 app bundle、Xcode 打包、真机和分发未验证；当前安装包不包含新入口。
- 未用真实个人日记执行“原生导出 → 网页导入 → 云空间上传 → 另一设备恢复”的端到端旅程。
- 未验证大日记、照片/健康数据边界、旧版/新版混合数据与导出权限。
- 网页仍只读，不提供网页速记或编辑。

## 5. 下一步

1. 在可用的 Xcode/SwiftPM 缓存环境完成 iOS 构建，安装到模拟器/真机验证导出面板。
2. 用用户主动选择的真实副本走完整链路，记录字段丢失与体积。
3. 把 V2 记忆/合集/理解卡映射进 `river.memory-mirror`；优先保证“原话 + 日期 + 来源”不丢。
4. 统一双端文件名、入口位置和“旧版日记/完整镜像”措辞，避免再次让用户误以为网页已同步。

构建指纹见 [native-web-export-build.json](evidence/2026-10-20/native-web-export-build.json)。

详细规则仍以 [主规划](../../主规划.md) T12/T44/T45 为准；网页侧导入/云空间见 [控制台验收](USER_MEMORY_CONSOLE_2026-10-20.md) 与 [云空间验收](USER_MEMORY_CLOUD_2026-10-20.md)。
