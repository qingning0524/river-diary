# River Node 架构与当前实现

更新日期：2026-09-28

本文记录本轮代码当前做到的程度，不代表所有 V1 验收场景已经完成。V1 只有在下方列出的未完成项和验收场景均处理后才算完成。

## 产品模型

River Diary 由多个本地优先的 River Node 组成。iPhone 和 Mac 都有自己的设备身份、本地数据库、采集和分析入口；普通 iCloud Drive 文件夹保存跨设备复制对象。两端可以暂时持有不同的状态，完成复制、导入、冲突处理和摘要核对后才显示“已验证”。

最终定义：

> River Diary is a distributed, local-first Memory OS with eventual deterministic convergence. Each River Node can operate independently while offline. Devices may temporarily hold different partial states, but after replication, reconciliation and integrity verification, all nodes must converge to the same canonical user state. Canonical state includes raw facts, deterministic derived state, user decisions, semantic timeline, AI artifacts, reviews, habits, memories, insights and pending confirmations. Generative AI output is versioned and synchronized as immutable artifacts rather than independently regenerated on every device. User decisions have higher authority than AI inference. The Timeline represents the person, not the device.

## 代码边界

- `Packages/RiverDiaryCore`：设备/Event/State Operation/Artifact/Manifest 模型、HLC、批次与序号检查、加密文件封套、确定性会话修复与融合、地点聚类、Artifact 仲裁、同步协调器。
- `ios/RiverDiary/RiverDiary/Managers/RiverLocalDatabase.swift`：iPhone 本地 SQLite、事件和操作追加、Artifact/AnalysisJob 持久化、地点投影、导入前沿和摘要。
- `ios/RiverDiary/RiverDiary/Managers/RiverNodeStore.swift`：iPhone 节点生命周期、共享密钥、iCloud 文件夹协调、同步入口和旧摘要迁移。
- `ios/RiverDiary/RiverDiary/Managers/IPhoneLocationCollector.swift`、`AppleMapPlaceProvider.swift`：Core Location 采集与 MapKit/CLGeocoder 候选。
- `ios/RiverDiary/RiverDiary/Managers/LogAppActivityIntent.swift`：Shortcuts App Intent；Shortcuts 个人自动化由用户创建。
- `ios/RiverDiary/RiverDiary/Views/RiverReviewView.swift`：读取共享回顾卡、回答卡片并确认个人习惯规则，同时显示共享月度河流信。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/ActivityStore.swift`：把 Mac 快记写入本机 Event 流，并为删除追加共享 tombstone。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/AIAssistantStore.swift`：把经 TimelineDigest 来源校验的 clarification 投影为共享待确认事项，并在已有用户标注后关闭或更新对应事项。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/DiaryStore.swift`：把 Mac 手写日记、手动评分和已保存的月度河流信复制为共享 State Operation，并将其他节点的 canonical 投影写回本地加密状态。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/Storage/V2Store.swift`：Mac SQLCipher V2 事实库、序号前沿、状态操作、Artifact、AnalysisJob 和地点投影。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/SyncSettingsStore.swift`：Mac 文件夹授权、同步密钥、设备管理、同步状态和周期核对。
- `macos/RiverDiaryMac/Sources/RiverDiaryMac/ActivityTimeline.swift`、`Views/RiverTimelineView.swift`：本机和远端应用会话融合、地点节点、快记和未记录时段的展示。

旧的 River Diary 数据库、手写日记和打包数据仍保留。Mac 的 V2 表在旧库旁边创建，继续读取既有活动文件；iPhone 仍只读读取旧版共享快照并把可迁移的睡眠、运动、快记和评分转入新事件/操作层，不再写新的明文共享快照。

## 本地数据库

### iPhone

文件位于 Application Support 下的 `RiverDiary/Database/river-node.sqlite`。SQLite 使用 WAL、`synchronous=FULL`、`secure_delete=ON`；数据库目录和文件使用 `completeUntilFirstUserAuthentication` 保护。设备 ID 和同步密钥存钥匙串；本地数据库本身当前不是 SQLCipher 加密。

主要表：

- `raw_events`：Event ID、origin device、设备序号、observed/recorded 时间、时区、来源、类型、payload、source hash。
- `state_operations`：操作 ID、Actor、序号、HLC、因果前沿、目标字段与 payload。
- `artifacts`、`artifact_dependencies`：不可变分析修订、输入前沿、内容摘要与依赖范围。
- `analysis_jobs`：待运行的分析任务、输入前沿和持久化状态。
- `shared_user_records`：从共享 State Operation 重建的习惯规则、回顾卡、回顾批次、长期记忆、待确认事项、手写日记和月度河流信投影。
- `places`：由位置 Event 和 State Operation 重建的地点投影。
- `devices`、`sync_imports`、`sync_exports`、`sync_state`：设备注册、对象去重、同步前沿、Manifest 和核对摘要。

使用 SQLite `user_version=4`。从 V1/V2/V3 幂等创建 AnalysisJob、共享用户记录和习惯/记忆决策投影；更新版遇到更高的 `user_version` 时停止打开，不会尝试用旧代码改写新库。

iPhone“本地备份”导出 Event、State Operation、Artifact 修订和设备登记，并用共享同步密钥封装为 AES-GCM 加密的 `local_backup` 文件。恢复采用可重试的幂等合并，不清空当前数据库；恢复文件不含密钥，需保留密钥或从仍保留密钥的设备导出转移码、在恢复设备导入同一密钥。密钥转移走独立的同步密钥设置，不把密钥写入备份。旧版打包日记正文不包含在 River Node 备份内。设备 ID 在钥匙串仍可读取时保持不变；同一设备也可从所选复制目录重新导入自己之前发布的对象，并从已有 Manifest 修订号之后继续。

### macOS

沿用 SQLCipher `river-v2.db`，新增/扩展 `raw_events`、`places`、`devices`、`state_operations`、`artifacts`、`artifact_dependencies`、`analysis_jobs`、`sync_imports`、`sync_exports`、`sync_state`；原有 activities、episodes、memories、analysis_runs、habit 和手写数据表仍保留。数据库使用 SQLite `user_version=2`，既有列用幂等列迁移补齐。

## Event、会话和地点

- Event 创建时获得 UUID、稳定 originDeviceID 和单调序号；重复 ID 内容不同会拒绝。Mac 旧 Event 的序号在迁移期补齐。
- 保存 observedAt、recordedAt 和 observed timezone。同步摘要覆盖这些字段、payload/hash、操作、当前 canonical Artifact 和设备前沿。
- iPhone 位置路径为 Visits、显著移动和用户请求的单次高精度定位；先写 Event，再异步查地图。普通相邻定位样本按 100m/60 秒抑制，地点候选按 250m/30 分钟抑制。MapKit POI 搜索半径为 250m；CLGeocoder 与 POI 查询失败不会删除坐标事实。
- 地点由约 250m 的确定性聚类、MapKit 候选和同步用户决定组合。用户命名/确认通过 State Operation 保存，确认值优先于地图名称。
- `SessionBuilder` 由 app.open/close 建立会话；缺少 close 时可由下一应用事件修复，未闭合会话最多按两小时封顶，并保留 inferred/observed 区别。Mac 导出的 app.session 也进入共同 Event 流。
- Mac 主 Timeline 把远端 iPhone 的应用会话纳入一天，并把 iPhone 的到访/显著移动转换为独立地点节点。地点节点不生成应用 Session，不增加应用时长。iPhone Timeline 对本机与已导入设备的 Event 构建会话，同时保留可展开的原始线索。
- SessionFusionEngine 将跨设备重叠的较短活动嵌套在较长主活动中；主活动时长不加上短暂的另一设备活动。

## State Operation 与权威

State Operation 是追加式、带设备序号和 HLC 的字段操作。当前已接入的类型包括地点确认/改名、评分设置/重置、设备退役、Event tombstone、Timeline 标注、习惯规则/回顾卡/回顾批次/回顾节奏、长期记忆记录/确认、共享待确认事项的创建/决定、手写日记/河流信当前记录与日记删除、快记元数据，以及 Artifact 过期标记。删除使用 tombstone 或稳定记录的 deleted 状态；Artifact 失效本身也通过 `artifact.stale` 操作表达，不改写已发布修订。

共享记录遇到未知 `kind` 时保留原始字符串并允许转发；当前客户端不渲染未知类型，也不会因其存在而中止 State Operation 重建。

同字段冲突先按因果关系识别并保留并发值，再按 HLC 与稳定 ID 确定当前投影。地点用户操作覆盖地图推测。此规则已接入的字段范围有限；还没有把所有旧版习惯规则、手写复盘和历史用户内容都迁移到 State Operation。

## 加密复制协议 v1

普通 iCloud Drive 根目录下按设备和流存放不可变对象：

```text
Devices/<deviceID>/Events/<objectID>.rdo
Devices/<deviceID>/Operations/<objectID>.rdo
Devices/<deviceID>/Artifacts/<objectID>.rdo
Devices/<deviceID>/Manifest/<objectID>.rdo
```

每个 `.rdo` 是 JSON 封套，含 object ID、kind、protocolVersion、ciphertext、ciphertextSHA256。明文序列化为排序键 JSON，使用共享 256-bit AES-GCM 密钥；认证数据绑定 `river-replication-v1 | objectID | kind`。SHA-256 用于快速完整性检查，AES-GCM 负责真实性和机密性。同步密钥通过 `river-sync-v1:` 导出码由用户复制/导入，存钥匙串，不写进文件。

Event 和 Operation 批次按每个设备的连续序号分段，object ID 固定范围。Event ID/Operation ID 是跨传输去重主键；Object ID 是文件去重主键。导入先验哈希与 GCM，再解析/检查设备和序号，最后数据库事务写入及记录 sync_import。

Manifest 是加密不可变快照，包含协议/Schema 版本、设备 HLC/修订、设备自有 Event/Operation 前沿、已导入设备前沿、设备登记和 canonical state digest。每轮同步：先发布本机对象，扫描和校验远端对象，导入，重建派生地点和 Artifact 状态，再根据缺口、未知对象/版本、完整性错误、活动设备间双向前沿确认及 canonical digest 判断是否 Verified。写出 iCloud 文件本身不会直接标为已同步。

## Artifact 和 canonical state

Artifact 内容由 AES-GCM 封套复制为不可变修订。当前 Artifact 仲裁严格排序：

1. 用户批准/编辑状态优先于 AI 生成。
2. 支配另一方的输入 Event/Operation frontier 优先。
3. 不可比较的 frontier 按覆盖分数、状态等级处理。
4. 再比较 pipelineVersion、promptVersion、HLC、修订号，最后按稳定 Artifact ID。

Artifact 记录 logicalKey、类型、来源设备、HLC、输入 frontier/snapshot hash、模型、pipeline/prompt 版本、内容 hash、状态和依赖。AI 请求在发出前捕获输入前沿；网络请求期间新数据到达时修订标 stale。后到 Event 落入修订依赖时间范围且其序号超出 Artifact 输入前沿时，会追加 `artifact.stale` 操作，所有节点可重建同一 stale 投影。用户编辑状态不会被该失效操作覆盖。

会改变分析语义的用户 State Operation（评分、地点、注释、习惯规则/作答、记忆确认、删除等）也会使其因果前沿之后的生成型 Artifact 失效；失效使用独立 `artifact.stale` 操作，不会递归失效，也不会覆盖用户批准或编辑的 Artifact。

iPhone 与 Mac 的每日回顾共用 `daily-review:<yyyy-MM-dd>` logicalKey、`.dailyReview` 类型、pipeline/prompt 版本和纯文本内容；provider/model 保留为 provenance，不作为 Artifact 身份。相同输入前沿的现有 canonical Artifact 会被两端复用，避免各自再生成一个结果。

Mac Artifact 的 `inputSnapshotHash` 基于实际 system/user prompt、超参数、证据引用和校验上下文，provider/model/endpoint 留在 provenance 或本机 AnalysisJob 身份中，不参与 Artifact 输入身份。

两端都有持久化 AnalysisJob 表，记录 logicalKey、Artifact 类型、输入前沿、优先级、状态、时间、重试次数、来源设备和 pipeline/prompt 版本。iPhone 今日回顾会跳过相同输入的 canonical Artifact；新 Event 使正在运行的结果失效时，在用户仍授权远程分析（或配置本机模型）的前提下最多自动补跑三次。Mac `runTask` 会把确切的 system/user prompt、参数、响应策略和验证所需本机候选保存到本地 SQLCipher job snapshot；请求指纹进入 job 身份，快照不参与复制。启动后只在输入 frontier、供应商、模型、endpoint 指纹及请求快照指纹仍一致、consent 有效且重试次数未超限时重放；成功或终态会清除快照。当前可恢复时间线摘要、日/周验证分析和记忆搜索；习惯回顾由 HabitReviewStore 从当前 14 日事实重新组装提示并把结果写回共享卡片，不由通用 worker 只重放原始文本。请求中输入变化时不会重放旧 prompt：当日回顾由现有管线重建，其它任务需要专用重新构造器。全任务防抖和端到端崩溃/并发成本验收仍未闭环。

iPhone 的本机 AnalysisJob 指纹覆盖实际 system/user prompt、模型、endpoint 与生成参数，不含 API key，也不复制到其他设备；恢复时按当前配置重建请求，配置不匹配的旧任务会 supersede。它对共享 canonical Artifact 的复用仍遵循相同输入 frontier 和 pipeline/prompt 版本，不要求接收设备重算出与来源设备完全相同的本地提示词哈希。重新同意网络分析会唤醒仍适用的今日回顾任务。

## 真实验证与仍需真实设备验证的场景

本轮 Xcode beta 工具链验证：RiverDiaryCore 36 项测试通过；macOS 全量 371 项测试通过；iPhone iOS 27 真机目标构建与签名成功；先前构建曾安装并在 iPhone 14 Pro 上接受启动，但由于当前 CoreDevice 显示设备 unavailable，最新真机签名包目前只在本机产物目录中。`devicectl` 曾接受启动请求，但随后设备状态变为 unavailable，截图请求失败，无法用真机验证当前 UI。当前 iPhone 17 Pro iOS 27 模拟器无 TeamIdentifier 的构建可以安装并启动，但界面明确报告“本地事件库不可用”，Keychain access group 权限错误 `OSStatus -34018`。该模拟器容器中有本轮启动生成的 SQLite `user_version=4` 数据库、Event/State Operation/Artifact/AnalysisJob 表和 WAL journal，原始 Event 数为 0；但 app 无法取得可用设备身份/钥匙串访问，因此这只验证到 schema bootstrap 和正确失败提示，不证明一个可工作的本地节点，也不替代真机签名包验证。Core tests 覆盖精确序号缺口、LAN 对象与后续 iCloud 重复投递幂等、共享习惯/记忆/日记/河流信加密复制、未知共享记录类型保留、provider/model 不作为 Artifact 身份、待确认事项身份、Timeline clarification 共享、用户状态操作对旧 Artifact 失效，以及分析请求/Artifact 指纹分离；macOS tests 覆盖 AnalysisJob 请求快照加密落盘/恢复输入序列化、mock transport 下同 frontier 恢复及 stale frontier 拒绝重放、本日新旧输入重建判定、远程 AI 未授权时零网络请求与同意后恢复、诊断报告共享待确认事项计数、习惯回顾、记忆确认、待确认事项纠正、TimelineDigest clarification 发布与关闭、快记 Event/tombstone与标签置顶元数据、DiaryStore 日记/河流信/评分复制和 State Operation Artifact 失效。LAN/Bonjour 实际设备互连、用户 iCloud 账号、位置后台交付、Shortcuts 自动化、真机交互和重装流程仍需操作级验收。

以下情形还没有通过真实 iPhone/Mac + 用户 iCloud 账号实际验收：Core Location 后台 Visits 的系统交付、Shortcuts 个人自动化触发、MapKit/Geocoder 实际 POI 质量、跨设备 iCloud 延迟和文件提供器协调、LAN/Bonjour 实际传输及 LAN/iCloud 重复投递、真实权限撤销、Personal Team 重签名后的持久性与恢复。

Developer Diagnostics 已在两端设置中提供显式开关，展示数据库计数、Artifact 状态、习惯卡/记忆/通用事项待确认数、导入对象、前沿、目录授权、LAN 状态、最近同步摘要、准确序号缺口范围、完整性失败、位置/地图/活动采集时间和最近 AnalysisJob；报告导出为不包含 Event 正文、坐标或密钥的 JSON。已接入测试 Event、iPhone 单次定位请求、完整同步管线、派生状态重建、Artifact 失效和报告导出。iPhone 的用户授权状态会显示；Mac 位置采集器和平台不支持的动作会明确标为未实现。

## V1 未完成项

- iPhone 与 Mac 已接入可选 MultipeerConnectivity/Bonjour 快速复制：只交换 AES-GCM 复制对象，接收端验密并写入同一复制目录，常规协调器再导入。重复 Event ID 已在存储层幂等；LAN + iCloud 的重复到达目前仍只有模拟单测，尚未真机验证本地网络授权、断连续传和文件提供器协调。
- iPhone 本地备份加密导出/合并恢复已实现并可编译，但尚未通过模拟器文件选择器操作或真机恢复测试。还未覆盖旧版打包日记正文和本地系统权限状态。
- AnalysisJob 已持久化；Mac 对可恢复任务保存加密请求快照，并且只重放 frontier、provider/model/endpoint 和请求指纹均匹配的请求。Mac 收到同步变更后会对本日 TimelineDigest/DailyReview 做 900ms trailing debounce，等待同一分析流水线结束，再从最新本机事实重建；这个调度目前只覆盖本日流水线。习惯回顾的应用激活重建已接入，但 cadence/证据门控下的进程崩溃恢复尚未故障注入；其他任务的输入变化后专用重建、全任务防抖和崩溃期间成本/幂等边界仍需继续实现和验收。
- 通用待确认事项已成为共享用户记录：iPhone 对多次到访且有真实地图候选的未确认地点生成稳定事项，Mac/iPhone 可确认、拒绝或改名，结果通过 State Operation 复制。Mac TimelineDigest 的来源校验 clarification 也会生成共享事项；更一般的活动解释与其他 AI 任务尚未接入统一确认管线，离线并发作答、重复提问和地点候选门槛仍需真机验收。
- Mac 快记文本和时间已进入 Event 流；旧快记在启动时幂等迁移，删除通过 tombstone 传播，收到删除操作后会刷新 Mac 快记投影。手写日记、评分、删除和已保存月度河流信已写入共享 State Operation，并在 iPhone 时间线/回顾页显示。Mac 启动时等待日记源加载后迁移旧 override 与信件。快记标签与置顶状态也通过共享用户记录复制并显示在 iPhone 时间线；自动生成但尚未保存的河流信草稿仍不会同步。
- 旧版 Mac `habit_*` 与长期记忆记录会在复制前迁移到共享 State Operation；iPhone 可查看/回答回顾卡、确认或撤销长期记忆。两端离线并发、撤销/退役、重装恢复和真实 iCloud 的操作级验收仍未完成。其他复盘状态、自动生成语义确认和长期历史迁移仍有未覆盖部分。
- iCloud offline、权限撤销、坏文件和未知协议有代码保护路径及核心测试，但还没有两个真实安装实例/真实 iCloud 文件提供器的端到端故障注入。
- 仍需在真实设备上完成文档 Scenario A–O 的操作级验收；模拟器启动不等同于完成位置、Shortcuts、iCloud、签名和 AI 场景。
- 真机验收需先在 iPhone 上信任上述开发者配置；之后才能继续验证位置后台交付、Shortcuts、LAN、iCloud 和重装场景。
