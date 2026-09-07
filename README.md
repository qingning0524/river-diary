<div align="center">

# 🌊 情绪河流 · River Diary

**用数据把每天的情绪、精力、专注与产出可视化，看见自己一点点变好。**

一端 Web，一端原生 iOS，一端原生 macOS。iOS 导出本地评分与健康摘要，macOS 负责定时采集、清洗和消费。

[**在线预览**](https://github.com/qingning0524/river-diary) · [iOS 工程](ios/RiverDiary) · [技术文档](docs/DATA_PIPELINE.md) · [License](#License)

[最近改造记录](docs/OVERHAUL_2026-09-04.md)

</div>

---

## ✨ 产品亮点

- **三端同源**：Web 单文件页 + SwiftUI iOS/macOS 应用，由同一份 `raw.json` 云同步驱动，各端看到同一份人生快照。
- **多维度自我观测**：每天自动汇总**心情 / 精力 / 专注 / 产出 / 综合 / 成长**六维指标，一条"河流图"回放情绪起伏。
- **六大叙事页签**：随笔小记、想法与心情、学习与工作、娱乐休息、身心健康、今日概览——不是冷冰冰的数据，是能读的日记。
- **隐私优先**：本地优先架构，健康与情绪数据不出设备；聊天原文与浏览明细从不上云、不进版本历史。
- **AI 加持（可选）**：随笔的情感基调与状态解读由规则引擎离线判定，确定性强、无需联网。

## 🖼️ 界面预览

| 手机端 | 桌面端 |
|:---:|:---:|
| ![手机端预览](预览图/手机端预览.png =x320) | ![桌面端预览](预览图/桌面端预览.png =x240) |

| 随笔状态解读 | 随笔展示 |
|:---:|:---:|
| ![状态解读预览](预览图/状态解读预览.png =x240) | ![随笔展示预览](预览图/随笔展示预览.png =x260) |

## 🛠️ 技术栈

| 端 | 技术 |
|---|---|
| **Web** | 原生 HTML/CSS/JS（零依赖，模块化 `src/` → `build.py` 打包单文件） |
| **iOS** | SwiftUI 原生应用，iOS 27 SDK 构建通过，健康数据接入 HealthKit |
| **数据管道** | Python `pipeline/`：校验 / 清洗 / 合并 / 同步（Web · iOS · iCloud） |
| **macOS 采集** | SwiftUI + HealthKit 导出快照 + `NSBackgroundActivityScheduler` 定时清洗 |
| **测试** | Python `unittest` 数据管道自动化测试 |

## 📁 项目结构

```
河流日记/
├── index.html          # Web 页面骨架
├── src/css|js/         # 模块化源码（构建合并）
├── build.py            # 兼容构建入口
├── pipeline/           # 清洗 / 快照 / 合并 / 打包模块
├── data/               # 数据（raw.json 唯一真相源，不进 git）
├── ios/RiverDiary      # SwiftUI 原生 iOS 工程
├── macos/RiverDiaryMac # SwiftUI 原生 macOS 应用 / 采集 / 打包脚本
│   └── Sources/RiverDiaryMac  # macOS 数据层、AI 与界面
├── tests/              # 数据管道自动化测试
├── docs/               # 技术文档
└── dist/index.html     # 可直接分享/部署的单文件构建产物
```

## 🚀 本地运行

```bash
# 1. 构建（合并样式、清洗数据、生成单文件、同步 iOS/iCloud）
python3 build.py

# 2. 跑完整校验（测试 + JS/JSON 检查）
make check

# 3. 三端发布前统一验证
make verify-all

# 4. 本地预览
python3 -m http.server 8000
# 打开 http://localhost:8000
```

> 单文件版不需要服务器，直接双击 `dist/index.html` 即可（数据已内联）。

iOS 端在 Xcode 打开 `ios/RiverDiary/RiverDiary.xcodeproj` 运行即可。

macOS 端可重新打包最新数据：

```bash
./macos/RiverDiaryMac/make_app.sh
```

## 🕹️ 交互特性

- 🎹 **键盘导航**：方向键切换日期，`⌘K / Ctrl+K` 命令面板
- 🏃 **健康恢复**：睡眠、步数、活动能量与心情同屏对照，近 7 天与前 7 天自动对比
- 🩺 **数据体检**：快速发现待评分、缺概览、缺计划的日期，不让记录链悄悄断掉
- 📤 **多格式导出**：单日 Markdown，全量 CSV 表格，完整 JSON 备份，全部离线完成
- 🧭 **关联线索**：用相关系数观察屏幕、步数、睡眠与心情的联动，只作线索不作因果
- 🔒 **演示模式**：一键隐藏界面里的好友姓名（数据文件本身不受影响，分享前请自行确认）
- ◐ **深色 / 浅色**：跟随系统，一键切换
- ✏️ **心情即时编辑**：点点数字即可改当日评分，保存在本机
- 🔗 **深链分享**：`#date=2026-08-18&tab=memos` 直达某天某页签

## 🧠 数据管道（本地优先）

`data/raw.json` 是**日记内容的原始真相源**。日常只更新它；构建脚本负责校验、清洗、合并 macOS 采集快照，并把同一份快照同步到 Web 与 iOS 两端。

```
iOS 本地数据 ──▶ river-diary-user-data.json（iCloud）
                       │
                       ▼
              macOS 定时采集 / 清洗 / 加密保存
                       │  （可选导出 data/ios-user-data.json）
                       ▼
raw.json ──▶ build.py ──▶ data/data.json（网页运行数据）
                     ├─▶ ios/RiverDiary/.../Resources/data.json（iOS）
                     ├─▶ iCloud Drive（可选同步）
                     └─▶ dist/index.html（单文件构建产物）
```

macOS 端在设置里选择数据源和频率；快照先加密保存在本机。从项目应用运行时，会自动导出清洗后的 `data/ios-user-data.json` 供构建读取。macOS 应用打开时按计划采集，关闭后不会继续运行。

**隐私保障**：聊天原文、浏览明细、原始健康样本不进入应用状态；消费的是聚合统计。个人日记数据通过 `.gitignore` 排除，绝不进入版本历史。

## 🧭 后续规划

- [ ] **屏幕时间采集**：接入 `DeviceActivityReport` 扩展，补齐 iOS 屏幕使用聚合
- [ ] **健康洞察**：把 HealthKit 睡眠/运动真正接入情绪分析，而非仅展示
- [ ] **多设备同步**：CloudKit private database（数据始终归用户账号）

## License

该项目为个人自用 / 作品集项目。数据严格本地持有，请勿用于任何收集他人隐私的场景。

---

<div align="center">Made with 🌊 · 情绪会沉淀，日子会向前</div>
