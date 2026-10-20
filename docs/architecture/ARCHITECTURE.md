# River Diary 当前架构速览

更新：2026-10-19。本文描述代码结构，产品取舍/未完成建设/验收只维护在根目录 [主规划](../../主规划.md)。协议细节见 [River Node](RIVER_NODE_ARCHITECTURE.md)。

## 原生主线

| 层 | 位置 | 当前职责 |
|---|---|---|
| 共享核心 | `Packages/RiverDiaryCore` | Event/Operation/Artifact、身份、仲裁、分析指纹/任务、加密复制与账号会话 |
| Mac应用 | `macos/RiverDiaryMac/Sources/RiverDiaryMac` | App、Design、Domain、Features、Infrastructure、Views；采集/加密存储/投影/AI/恢复/原生工作区 |
| iOS应用 | `ios/RiverDiary/RiverDiary` | App、Design、Domain、Features、Infrastructure、Views；移动来源、文件保护数据库、按日阅读/编辑、复制与AI |
| 账号与管理 | `server` / `website` | 身份、权益、设备会话、邮件/审计及分发入口；不接收原生日记/健康/位置正文和复制密钥 |
| 验证 | Core/Mac的Tests、iOS单元/UI目标、Python tests | 分层验证纯规则、存储适配、原生旅程、管道；历史结果与当前执行分别记录 |

原生Event保留观察，Operation保留用户决定，Artifact保留可失效派生。先持久化再发布投影，副作用可恢复；跨端通过不可变加密对象复制并核对前沿/摘要。用户决定优先于AI，不以同一模型反复解释生成新事实。

Mac使用SQLCipher及既有本机状态保护，iOS SQLite使用系统文件保护；账号身份与本机密钥、复制密钥分开。资料上下文的延迟打开、退出与在途任务是主规划T02–T07的待完成边界，不能仅凭登录页存在认定已经达标。

## 保留的历史快照/网页管道

`data/raw.json` 是这条兼容管道维护的原始快照；`pipeline/` 清洗、合并聚合、生成每日JSON/manifest、打包 `web-preview/`。它不替代原生Event/Operation事实库。

- `paths/io`：路径与只在变化时写入。
- `records/health`：校验/清洗与旧聚合合并。
- `snapshots/assets`：每日文件、manifest与CSS/JS/单文件网页。
- `runtime` / 根目录 `build.py`：兼容编排；完整构建可能写项目/iCloud，隔离测试不能用它冒充只读检查。

旧网页按编号拼接模块，仍是使用中的兼容输出，不因原生主线成熟就删除。未有当前调用的旧iOS首页链路已清理，当前入口为RootView→RiverAutomaticTodayView。

## 开发入口

```bash
make test
./scripts/test_macos_isolated.sh --disable-sandbox
```

iOS通过 `scripts/select_xcode.sh` 选择工具链；QA与正式bundle隔离。构建通过、UI runner运行、真机来源与真实iCloud是不同证据层级。当前构建与清理结果见 [整合记录](../maintenance/MASTER_PLAN_CONSOLIDATION_2026-10-19.md)。
