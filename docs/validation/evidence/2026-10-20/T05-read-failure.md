# T05 读取失败：报告、拒绝覆盖、保留救援文件

日期：2026-10-20（Asia/Shanghai）
状态：**T05 读取失败路径已补自动证据；磁盘满/SQL 失败注入、强杀与重试去重仍待。**

## 1. 本轮发现

`DiaryStore` 的读取失败保护其实已经写进代码：

- `localStateReadFailed` 在解密/解码/旧版迁移失败时置位；
- 各保存入口（月信、时间线标注、保存查询、每日目标、日记草稿、写字等）都以
  `guard !localStateReadFailed else { throw … }` 拒绝写入；
- 旧版 `user-state.json` 只有在成功迁移后才删除。

但整个 Mac 测试目标里**没有任何用例**证明这些行为成立。磁盘上的加密状态一旦
损坏，如果保护失效，下一次保存就会把原文件覆盖成一份“空日记”，用户再也无法
用恢复能力救回。本轮先把这条底线变成可回归的证据。

## 2. 新增测试

文件：`macos/RiverDiaryMac/Tests/RiverDiaryMacTests/StorageReadFailureTests.swift`（3 项）

| 用例 | 断言 |
|---|---|
| `testCorruptEncryptedStateIsReportedAndNeverOverwritten` | 损坏的 `journal.state` 会设置 `loadError`；`entries` 为空；保存被拒绝；原文件字节保持不变 |
| `testCorruptLegacyStateIsNotDeletedOrReplaced` | 损坏的 `user-state.json` 会报错；文件不被删除、内容不变（迁移失败不能吃掉原件） |
| `testReadFailureBlocksEveryUserFacingSavePath` | 保存查询、时间线标注、每日目标、日记草稿四条用户写入路径全部抛错 |

结果：3 项通过；macOS 全量测试从 423 增至 **426 项**。

## 3. 仍未完成

- **磁盘满**：没有真正写满卷或用注入式文件系统模拟 `ENOSPC`；当前只有“读取失败”阻断写。
- **SQL 失败注入**：V2Store 的 prepare/commit 失败、只读数据库、锁冲突没有专门用例。
- **强杀**：没有在写入窗口内强杀进程再验证不半提交（原子写依赖系统语义，但缺证据）。
- **重试不重复**：保存失败后重试是否只产生一条记录，缺少直接用例（复制批次的幂等已有测试）。
- **iOS**：iOS 端读取失败（`RiverLocalDatabase` 打开失败、草稿读取失败）仍无自动测试，runner 未修复。
- **界面层**：读取失败时“不要显示成空记录”只有 store 层断言，未验证界面是否真的展示错误态。
- **外部快照损坏**：`externalSnapshotPath` 指向损坏文件时的提示未测。
