# 用户记忆控制台 · MemoryOS Console

状态：**前端重写完成并已静态部署，原生导出与真实账号/副本联调待验（T44）**。本文记录当前实现与边界，不是发布验收。产品取舍与任务状态以 [主规划](../../主规划.md) 为准，视觉规则以 [DESIGN](../../DESIGN.md) §8 为准。

## 1. 定位

用户中心原来只管理账号。MemoryOS 控制台把它扩展成一只只读窗口：用户登录后能管理身份、设备、权益与反馈，也能在本地打开一份由原生 App 导出的记忆副本，重读自己的文字、地点、章节与 River 的理解卡。

它不是第二个编辑器，也不是第二个日记事实库：

- 账号服务继续只处理身份、设备、会话、权益、反馈与安全活动。
- 记忆正文、地点、标签、健康与 AI 对话不从网页上传。
- 控制台不写回原生数据库；修改、补写与同步仍在 Mac / iPhone。
- “问 River”在本轮是本机检索，不调用模型，不伪造生成式回答。

## 2. 信息结构

| 空间 | 用户任务 | 主要数据 |
|---|---|---|
| 记忆首页 | 回到今天、最近与旧日回声 | 统计、最近记忆、那年今天、久未重读、待确认理解 |
| 长河 | 找一段过去 | 全量记忆、日期/年/类型/地点/标签/收藏/合集筛选、搜索 |
| 合集 | 按章节或主题重读 | 章节、收藏、主题标签 |
| 地点 | 在同一个地方遇见几次自己 | 地点名、首末日期、地点记忆 |
| 理解 | 核对 River 的暂定解释 | 理解卡、依据、范围、确认/纠正/撤销 |
| 问 River | 用自然语言找回原话 | 本机检索结果、引用、范围 |
| 账号与设置 | 管理身份与服务 | 概览、设备、会话、权益、密码、安全活动、反馈、偏好 |

桌面是浮动顶栏 + 左侧空间栏 + 阅读区；移动端固定底栏五个入口，合集与地点从首页/长河进入。七空间没有“故事/成长/实验/分享”等新顶级社交入口。

## 3. 数据流

```text
Mac / iPhone
  └─ T12 导出（待接入原生入口）
       └─ river.memory-mirror v1 或旧 entries 快照（JSON）
            └─ <input type=file> / 拖放
                 └─ File.text() → JSON.parse → normalizeArchive()
                      └─ 浏览器内存 + 当前标签页 sessionStorage
                           ├─ 长河筛选/搜索/本机回答
                           ├─ 收藏（仅 ID，localStorage）
                           └─ 理解卡决定（仅当前标签页）
账号
  └─ fr_session Cookie（Domain=.flowriver.xyz）
       └─ AccountClient.ensureSession()
            └─ /v1/me、/v1/me/devices、/v1/me/sessions、/v1/me/entitlements…
```

两条链路不交叉。记忆链路没有任何 `fetch`；账号链路在 `assets/account-core.js` 内集中处理。

## 4. 记忆副本契约

### 4.1 `river.memory-mirror` v1

```json
{
  "format": "river.memory-mirror",
  "version": 1,
  "exported_at": "2026-10-20T02:00:00+08:00",
  "persona": { "name": "林岸", "line": "一句可选的自述" },
  "entries": [
    {
      "id": "d01",
      "occurred_at": "2026-10-20T07:42:00+08:00",
      "kind": "journal",
      "title": "窗边的十分钟",
      "body": "没有急着打开电脑。\n\n烧水，磨豆子。",
      "facts": ["当天还发生的事（可选）"],
      "tags": ["早晨", "日常"],
      "place": "杭州·拱宸桥",
      "mood": "平静",
      "weather": "晴",
      "source": { "type": "user", "label": "手写" },
      "favorite": true,
      "collectionIds": ["c8"],
      "tone": "sea"
    }
  ],
  "collections": [
    {
      "id": "c8",
      "title": "工作之外",
      "description": "章节的可选说明",
      "entryIds": ["d01"],
      "tone": "sea"
    }
  ],
  "understandings": [
    {
      "id": "u1",
      "statement": "换季时你更常写下关于睡眠和窗子的句子。",
      "evidenceIds": ["d06", "d13"],
      "scope": "2023–2026 · 春秋换季",
      "status": "pending",
      "kind": "rhythm"
    }
  ]
}
```

约束：

- `entries[].id` 使用 `[A-Za-z0-9_-]`；`collections[].entryIds`、`understandings[].evidenceIds` 必须引用这些 ID。控制台会保留安全显式 ID；没有安全 ID 时按日期/标题/正文生成稳定哈希。
- `date` 或 `occurred_at` 必填；没有可识别日期的条目会被跳过，并在导入报告里说明数量。
- `kind` 可放宽；未知值按 `journal` 读取。当前展示类型为 `journal / auto / note / photo / place / milestone`。
- `body` 是阅读正文；`facts` 是“当天还留下”的可选列表。不要把 AI 摘要写成用户原话。
- 建议原生导出只包含用户主动选择的范围，并在文件内写明导出时间与范围；控制台不假设这是完整历史。

### 4.2 旧 `data.json` 兼容

导入器也接受 `{ entries: [...] }` 的旧快照，并映射：

| 旧字段 | 控制台字段 |
|---|---|
| `date` / `page_id` | 日期 / 稳定 ID |
| `thoughts`、`overview`、`daily` | `body`（按原顺序组合） |
| `did[].items`、`memos` | `facts` |
| `tags`、`mood` | `tags`、`mood` |
| `daily` / `screen_apps` / `screen_note` | `kind=auto`、来源“自动日记” |

旧快照没有章节/理解卡时，对应的两个空间显示空态，不推导新结论。

## 5. 存储与清除

| 键 | 位置 | 内容 | 生命周期 |
|---|---|---|---|
| `river.console.archive.v1` | `sessionStorage` | 归一化后的记忆副本（含正文），带 `ownerId` | 当前标签页；关闭后清除；账号切换时不恢复 |
| `river.console.understanding.v1` | `sessionStorage` | 理解卡状态与用户纠正 | 当前标签页；关闭后清除 |
| `river.console.favorites.v1` | `localStorage` | 仅记忆 ID → 收藏布尔值 | 当前浏览器；用户可清除 |
| `river.console.theme.v1` | `localStorage` | 外观偏好 | 当前浏览器 |

- 文件上限 25 MB；会话存储超过约 4.6 MB 时只保留在内存，页面会明确提示刷新后需要重新导入。
- `?preview=1` 演示模式不写 `sessionStorage`；导入副本只保留在内存，刷新后回到合成示例。
- 控制台不把正文写入 `localStorage`，不写 IndexedDB，不建立浏览器端长期记忆库。
- 副本绑定当前账号 ID；同一标签页换账号时，`restoreArchive()` 会清除旧副本、旧收藏与当前标签页理解决定，避免把上一位用户的记忆显示给下一位。
- “清除本机副本”只清当前标签页的内存/会话副本；不删除原生 App、加密备份或账号资料。

## 6. 搜索与本机回答

`assets/memory-core.js` 是纯函数模块，无网络、无 DOM：

1. `parseDateIntent()` 解析今天/昨天、年、月、季节、最近 N 天/月/半年。
2. `queryTerms()` 移除日期短语和问题填充词，保留中文短语与二元片段。
3. `searchEntries()` 在标题、正文、标签、地点、心情上打分；日期意图先过滤；结果按分数与时间排序。
4. `answerFromMemory()` 只做抽取式回答：
   - 引言说明范围和命中数量；
   - 每条 finding 引用日期、标题和原话片段；
   - “什么时候/最早/开始”优先返回最早一条；
   - 没有命中时返回 `ok=false` 和可选改问方式；
   - 固定注明“本机检索 · 未调用模型 · 未上传”。
5. 回答不会生成原文没有的原因、诊断或人格判断；引用 ID 只在本机副本内解析。

## 7. 账号传输

`assets/account-core.js` 保留既有安全语义：

- 读取 `Domain=.flowriver.xyz` 的首方 `fr_session`；无会话 fail closed。
- access token 到期前 60 秒内刷新；401 时先强制刷新一次再重放。
- 刷新与写操作带 `Idempotency-Key`；刷新请求键持久化在会话 cookie 中。
- 401 最终失败清除 cookie；账号切换刷新页面。
- 密码、令牌不写入页面正文、`localStorage` 或日志。
- 账号接口：`/v1/me`、`/v1/me/entitlements`、`/v1/me/devices`、`/v1/me/sessions`、`/v1/me/password`、`/v1/me/activity`、`/v1/me/feedback`、`/v1/me/redemptions`、`/v1/me/reauth/*`、`/v1/me/deletion`、`/v1/me/activation-codes/redeem`、`/v1/auth/*`。

失败处理：

- 网络失败保留表单输入，显示可重试状态；不把读取失败显示成空列表。
- 设备/会话撤销与退出在服务端接受后才清理会话。
- 注销按“申请 → 邮箱二次验证 → 提交 → 等待安全日志”分段反馈；服务端 fail-closed 时如实显示。

## 8. 视觉与可访问性

- 三套外观：柔光、手记、夜色；token 与原生海雾蓝/暖白/深蓝对应，见 `website/user/assets/style.css`。
- 24px 面板、相向柔和阴影、内凹输入、浮动半透明顶栏；标题使用衬线，正文/控件使用系统无衬线。
- River Glyph v2 通过 `tools/build_glyphs.py` 从共享 SVG 生成 `assets/glyphs.svg`，并内联进 `index.html` 的 `glyph-sprite` 块；避免跨文档 `<use>` 在 Safari 的差异，不维护第二套网页图标。
- 键盘可达：空间导航、筛选、卡片、对话框、账号表单；`Escape` 关闭原生 `dialog`；焦点环可见，程序化聚焦标题不画焦点框。
- `prefers-reduced-motion` 关闭漂移/位移；触控目标至少 44px（coarse pointer 下小按钮与列表行提升）。
- 320/390/768/1024/1440 宽度无横向溢出；移动底栏不遮断必要动作。
- 正文与次级文字使用加深后的 `--ink-2/--ink-3`；状态不只靠颜色（标签同时有文字）。

## 9. 验证与未完成

本轮验证见 [控制台验收](../validation/USER_MEMORY_CONSOLE_2026-10-20.md)：

- 32 项 Node 测试通过（记忆核心 16、账号传输 8、结构/隐私 8）。
- Chromium 桌面/移动七空间检查、导入/搜索/回答/收藏/理解卡/账号七栏目与 mock API 流程通过。
- 已部署静态前端到 `https://user.flowriver.xyz/`，现有 Caddy CSP/缓存头与预览页通过检查；未接真实账号、未接真实原生副本、未做真机 VoiceOver/Safari/WebKit。

仍待：

1. 原生 App 导出入口、字段契约冻结与真实副本联调（T12/T44）。
2. 真实账号/生产接口联调；确认 401、刷新键、密码、注销与 fail-closed 行为（T20/T44）。
3. 真实登录后的生产账号旅程与静态资源缓存失效策略；现有 CSP、Referrer-Policy、缓存头已验证，禁止把副本放进站点目录。
4. 真实设备、最佳辅助字号、VoiceOver、Safari/WebKit 与三外观视觉验收。
5. 大副本加密/大小边界/会话存储降级；多 profile 隔离。
6. 可选：把本轮 Playwright 手工流程固化为仓库内可重复的 UI 测试，并接入发布前置。

## 10. 相关文件

- 页面：`website/user/index.html`
- 样式：`website/user/assets/style.css`
- 控制器：`website/user/assets/app.js`
- 记忆核心：`website/user/assets/memory-core.js`
- 账号传输：`website/user/assets/account-core.js`
- 示例记忆：`website/user/assets/demo-data.js`
- 图标构建：`website/user/tools/build_glyphs.py`
- 测试：`website/user/tests/*.test.mjs`
