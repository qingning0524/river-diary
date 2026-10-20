# River Diary Scenario A–O 验收跟踪

更新日期：2026-10-04（新增规划映射；历史测试记录未复验）

本文把方案第 90 节逐项对应到当前证据，并跟踪第 91–92 节性能/电量门槛。Core/Mac 单测、目标编译和签名校验只能证明所覆盖的代码路径；它们不能替代需要 iPhone、Mac、用户 iCloud 目录和系统权限的操作验收。

**当前门槛：A–O 均未取得操作级验收结论。所有场景必须完成后才能宣布首个版本完成。**

| 场景 | 已有自动化/构建证据 | 仍需的操作级证据 |
|---|---|---|
| A — iPhone Only | iPhoneOS Debug/Release 目标编译；iPhone 14 Pro / iOS 27.0 真机 Build-for-Testing 与 XCTest 2/2 通过；原位启动后 Timeline、已有地点确认和会话条目可见 | Mac 关闭时，实际走完位置/地图、Shortcuts 自动化、用户同意后的网络 AI、Daily Review 和用户确认流程 |
| B — Mac Only | Mac 全量测试与 Release package build 通过 | 手机离线时启动 Mac 应用，实际采集、查看 Timeline 并完成 AI Review |
| C — Merge | `twoPairedOfflineNodesConvergeAfterBothExchangeImmutableBatches`；iPhone XCTest `testTwoSQLiteNodesConvergeEventsAndSharedConfirmationThroughEncryptedFiles` 与 Mac `testTwoV2StoresConvergeEventsAndSharedConfirmationThroughEncryptedFiles`；共享日记/河流信加密复制测试 | 两个真实安装实例离线产生不同 Event，连接后确认双方都收敛到 A/B/C/D/E，并在真实共享 iCloud 目录核对前沿 |
| D — Full Timeline | SessionBuilder、ActivityFusion、导入手机到访节点的模型测试 | 同一天的真实 iPhone 与 Mac 活动同步后，在两端确认完整一天 Timeline 的内容和时间 |
| E — AI Same Result | Artifact canonical identity/resolver 与加密修订复制的 Core 测试 | Mac 生成指定 Daily Review 修订后，确认 iPhone 显示同一修订和原文，且不本地重生成 |
| F — Offline AI Conflict | `pairedNodesConvergeUserOperationsAndOfflineArtifactConflict`、Resolver 顺序无关测试 | 两台设备真实离线各自产生 R4，联网后在两个 UI 确认唯一 Canonical revision |
| G — Confirmation | `testPendingConfirmationResolutionReplicatesUserCorrectionAndPlaceIdentity` 检查地点身份与确认关闭操作相邻提交；`testStateOperationBatchRollsBackAllWritesWhenOneIdentityConflicts` 检查批次失败时完整回滚；`explicitConfirmationAndHabitAnswerOutrankLaterGeneratedRecords` 检查用户决定高于并发新生成项；Timeline clarification 共享测试 | 手机确认真实地点候选，Mac 显示同一已确认地点且不再询问 |
| H — Place Rename | 用户地点权威优先于地图推测及共享纠正测试；确认/改名的两个本地 State Operation 现处于同一 SQLite 事务 | Mac 重命名真实地点后，在 iPhone 确认显示相同名字 |
| I — Late Event | `testLateEventInvalidatesArtifactThroughAppendOnlyOperationAndNewRevisionWins`、`testCurrentDayRebuildDetectsStaleArtifactAndQueuedCurrentFrontier` | 真实跨设备晚到 Event 后观察 R1 stale、R2 重建并在两端收敛 |
| J — Duplicate Delivery | Core `duplicateLanThenICloudDeliveryKeepsOneEventByEventID`；Mac SQLCipher `testTwoV2StoresConvergeEventsAndSharedConfirmationThroughEncryptedFiles` 从两个临时传输目录重复投递同一加密 Event | 同一真实 Event 先 LAN、再 iCloud 到达后检查两个节点数据库和 Timeline 仍只有一条 |
| K — Missing Batch | Core `missingEventSequencePreventsVerifiedStatus`；Mac V2Store `testV2SyncReportsMissingEventSequenceAndCannotVerify` | 在真实复制目录制造缺序，确认界面和 diagnostics 拒绝 Verified；补齐后恢复核对 |
| L — Corrupted File | Core `corruptedArtifactFileCannotImportOrReportVerified`；Mac V2Store `testV2SyncRejectsCorruptedArtifactWithoutImportOrVerification` | 损坏真实 Artifact 文件后确认 canonical 不被覆盖且 diagnostics 显示完整性错误 |
| M — iCloud Offline | 本机 Event、授权 AI gate、同步协调器模型测试 | 真实断开 iCloud 时仍可采集、Timeline、确认和获准 AI；恢复后自动继续同步 |
| N — Folder Permission Lost | `testLostSyncFolderBookmarkKeepsLocalNodeUsableAndRequestsReconnection`；iPhone/Mac 失效授权处理已编译 | 在两个系统真实撤销目录授权，确认不崩溃、local-first 继续、提示重连且恢复后同步 |
| O — Reinstall / Re-sign | iPhone 14 Pro 上以同一 bundle ID 原位更新并启动；Team `Z29662632F`、Keychain group `Z29662632F.local.riverdiary.app` 与此前签名一致；已有 Timeline、地点决定和会话条目仍可见；Core 节点重装复制模型测试 | 仍需在更新前后核对同一设备 ID、实际数据库版本/前沿和钥匙串同步密钥可读；当前屏幕只证明已有内容可读 |

## 当前规划映射与新增边界

总入口见[产品与重构规划](../../主规划.md)，iOS当前为今天/足迹/待确认/River/我的五页，见[iOS基线](../../ios/BUILD_BASELINE.md)。旧四入口及下方历史主题/布局记录只作日期证据；A–O的数据/复制/用户决定门槛继续有效。没有按当前构建走完的场景保持待验。

| 范围 | 任务 | 证据要求 |
|---|---|---|
| 既有复制与已有备份基线 | T08a / A–F、I–O | 物理双端/真实File Provider、离线/缺序/损坏/版本，与本机目录证据分开 |
| 纠正与同一理解 | T06/T07 / G–I | 事务提交、用户权威、stale、另一端队列关闭和相同canonical内容 |
| 新恢复与节点身份 | T09→T08b | 原地恢复/换设备/旧设备同时在线；恢复后新增事件无origin/序号冲突 |
| 六条产品旅程 | T10–T13 | 键盘/大字号/三外观、返回日期/地点/草稿、来源失败、导出与性能 |
| 授权与学习 | T07/T14/T15（仅启用范围） | 撤回后无发送、预算跨重启；独立标签质量评估与规则撤销 |

新增R1–R5暂未执行：R1旧安装离线升级仍可受控备份/导出；R2缺本机密钥保留密文；R3恢复后新旧设备共同写入仍无ID/序号冲突；R4日记/问题本机草稿与共享月信草稿范围正确；R5未来版本备份写入前拒绝且混合版本复制不损坏旧记录。

每条新证据记录commit及未提交源码指纹、构建/设备/系统、fixture是否合成、步骤/预期/实际、产物位置、跳过或失败。首次安装/编译/单测/模拟器/真机旅程各自单列；只有同范围有效证据可关闭任务。

## 2026-09-29 真机运行记录

- 设备：iPhone 14 Pro（iPhone15,2），iOS 27.0，Xcode 27 Beta。
- `RiverDiaryTests` 真机 XCTest：2 项通过、0 失败。覆盖 v6→v7 会话投影迁移，以及增量尾段只改动受影响设备的 Session rows、倒序 Event 回退该设备全量重建；测试使用临时 SQLite 和注入的测试设备 ID。
- 新增的 `RiverDiaryQA` + `RiverDiaryUITests` 隔离方案在 iPhone 17e 模拟器上通过空 Timeline 启动，以及同步密钥 UI 导入并从 Keychain 读回：2 项通过、0 失败。该结果不替代 iPhone 14 Pro 上的真实文件提供器与双端核对。
- 同一代码状态的 Core 47 项、Mac 378 项、iPhone 17e 模拟器 2 项均通过；Core/Mac Release package build、iPhoneOS Debug 签名构建、iPhoneOS Release 构建及真机 `build-for-testing` 均通过。签名校验通过，Team 与 Keychain group 符合既有配置。
- 同一 Debug 构建原位安装后启动正式 App；Timeline 展示已有地点决定及应用会话，没有崩溃。测试没有清除 App 数据，也没有验证真实 iCloud、地图请求、Shortcuts 自动化或网络 AI。
- 此次运行为 A 与 O 增加了启动和数据可见性的部分证据；A–O 仍没有任何场景达到完整操作级通过，首个版本验收门槛保持未通过。

- 2026-09-29 本轮使用 Xcode 27 Beta 复验 Core 47 项；Mac 383 项通过的有效结果来自隔离测试脚本。此前一次直接运行 `swift test` 的 383 项绿灯因触碰正式目录而不作为有效验收证据。
- 本轮在 iPhone 17e 模拟器重跑隔离 QA 空 Timeline 启动 UI 用例：1 项通过、0 失败；应用使用专用空数据 fixture，未读取正式日记资源。模拟器结果不代替真机验收。
- 修正开发者诊断把本地数据库版本写死为 4 的问题：诊断和迁移现共用 schema version 常量；iPhone 17e 模拟器上的 `RiverLocalDatabaseSessionProjectionTests` 2 项通过，其中 v6→v7 迁移断言实际 SQLite 版本与该常量一致。
- 加入 Mac QA 存储隔离启动保护及 `scripts/launch_mac_qa.sh`；缺少专用临时 Home 或 Application Support 路径不匹配时，QA bundle 会在创建数据库连接前拒绝启动。5 项隔离环境回归和 Mac 全量 383 项测试通过，Mac Release package build 通过。

## 2026-09-29 隔离 QA 环境

- iPhone QA bundle `studio.riverdiary.ios.qa` 与正式版并存，Keychain group 为 `Z29662632F.studio.riverdiary.ios.qa`。发现原 QA 构建会捆绑项目忽略的日记 snapshot 后，已只卸载并重装 QA bundle，正式版仍安装。
- Mac QA bundle `studio.riverdiary.mac.qa` 需通过 `scripts/launch_mac_qa.sh` 设置单独的临时 Application Support home；启动时会验证该隔离目录。QA 钥匙串 service 加 `.qa` 命名空间；脚本每次启动都会关闭自动采集、网络 AI 授权和 LAN 复制。禁止从 Finder/CUA 直接打开 QA `.app`，因为 Launch Services 不会继承 `CFFIXED_USER_HOME`。
- Mac QA 已选择专用 iCloud Drive 文件夹 `RiverDiary QA 2026-09-29`、生成临时同步密钥并发布节点对象。QA 重装清除了 iPhone 端书签；需在重新解锁后再选同一目录、导入密钥并核对双端前沿。
- 隔离文件夹含一个便于 iCloud File Provider 同步空目录的 QA README；复制扫描只读取 `Devices` 下的加密 `.rdo` 对象。
- 检查 QA 运行包时发现应用资源目录里的 `data.json` 会被副本读取；该资源可能含用户日记。已为 `RiverDiaryQA` 增加空数据 fixture、排除原始资源，并将 Mac QA 包替换为空 fixture、重置临时 Mac QA home。复制目录中检查到的唯一 Mac Event 解密元数据为 1 条 `ingestionSnapshot`，payload 14 字节；没有发现 State Operation 或 Artifact 文件。
- 密钥导入 UI 已在模拟器验证，但实体机配对尚未完成。Mac/iPhone 再次自动锁定后，系统拒绝启动 iPhone QA；正式版仍保留安装，未清除或改写其同步目录、数据库或钥匙串。
- XCUITest target 的通用 iPhoneOS `build-for-testing` 编译通过；实体机 runner 签名未通过：Xcode 找不到 `studio.riverdiary.ios.qa.uitests.xctrunner` 的 provisioning profile，当前开发者账户凭据不可用。QA App 本身已用独立 bundle 签名安装；下一步可用手动 UI 继续实体机操作，或恢复 Xcode 账户后重试 UI runner。
- 2026-09-29 通过 Xcode 27 Beta 的正常模拟器构建签名运行完整 `RiverDiaryQA` UI 集：iPhone 17e / iOS 27.0 上 2/2 通过，覆盖空 QA Timeline 和测试密钥导入后读取。该模拟器没有选中的 iCloud 文件夹，因此没有验证实际复制。一次诊断运行显式设置 `CODE_SIGNING_ALLOWED=NO` 后显示本地库不可用且密钥读回失败；签名检查显示该产物的 Info.plist 未绑定、资源未封存，而正常 Xcode 模拟器产物的 app bundle 已封签（ad-hoc；Team ID 和 entitlements 仍为空）。故无签名产物不能作为 Keychain 验收证据；本次通过也不证明真机 Team Keychain group 或 iCloud 行为。
- 本轮在同一 iPhone 17e 模拟器运行 `RiverDiaryTests`：4/4 通过。新增覆盖 App Intent 录入器把 Shortcuts opened/closed 持久化进注入的临时 SQLite，并生成观测关闭、420 秒 Safari Session；空应用名/标识会在写入前被拒绝。`RiverDiary` iPhoneOS Release 通用目标编译通过（未签名、未安装）。这些模型/模拟器结果仍不证明 iPhone 上的真实 Shortcut 个人自动化触发。
- 收紧 QA UI 状态断言：没有选中共享文件夹时，仅允许“密钥已导入”或“请先选择共享文件夹”，不接受“已核对/已验证”。Xcode 27 Beta 重跑隔离 UI 集仍为 2/2 通过。
- 后续性能与 Shortcuts 检查（2026-09-29）：App Intent 的追加专用数据库打开模式不重建地点或共享记录投影；trigger 回归证明两个投影表没有被删除重建，iPhone XCTest 更新为 5/5 通过。`RiverDiary` iPhoneOS Release 在此改动后再次编译通过。QA 包 `Metadata.appintents` 中包含可发现的 `LogAppActivityIntent` 和 App Shortcut 元数据；这仍不代替在 iPhone 上实际创建并运行个人自动化。
- 同步性能回归（2026-09-29）：无变更时 Core 同步协调器不再反复全量重建派生表；两端导入新批次后会重建一次，并在成功后清除持久化 dirty marker。iPhone trigger 回归并检查 Event 导入后的单次重建；Mac trigger 回归也通过。Core 47/47、iPhone XCTest 7/7、Mac 全量 385/385、RiverDiaryQA UI 2/2 通过；iPhoneOS Release 与 Mac Release package build 通过。真机延迟、真实 iCloud 目录规模与电量尚未测量。
- 事件级恢复回归（2026-09-29）：普通本机 App/Shortcut Event 的 Artifact 失效成功后会清除临时标记，不要求随后全量重建地点投影；本机地点 Event、State Operation、远端 Event/Operation 批次或恢复数据库仍安排派生核对。最新 iPhone XCTest 7/7、隔离 QA UI 2/2、Core 47/47、Mac 全量 385/385 均通过。真实目录扫描和 Canonical digest 仍可能读遍已知对象；需用实际大目录测量后再定性能门槛。
- 后续 SQLite-backed 双节点集成（2026-09-29）：iPhone 17e 模拟器上 7/7 XCTest 通过。新增用例用两份独立 SQLite、临时复制目录和同步密钥交换不同 Event 与共享待确认记录，验证两端状态操作、Event ID 集合、canonical digest 和 Verified 最终一致。它不覆盖 Mac SQLCipher 适配器或真实 iCloud File Provider。
- Mac SQLCipher 双库集成（2026-09-29）：新回归用两个独立 V2Store、临时加密复制目录和相同同步密钥交换 Event 与共享待确认记录，验证 Verified 与 canonical digest 收敛。首轮全量测试暴露 Mac `RawEvent.replica()` 的 JSON 字段顺序不稳定，导致同一对象 ID 被误判为内容冲突；改为排序键编码后，定向用例和 Mac 全量 385/385 均通过，Mac Release package build 通过。仍不覆盖真实 iCloud 或物理设备。
- 最新复验（2026-09-29）：隔离 Mac 全量测试 387/387 通过，新增覆盖真实适配器下的缺失 Event 序号检测和损坏 Artifact 拒绝导入。用户确认 Xcode Beta 中指定账号有 Personal Team，因此已仅移除 `RiverDiaryQA` 和 `RiverDiaryUITests` target 上写死的旧 Team；正式 `RiverDiary` 签名设置未改。iPhone 17e 模拟器隔离 UI 集 1 项通过、1 项因未提供测试同步密钥而跳过。iPhone 14 Pro 的 UI 测试仍需由 Xcode 把所选 Personal Team 应用到这两个 QA targets 并生成测试描述文件；命令行无法仅凭 Apple ID 号码选择团队，自动签名此前也没有找到匹配账号/描述文件。Apple Developer 账户页对该账号显示暂不符合使用条件。尚未在真机安装或启动此版 QA App；A–O 仍为 0/15 个完整操作级通过。

### QA 隔离误启动与清理记录（2026-09-29）

- 一次通过 CUA 直接按路径启动 Mac QA bundle 的操作没有传入 `CFFIXED_USER_HOME`。进程因此打开了正式 App Support 下的 `river-diary.db` 与 `V2/river-v2.db`；对应的本地状态密钥也位于相同 Support 根目录。没有读取数据库正文，但 V2 数据库修改时间在运行期间更新，故无法证明其逻辑内容完全未变；没有找到可用于对照的应用级备份，也没有执行数据库恢复。
- 同一时间窗内，专用 QA iCloud 文件夹新增了 2 个 Mac State Operation 批次、1 个 Mac Event 批次、4 个后续 Mac Manifest 和 1 个后续 iPhone Manifest。文件均为加密 `.rdo` 对象，未解密或查看载荷。用户授权后，已删除这 8 个新生成的 QA 对象；原始 README、初始 Mac Event 和两个设备的初始 Manifest 保留。File Provider 显示文件夹已上传、最新版本已下载且同步未暂停。
- iPhone CoreDevice 当前不可用，因此尚未核实 iPhone QA 沙盒是否导入过这些对象；已尝试从镜像应用切换器关闭 QA App 并返回主屏幕，但无法验证后台进程与本地沙盒清理状态。正式 App 未卸载，正式数据库未恢复或删除。A–O 验收保持未完成。
- 另一次未设置临时 Home 的直接 `swift test` 运行中，正式 `river-v2.db` 大小增加 4 KiB；根因是活动测试没有注入 V2 store，并有一个范围测试使用了默认 Activity 目录。相关测试现在分别使用临时 V2 数据库和 Activity 目录，状态加密也会拒绝未隔离的 XCTest 进程。
- 随后通过 `scripts/test_macos_isolated.sh` 重跑 Mac 全量 383 项，全部通过。正式 V2 文件的修改时间和大小保持在事故后的值不变；测试数据库与测试加密密钥实际出现在临时 Home。Mac Release package build 通过。
- 用户明确授权后，已删除临时目录中名称严格匹配 `river-audit-<UUID>` 的 520 个测试数据库目录；清理后复查该命名规则匹配数为 0。清理没有匹配 `river-audit-activity-*` 目录，也没有操作正式数据库或 QA iCloud 基线对象。由于当前工作环境无法访问 Mac 正式 App Support 路径，清理后未能再次核对正式数据库文件元数据；iPhone QA 沙盒是否导入过此前误同步对象仍待设备重新连接后确认。
- 随后在隔离目录运行的 Mac 384 项全量测试退出后，又按同一精确目录名清理了 6 个新建临时数据库目录（文件内容约 1.5 MiB）；当时没有测试进程，复查剩余匹配目录为 0。Mac 正式数据库和 QA iCloud 基线对象仍未触碰。
- 最近的 Mac 385 项全量测试退出后，按相同精确规则清理了 12 个新建临时数据库目录（文件内容约 2.9 MiB）；无活动测试进程，复查剩余匹配目录为 0。

## 本地备份补充

Core 加密备份测试包含迁移后的旧日记 State Operation，确认正文被加密且解密后可恢复；`coordinatedFileIOReadsAndAtomicallyWritesSelectedFiles` 仅验证本地文件的协调读写。iPhone 文件选择器导入、真实 File Provider 协调、密钥恢复及 UI 可见性尚未操作验收；系统权限不写入备份，需要重新授权。

## 方案第 91–92 节：性能与电量门槛

| 要求 | 当前代码证据 | 状态 |
|---|---|---|
| Event 到达时不扫描整个 iCloud 目录 | iPhone 由前台 30 秒定时器、回到前台和 LAN 到件回调触发完整同步；不是每条 Event 都直接发起同步 | 真实 iCloud 目录规模下的扫描耗时/电量尚未测量 |
| 打开 App 不重建所有 Timeline | iPhone 当前 Timeline Event 查询限制在所选日；v7 `timeline_sessions` 与 per-device frontier 持久化会话投影；普通位置/健康 Event 不标 dirty | iOS XCTest 在 iPhone 17e 模拟器和 iPhone 14 Pro 真机均通过 v6→v7 迁移、增量尾段只更新受影响 session row、倒序 Event 回退该设备全量重建。真实大库耗时仍待测 |
| GPS 不逐条请求地图服务 | 位置精度约 100 米；同一位置 250 米内 30 分钟不重复请求，且检查近期候选 | 代码门控已实现；实际 POI 质量及耗电需真机验证 |
| Timeline 打开不触发重复 AI | 已保存 Artifact 按输入前沿复用；Mac 今日回顾重建使用 900ms trailing debounce，iPhone 网络分析受用户同意和持久化 Job gate 控制 | 代码路径已覆盖；实际前后台/网络切换需在设备上验收 |
| 位置采用低功耗策略 | 使用 Visits 与 Significant Location Changes、约 100 米精度和距离过滤，不持续请求高精度 GPS | 代码路径已实现；电池影响和后台交付尚未实测 |

此表仍有未完成项，不能替代 A–O 门槛或据此宣布首个版本完成。

## 2026-09-30 iOS 产品重设计实现记录

- 正式 iOS 目标已换为五个原生入口：Timeline / 足迹 / 待确认 / River / Me；保留原有评分编辑能力并移到 Timeline 日期上下文；保留现有 bundle ID、SQLite、共享 State Operation、RiverSyncCoordinator 与 Keychain 同步密钥。
- 展示层使用真实按日 Session/Event、跨设备 SessionFusion、地点、共享问题、Memory、canonical Daily Review 和可由本机 Event ID 逐条核验的 `semanticTimeline` Artifact 分段。无法在本机解析证据的远端分段会隐藏；stale/provisional 标签保留。Timeline 的当天回顾可包含本机共享手写日记，但只有用户显式选择对应资料范围后才进入 AI 请求。Timeline 空态、足迹无权限/无位置空态、无待确认、无 Memory 等状态都不填充设计稿虚构数据。
- 足迹首次进入不会请求权限；只有点击开启后才调用位置授权。重复到访分段显示，未匹配坐标不生成地点名；地图候选显示“可能是”，足迹卡可以直接进入地点确认/更正，历史日期也不会误称为“今天”或暗示可回填位置。River 网络回答遵守既有网络同意、数据类别开关，并增加单独的共享记忆/习惯回答发送开关。自然语言回答默认只留在共享对话记录中；用户主动勾选长期规则后才创建 Habit。Me 可更正/删除 Memory、撤销习惯回答、重开已回答问题；撤销时规则退役与问题重开在单一本地 State Operation 事务中写入。
- Mac 生成的 Memory 现在把校验过的 `raw:` / `capture:` / `diary:` 引用写入共享记录和本地投影；iPhone 详情按需查询引用的 Event、共享日记并提供回到对应 Timeline 的入口。旧 Mac `episode:` 来源若不在 iPhone 上，会明确标出当前不能展开。已记录用户确认/撤销时间和备注；纠正、确认、删除反馈读取实际保存结果。
- 浅色与深色 QA 空 Timeline 截图：[`浅色空 Timeline`](../designs/ios/手机端UI设计图/05-历史界面与空态/timeline-empty-light--2d102109.png)、[`深色空 Timeline`](../designs/ios/手机端UI设计图/05-历史界面与空态/timeline-empty-dark--6219a2ca.png)；手写日记操作截图：[`隔离 QA 手写记录`](../designs/ios/手机端UI设计图/05-历史界面与空态/timeline-handwritten-entry-qa--831a0c1f.png)。截图只含空数据状态或测试输入，不代表真实用户内容。
- Xcode 27 Beta / iPhone 17e iOS 27.0 Simulator：隔离 QA UI 五栏、权限不自动弹出、Me → 设置入口、手写日记保存到空日期均通过；同步密钥 UI 用例因未配置 `QA_SYNC_KEY` 而跳过。UI 测试启动时只重置 QA bundle 的本地 SQLite/UserDefaults，未触碰 iCloud 文件夹。手写日记 UI 用例在点击编辑框时，XCUITest 结果包记录 `Invalid frame dimension (negative or non-finite)` 运行时警告；标准与最大辅助功能字号下都出现，测试仍通过，原因尚未定位。
- 同一工具链：iPhone `RiverDiaryTests` 在 iPhone 17 Pro iOS 27.0 Simulator 上 13/13 通过，覆盖 Session/跨设备融合、足迹到访分段、未确认地点名称标记、Artifact 依据校验、手写日记范围同意和共享操作撤销；RiverDiaryCore 49/49 通过；`scripts/test_macos_isolated.sh` 全量 Mac 391/391 通过，包含 Memory 证据引用存储与共享投影往返；Mac Release package build 和 iPhoneOS Release 通用目标未签名编译通过。隔离 UI 集 2 项通过，密钥导入 1 项按未配置 `QA_SYNC_KEY` 跳过。
- 2026-09-30 真机补充：iPhone 14 Pro 已配对并在 Xcode 中可用。隔离 QA scheme 的 iPhoneOS `build-for-testing` 编译通过。第一次 UI 测试因锁屏退出；解锁后重试仍在 runner 建连前以 code 74 退出（0 项用例执行）。设备镜像显示 iPhone 仍在使用中，真机截图无法确认 QA 界面是否到前台。随后只更新并启动隔离 bundle `studio.riverdiary.ios.qa`，带 QA 本地重置参数；测试结束后已终止该 QA 进程。正式 bundle `local.riverdiary.app` 未替换，仍保持安装。需要让 iPhone 空闲并保持解锁/连接后再重跑 runner；不应把这次启动尝试当作真机 UI 通过。
- 本轮在 iPhone 17e / iOS 27.0 Simulator 上隔离 UI 集 2 项通过，密钥导入 1 项因未配置 `QA_SYNC_KEY` 跳过；手写日记点击编辑框仍记录一条 `Invalid frame dimension` 运行时警告。没有操作用户 iCloud 文件提供器、Mac+iPhone 双端真实目录、位置/健康权限撤销与恢复、Shortcuts 个人自动化或重装保留流程。**A–O 仍是 0/15 个完整操作级通过；V1 验收门槛未通过。**
- 2026-09-30 UI 视觉复核：按认可截图重构固定五栏底部导航层级、River 常驻聊天输入区和 Me 首屏结构；空足迹使用无地点/路线标注的浅色示意底图。隔离 QA 截图：[Timeline](../designs/ios/手机端UI设计图/05-历史界面与空态/timeline-empty-qa-reference-pass--40021bbb.png)、[足迹](../designs/ios/手机端UI设计图/05-历史界面与空态/footprints-empty-qa-reference-pass--773c333c.png)、[待确认](../designs/ios/手机端UI设计图/05-历史界面与空态/confirmations-empty-qa-reference-pass--b3bc0faf.png)、[River](../designs/ios/手机端UI设计图/05-历史界面与空态/river-empty-qa-reference-pass--ea7ec091.png)、[Me](../designs/ios/手机端UI设计图/05-历史界面与空态/me-empty-qa-reference-pass--1e20c3a6.png)。
- 同轮 iPhone 17e / iOS 27.0 Simulator 隔离 UI 集 2 项通过、1 项因未配置 `QA_SYNC_KEY` 跳过；补充断言检查 River 输入框可见且可点，以及 Me 首屏不显示资料控制区。iPhoneOS Release 通用目标编译通过。截图来自空 QA 数据；设计稿示例活动、地点、照片和计数未填入。**A–O 仍为 0/15，真实 iPhone 与双端 iCloud 验收未完成。**
- 2026-09-30 iPhone 14 Pro / iOS 27.0 真机复验：隔离 bundle `studio.riverdiary.ios.qa` UI 集 2 项通过、1 项因未配置 `QA_SYNC_KEY` 跳过。覆盖五栏切换、River 输入框可操作、Me 首屏结构、日记多行输入实际唤起键盘并保存。日记弹层在第一次真机运行时发生布局错位、输入框未取得焦点；改为大尺寸弹层和多行输入控件后通过。`Invalid frame dimension (negative or non-finite)` 运行时告警仍在，尚未定位。
- 真机隔离截图：[Timeline](../designs/ios/手机端UI设计图/05-历史界面与空态/iphone14pro-timeline-empty--b9f61327.png)、[足迹](../designs/ios/手机端UI设计图/05-历史界面与空态/iphone14pro-footprints-empty--ddf61a3b.png)、[待确认](../designs/ios/手机端UI设计图/05-历史界面与空态/iphone14pro-confirmations-empty--7007cdb1.png)、[River](../designs/ios/手机端UI设计图/05-历史界面与空态/iphone14pro-river-empty--9430fe37.png)、[Me](../designs/ios/手机端UI设计图/05-历史界面与空态/iphone14pro-me-empty--b064f714.png)。截图来自 QA 空数据库；足迹页的系统授权显示“始终允许”，但 QA 足迹事件为空。正式 bundle `local.riverdiary.app` 未替换，未读取或更改正式数据库和同步目录。
- 修复后的 iPhoneOS Release 通用目标编译通过。此轮没有验收真实 iCloud 双端复制、Shortcuts 自动化、位置记录交付、权限撤销恢复或重装保留；**A–O 仍为 0/15，V1 操作级验收尚未完成。**
- 2026-09-30 视觉精修：将主导航、日期操作、Me 设置、River 发送、Timeline 记录和足迹授权等高频操作的触控范围统一到 44pt；分类/时间微文案改用可随系统字号缩放的语义字体；修复深色模式下选中 Tab 仍使用近黑色导致难以辨认的问题，并为无位置线索示意图增加深色配色。River 空数据时补充“River 注意到”的真实空态，避免主理解卡与快捷提问之间出现大片无意义留白；仅在没有活动、待确认、记忆、日记或当日理解时显示。
- 按用户确认信任 Developer App 证书后，iPhone 14 Pro / iOS 27.0 最新隔离 UI 集 **3 项通过、0 项失败/跳过**。五页真机截图包含 River 新“注意到”空态；44pt 主操作断言、日记多行输入唤起键盘并保存、QA 同步密钥界面导入及钥匙串读回均通过。密钥用固定 QA 测试值，只写入 `studio.riverdiary.ios.qa` 的 QA 钥匙串，不匹配 Mac QA 密钥，也没有选择共享文件夹或发送同步对象；正式 Keychain/App 未动。iPhoneOS Release 通用目标编译通过。真机深色截图见 `iphone14pro-dark-*.png`；模拟器浅/深色截图见 `iphone17e-*-*.png`。真机 VoiceOver / XXL Dynamic Type、真实 iCloud 双端、Shortcuts、权限撤销恢复与重装保留尚未验收。**A–O 仍为 0/15；手写输入流程仍记录 `Invalid frame dimension` 运行时告警。**
- 2026-10-01 同步准备：在 `/tmp` 隔离构建 Mac QA bundle，使用空日记 fixture，并通过 `scripts/launch_mac_qa.sh` 启动。QA 设置显示专用文件夹 `RiverDiary QA 2026-09-29`，自动采集、网络 AI 与 LAN 复制均关闭。未显示或生成同步密钥、未选择文件夹内容、未运行同步；Mac↔iPhone QA 配对仍待手动导入同一测试密钥。
