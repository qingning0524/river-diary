# T05 读取失败：报告、拒绝覆盖、保留救援文件

日期：2026-10-20（Asia/Shanghai）
状态：**T05 读取失败与保存失败重试已补自动证据；真实 ENOSPC、SQL 失败注入、强杀与 iOS 仍待。**

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

## 3. 保存失败：保留旧值、重试不重复

文件：`macos/RiverDiaryMac/Tests/RiverDiaryMacTests/SaveFailureTests.swift`

1. 先成功保存「第一版」，记录 `journal.state` 字节与解码内容；
2. 把支持目录设为 `0o500`（原子写无法在同目录建临时文件，等价于写不进去）；
3. 保存「第二版」必须抛错；断言状态文件**字节不变**、解码后仍是「第一版」；
4. 恢复权限后重试同一保存：状态里只有**一条**记录，内容为「第二版」。

这条用例覆盖“写失败保留旧值和文字、恢复后重试不重复”，同时证明失败不会先在内存里改成新值再假装保存。

## 3. 仍未完成

- **磁盘满**：用“目录不可写”模拟了写失败，但没有真正制造 `ENOSPC`；两者错误码与部分路径不同。
- **SQL 失败注入**：V2Store 的 prepare/commit 失败、只读数据库、锁冲突没有专门用例。
- **强杀**：没有在写入窗口内强杀进程再验证不半提交（原子写依赖系统语义，但缺证据）。
- **iOS**：iOS 端读取失败（`RiverLocalDatabase` 打开失败、草稿读取失败）仍无自动测试，runner 未修复。
- **界面层**：读取失败时“不要显示成空记录”只有 store 层断言，未验证界面是否真的展示错误态。
- **外部快照损坏**：`externalSnapshotPath` 指向损坏文件时的提示未测。
