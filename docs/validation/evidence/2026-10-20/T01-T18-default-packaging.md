# T01 / T18 默认公开打包验证

日期：2026-10-20（Asia/Shanghai）

## 已完成

- macOS：使用隔离 SwiftPM scratch 目录构建 Release app，ad-hoc 签名；`codesign --verify --deep --strict` 通过。检查 `Contents` 未发现 `data.json`、`ios-user-data.json` 或 `river-diary-user-data.json`。构建指纹见同目录 `macos-release-provenance.json`。
- iOS：`RiverDiary` scheme 的 Release iOS Simulator 构建成功（Xcode beta，iOS Simulator SDK 27.0，未运行测试）。检查 `.app` 未发现上述三种快照文件。
- iOS 工程：`project.pbxproj` 的 `plutil -lint` 通过。正式 app target 排除本地 `Resources/data.json`；QA target 保留独立 fixture 路径。
- 网站：发布目录 `website/site`、`website/login`、`website/user` 未发现上述快照文件名。扫描发现 `website/site/downloads/RiverDiary-macOS-20261001.zip` 内含 `RiverDiary.app/Contents/Resources/RiverDiaryMac_RiverDiaryMac.bundle/Contents/Resources/data.json`。该 ZIP 与 `.sha256` 已移出仓库，隔离保存在 `~/Library/Application Support/RiverDiary/Quarantine/2026-10-20/`，原 ZIP SHA-256 为 `0858b9821c959489f1f01cb9d20f3ae7e5a9ccdadaabdddd4ca8fb510dacb0ed`。网站 README 发布命令现排除本地 `downloads/`，新版本仍应通过服务端下载发布路径管理。
- 空资料路径：代码检查确认 iOS `DiaryStore` 在 bundle 无 `data.json` 时建立空 `DiaryData`，Mac `DiaryStore` 在无资源快照时建立空日记状态并调用 ready 回调；本轮未实际启动应用验证交互。

## 尚未完成

- 未执行合成敏感标记在所有打包/网站路径中的端到端验证。
- 未运行应用验证空资料首次启动与后续导入。
- 未部署或核验生产站点/下载服务，因此不能据此声称生产环境已清除旧包。
- T01 的完整源码来源冻结、干净目录构建和关键 skip 门禁仍未完成。provenance 指纹对应当时未提交工作树，仅作为构建快照证据。

## 产物位置

- macOS 临时构建：`/tmp/river-diary-t18-2026-10-20.app`（验证后保留在本机临时目录）
- iOS 临时构建：`/tmp/river-diary-t18-ios-derived-2026-10-20/Build/Products/Release-iphonesimulator/RiverDiary.app`
- Mac provenance：`docs/validation/evidence/2026-10-20/macos-release-provenance.json`
