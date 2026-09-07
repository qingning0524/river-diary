# River Diary 架构速览

更新日期：2026-09-07

River Diary 采用本地优先的三端结构。数据清洗只发生在构建阶段，运行时各端优先读取本机快照，敏感明细不出设备。

## 1. 分层

| 层 | 位置 | 职责 |
|---|---|---|
| 原始数据 | `data/raw.json` | 唯一手工维护的日记真相源 |
| 构建管道 | `pipeline/` | 清洗、汇总、数据体检、健康合并、每日快照、资源打包 |
| Web UI | `src/css`, `src/js` | 原生 HTML/CSS/JS，按编号加载并打包成单文件 |
| iOS UI | `ios/RiverDiary` | SwiftUI 消费端；日期导航与健康卡片已拆成独立子视图 |
| macOS 应用 | `macos/RiverDiaryMac` | SwiftUI 采集、加密存储、数据库、活动融合和 AI 洞察 |
| 测试 | `tests/`, `macos/.../Tests` | Python 管道测试 + SwiftPM 逻辑测试 |

## 2. Web 模块边界

- `01-core.js`：全局数据、格式化、状态与筛选。
- `02-river.js` / `03-detail.js`：河流图与单日详情。
- `04-insights.js` / `05-social.js`：数据洞察与社交页签。
- `06-bootstrap.js`：启动、绑定与主渲染入口。
- `07-shell.js`：主题、演示模式、侧栏与滚动状态。
- `071–077`：细节增强、命令面板、指标卡、诗词、分享图、收尾交互。
- `08–11`：回放、回顾、健康、导出与轻量工具。

构建按文件名顺序拼接；跨文件接口只通过全局渲染函数或明确挂到 `window` 的方法。

## 3. Python 管道模块

| 模块 | 职责 |
|---|---|
| `pipeline/paths.py` | 固定路径与 iCloud 目录 |
| `pipeline/io.py` | 原子化写入、只在内容变化时落盘 |
| `pipeline/records.py` | 输入校验、清洗、summary、data quality |
| `pipeline/health.py` | 合并 iOS 心情评分与健康聚合 |
| `pipeline/snapshots.py` | 内容 hash、每日 JSON、manifest、过期清理 |
| `pipeline/assets.py` | 合并 CSS/JS 并生成单文件 HTML |
| `pipeline/runtime.py` | 编排构建与多端同步 |

`build.py` 保留为兼容入口；旧脚本可以直接继续调用，不必关心内部模块变化。

## 4. macOS 数据边界

- `ActivityModels.swift` / `ActivityClassifier.swift`：活动类型与分类。
- `ActivityStore.swift`：实时采集状态和持久化。
- `ActivityFusionEngine.swift` / `ActivityConfidenceEngine.swift`：把实时片段与项目管道融合，避免重复计时长。
- `AppDatabase.swift` + `DatabaseModels.swift` + `DatabaseTime.swift`：SQLite 边界。
- `AIProvider.swift` / `AIKeychain.swift` / `AIModels.swift` / `AIAssistantStore.swift`：AI 配置、安全存储、请求上下文与任务状态。
- Views 已从巨型文件中拆出导航、日期选择、AI 连接卡等稳定子视图。

## 5. 统一验证

```bash
make check       # Web + Python 管道
make swift-test  # macOS SwiftPM 测试
make ios         # Web 测试 + iOS 编译
```

发布前建议依次执行：

```bash
make check && make swift-test && make ios
```
