# 情绪河流 · 每日自动记录

用数据把每天的情绪、精力、专注与产出可视化，看见自己一点点变好。

## 项目结构（多文件产品版）

```
./
├── index.html          # 页面骨架（结构 + 元信息）
├── src/css/            # 样式源码模块
├── src/js/             # 逻辑源码模块
├── css/style.css       # 构建产物：合并后的样式
├── js/app.js           # 构建产物：合并后的逻辑
├── data/raw.json       # 唯一原始数据快照（日常更新这里）
├── data/data.json      # 清洗后的网页运行数据
├── build.py            # 合并、校验、清洗、同步 iOS 数据
├── tests/              # 数据管道自动化测试
├── dist/index.html     # 可直接分享的单文件构建产物
└── dist/index.html     # 单文件版（可直接双击打开 / 分享 / 部署）
```

## 本地运行

开发与部署前先构建：

```bash
python3 build.py
python3 -m unittest discover -s tests
python3 -m http.server 8000
# 打开 http://localhost:8000
```

单文件版不需要服务，直接双击 `dist/index.html` 即可（数据已内联）。

## ⚠️ 重要：数据管道如何接入（防止被覆盖）

原管道每天重写整个 `index.html`，会把代码改动全部冲掉（已发生过一次）。
现在请把管道改为**只更新 `data/raw.json`**；构建脚本会校验、清洗并同步网页和 iOS。

需要对外分享 / 部署单文件时，跑一次：

```bash
python3 build.py
```

会生成 `dist/index.html`（当前数据 + 最新代码的内联单文件）。

## 部署（任选其一）

1. 静态托管：把整个项目目录（index.html + css/ + js/ + data/）传到 Vercel / Netlify / GitHub Pages / OSS。
2. 单文件：只传 `dist/index.html` 到任意静态托管。

## 数据字段说明

`data/raw.json` / `data/data.json` 顶层结构：

```json
{
  "generated": "2026-08-19 22:41",   // 生成时间
  "today": "2026-08-19",             // 当前日期
  "poem": "每日一句诗词",
  "entries": [ /* 每天一条，见下 */ ],
  "social": { "2026-08-19": { /* 微信社交统计 */ } }
}
```

每条 entry 包含：`date`、`score`（心情分 0-100）、`score_source`（user/ai）、
`title`、`tags`、`status`、`mood`（一句话心情）、`overview`（AI 概览）、
`thoughts`（想法）、`did`（事项分组）、`memos`、`plan`、`metrics`（精力/专注/产出/综合/成长）、
`stage`（阶段标签）、以及原始数据 `screen_apps` / `browse_sites` / `hermes_logs` / `workbuddy`。

## 固定模块（与视频脚本对应，勿随意增删）

日记详情页固定六大模块，顺序按脚本叙事：

| 页签 | 数据来源 |
|---|---|
| 📝 随笔小记 | Notes.app「随笔」文件夹完整原文 + 规则化状态解读 |
| 💭 想法与心情 | `thoughts` |
| 📚 学习与工作 | 工作/学习/环境/自我类事项 + WorkBuddy 记录 + Hermes 协助记录 |
| 🎬 娱乐休息 | 娱乐/兴趣/生活类事项 + 屏幕时间 + 浏览足迹 |
| ❤️ 身心健康 | metrics 四维指标 + AI 判定依据（未来接入运动/睡眠数据在此扩展） |
| 📅 今日概览 | AI 概览（各支流汇流，置于末位） |

另有 📌 明日计划、🏷 标签与状态两个辅助页签。
深链支持：`#date=YYYY-MM-DD&tab=<key>`，key 取值 overview/memos/thoughts/learn-work/fun-rest/health/plan/meta。

## 展示相关功能

- 「📝 随笔小记」页签带 **状态解读**：自动分析随笔的情绪基调（低落/积极/复杂/平静）、精力状态、内容主题、状态标签，并生成一句话解读 + 要点摘录。
- 详情卡顶部有「📝 今日随笔」引用块 + 状态摘要（基调 · 精力 · 标签）。
- 深链：`index.html#date=2026-08-18&tab=memos` 可直接定位到某天的随笔页签。
- 日记详情页按脚本叙事平铺为固定模块页签；屏幕时间、浏览足迹、社交等洞察放在「数据洞察」。
- 顶栏 🔒 = 演示模式：只隐藏界面里的好友姓名，不会从数据文件中删除敏感内容；分享前请先确认数据本身可公开。
- 顶栏 ◐ = 深色 / 浅色切换；首次打开会跟随系统主题。
- 点击心情数字可临时修改 0–100 的分数，并保存在浏览器 `localStorage`；重新打开页面时仍会优先生效。
- 修改心情后会同步刷新河流图、历史列表、平均指标和分享数据；`?` 可打开评分说明。
- 页面支持键盘方向键切日期、日记页签方向键切换、`⌘K / Ctrl+K` 命令面板。

> 注：状态解读基于关键词词典的规则分析（离线、确定性强）。
> 若管道改为把随笔**完整原文**存入 `memos` 字段，解读会更准确、更丰富。
