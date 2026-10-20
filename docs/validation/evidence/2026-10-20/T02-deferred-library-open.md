# T02 首次未绑定不再创建正式库

日期：2026-10-20（Asia/Shanghai）
状态：**T02 第一切片完成（延迟开库 + 退出关库）；统一系统入口、旧安装救援界面与真实登录/退出旅程仍待。**

## 1. 问题

T18 的空资料取证发现：全新安装、尚未登录时，Mac 应用在 `RiverDiaryMacApp.init()` 里无条件构造 `V2Store`，启动即创建：

- `Library/Application Support/RiverDiaryMac/Database/V2/river-v2.db`
- `Library/Application Support/RiverDiaryMac/journal-encryption.key`

这与主规划 §7.2 “首次未绑定不开正式库” 不一致，也让“一个从未登录过的人本机已经有正式资料命名空间”。

## 2. 改动

| 位置 | 改动 |
|---|---|
| `V2Store` | 新增 `opensImmediately` 初始化参数与 `openIfNeeded()`；路径辅助方法改为 `nonisolated` 且无副作用；重新打开时清掉旧的 `lastError` |
| `LibraryOpenPolicy` / `LocalLibraryPresence` | 新增启动门禁：**已有正式库 ∨ 有旧版本机状态 ∨ 已登录** 才开库，三者都不满足则只记路径 |
| `RiverDiaryMacApp.init` | 先建账号会话，再按门禁决定是否开库；store 拿到的是“尚未打开”的同一个实例 |
| 登录/退出 | 登录后 `activateSignedInLibrary()` 幂等开库并重读共享时间线/日记记录；退出时 `v2Store.close()` 关闭数据库上下文 |
| 旧安装 | 门禁同时识别 `journal.state`、`user-state.json` 与更早的 `Database/river-diary.db`，保证旧安装未登录时仍能读自己的资料 |

设计取舍：门禁放在“是否创建正式库”，不改变 `V2Store` 的查询语义。库未打开时查询返回空、写入失败并保留输入，与既有失败路径一致；不做第二套空内存库。

## 3. 验证

### 自动化测试

新增 `LibraryOpenPolicyTests`（3 项）：

1. 门禁真值表：只有“无库 + 无旧资料 + 未登录”才延迟；
2. 延迟构造的 `V2Store` 不创建文件；`openIfNeeded()` 后文件出现、schema=2、表齐全、重复调用幂等、关闭后可重新打开；
3. 旧状态识别覆盖 `journal.state` 与 `Database/river-diary.db`。

macOS 全量：**423 项测试、0 失败**（原 420 + 新增 3）。

### 空资料首次启动（Release 包）

`scripts/verify_mac_empty_launch.sh` 新增 `--expect-no-library`：

- 全新 QA 用户目录、无任何快照；
- 进程存活、主窗口出现；
- **创建文件数 0，未创建 `river-v2.db`**。

### 有绑定会话时仍会建库（模拟登录）

把一份合成的 `RiverAccountSession` 写入 QA 钥匙串命名空间（`RiverDiary.account.qa`，不触碰正式账号），同一 Build 再启动：

- 进程存活、主窗口出现；
- 创建 `Database/V2/river-v2.db`、旧 `Database/river-diary.db`（含 WAL/SHM）、`Ingestion/daily-capture.bin`、`journal-encryption.key`。

说明这是“已登录会话存在”的接线验证，不是真实账号登录；测试后已删除全部 `.qa` 钥匙串条目。

## 4. 仍待完成（T02 其余范围）

- App / Intent / 后台 / 菜单栏的统一归属门禁：菜单栏快记已按登录态隐藏，但 Shortcuts/Intent 与后台任务的入口还需逐项核对。
- 旧安装的显式救援界面：现在保证旧资料可读，还没有“认领/导出/备份”的引导。
- 真实账号的登录与退出旅程（含 401 刷新、退出后旧回写被拒）未验证；本轮只证明门禁接线。
- 首次启动仍会写入复制节点身份（`.qa` 命名空间的 `local.riverdiary.node.qa`），虽然不是日记正文，但属于“绑定前就有的持久身份”，应在统一生命周期里决定是否也延迟。
