# T02 首次未绑定不再创建正式库

日期：2026-10-20（Asia/Shanghai）
状态：**T02 第一切片完成：Mac 延迟开库/退出关库/入口门禁（含 Dock 菜单测试），iOS 延迟开库；iOS 退出关库、后台/Shortcuts 核对、旧安装救援界面与真实登录/退出旅程仍待。**

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
| 系统入口 | Dock 菜单在未登录时只保留“打开河流日记”；写作/命令面板/日期导航/采集/导入菜单项在退出后禁用；退出时撤销已排定的晚间提醒（不改用户偏好） |
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

### 有绑定会话时仍会建库（模拟登录，非自动化门禁）

把一份合成的 `RiverAccountSession` 写入 QA 钥匙串命名空间（`RiverDiary.account.qa`，不触碰正式账号），再启动同一 Build：

- 进程存活、主窗口出现；
- 创建 `Database/V2/river-v2.db`、旧 `Database/river-diary.db`（含 WAL/SHM）、`Ingestion/daily-capture.bin`、`journal-encryption.key`。

**限制（必须如实记录）：** 这是“已登录会话存在”的接线验证，不是真实账号登录。当 QA 构建重新签名后，系统会为旧签名写入的钥匙串条目弹出“想要访问钥匙串”的授权框并卡住启动；`security add-generic-password` 的 `-A` 在同时指定 `-a` 时会被忽略，无法做完全无人值守的会话注入。因此该路径只作一次性人工观察，不能当作可重复通过的自动化验收；测试后已删除全部 `.qa` 钥匙串条目。

### 入口门禁（Dock 菜单）

`MenuGateTests` 直接构造 `AppDelegate.applicationDockMenu`：

- 未登录/已退出：只有「打开河流日记」；
- 已登录：出现「写一句…」「立即采集一次」。

这样“退出后同一门禁立即生效”不只是一行条件，而是有测试锁定的行为。

## 4. iOS 端延迟开库

改动与 Mac 同构，但用 iOS 自己的存储路径：

| 位置 | 改动 |
|---|---|
| `RiverLocalDatabase` | 新增无副作用的 `defaultDatabaseFileURL()` / `databaseFileExists()`，不再为了判断路径而建目录 |
| `RiverNodeStore` | 新增 `opensImmediately` 参数与 `openIfNeeded()`；延迟模式下只注册本地状态观察者 |
| `RiverDiaryApp.init` | 先建账号会话，再按“已登录 ∨ 已有库文件 ∨ QA 隔离包”决定是否打开正式库 |
| 登录 | `.onAppear` 与登录态变化时先 `riverNode.openIfNeeded()`，再接位置/运动/照片/AI/同步 |
| 退出 | 仍只停采集、LAN 同步与健康排程；**未关闭数据库连接**（见下） |

验证（Debug 模拟器构建）：

- 全新模拟器（`simctl erase` 后）安装启动；
- 首屏为登录页（截图在测试机 `/tmp/ios-t02-fresh.png`，不纳入仓库）；
- `simctl get_app_container` 检查：`Library/Application Support` 下 **0 个文件**，没有 `RiverDiary/Database/river-node.sqlite`。

限制：

- 登录后建库只有代码路径保证；iOS 单元测试 runner 仍无法连接（T23），因此没有自动化验证，也没有真实账号登录。
- `RiverLocalDatabase` 目前没有安全关闭接口，连接随对象释放才关闭；iOS 退出关库需要先补接口与引用清理，不能照搬 Mac 的 `close()`。

## 5. 仍待完成（T02 其余范围）

- iOS 登录后开库缺少自动化测试（runner 待修）；iOS 退出关库、后台/Shortcuts 入口逐项核对仍未做。
- 后台任务与 Shortcuts/Intent：macOS 没有 AppIntent，Dock/菜单栏已按登录态收口；iOS 的 Shortcuts 入口（`LogAppActivityIntent`）、后台健康同步与场景刷新仍需逐项核对。
- 旧安装的显式救援界面：现在保证旧资料可读，还没有“认领/导出/备份”的引导。
- 真实账号的登录与退出旅程（含 401 刷新、退出后旧回写被拒）未验证；本轮只证明门禁接线。
- 首次启动仍会写入复制节点身份（`.qa` 命名空间的 `local.riverdiary.node.qa`），虽然不是日记正文，但属于“绑定前就有的持久身份”，应在统一生命周期里决定是否也延迟。
