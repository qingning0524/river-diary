# 用户记忆控制台（MemoryOS Console）

`user.flowriver.xyz` 的纯静态前端。线上：<https://user.flowriver.xyz/>；演示预览：<https://user.flowriver.xyz/?preview=1>。它有两个互不交叉的部分：

1. **账号服务**：登录态、设备与会话、权益与兑换、密码、安全活动、反馈与注销。请求同源 `/v1/*`，复用 `fr_session` 首方 Cookie。
2. **本机记忆副本**：用户选择一份由原生 App 导出的 JSON，在浏览器里解析、筛选、搜索和重读。正文不上传，不调用模型，不写回原生库。

产品与任务状态见 [主规划](../../主规划.md) §2.2 / T44；视觉规则见 [DESIGN](../../DESIGN.md) §8；实现与契约见 [架构说明](../../docs/architecture/USER_MEMORY_CONSOLE_2026-10-20.md)。

## 本地预览

```sh
cd website/user
python3 -m http.server 8099 --bind 127.0.0.1
```

- 演示：<http://127.0.0.1:8099/?preview=1>
- 直接打开 `/` 会要求登录；本地没有后端时无法完成真实账号流程。
- 账号页面在演示模式下只显示说明，不发起请求。演示模式导入的副本只保留在内存，刷新后回到合成示例。

## 文件

| 路径 | 内容 |
|---|---|
| `index.html` | 应用外壳、导航、对话框与静态说明 |
| `assets/style.css` | 三套外观与响应式材质 token |
| `assets/app.js` | 路由、渲染、导入、账号交互 |
| `assets/memory-core.js` | 无 I/O 的记忆归一化、筛选、搜索、抽取式回答 |
| `assets/account-core.js` | Cookie 会话、刷新、401 重放、幂等与错误映射 |
| `assets/demo-data.js` | 全部合成的演示记忆；不读取 `data/` |
| `assets/glyphs.svg` | 从 `图标素材库/` 生成的 River Glyph v2 雪碧图（同时内联进 `index.html`） |
| `tools/build_glyphs.py` | 重新生成雪碧图并内联；不要手改产物 |
| `tests/*.test.mjs` | Node 内置测试，无需 npm 依赖 |

## 测试

```sh
cd website/user
node --test tests/*.test.mjs
node --check assets/app.js
```

当前 32 项通过：记忆核心 16、账号传输 8、结构/隐私 8。浏览器流程（导入、搜索、命令面板、收藏、理解卡、账号 mock API、桌面/移动布局）在本轮用 Chromium 手工验证，尚未固化为仓库内 UI 测试。

## 导入格式

优先读取 `river.memory-mirror` v1：

```json
{
  "format": "river.memory-mirror",
  "version": 1,
  "entries": [
    { "id": "d01", "occurred_at": "2026-10-20T07:42:00+08:00", "title": "窗边的十分钟", "body": "…", "tags": ["早晨"], "place": "杭州·拱宸桥" }
  ],
  "collections": [{ "id": "c1", "title": "章节", "entryIds": ["d01"] }],
  "understandings": [{ "id": "u1", "statement": "…", "evidenceIds": ["d01"], "scope": "…", "status": "pending" }]
}
```

也兼容旧 `{ "entries": [...] }` 快照的 `date`、`title`、`thoughts`、`overview`、`did`、`tags`、`mood` 等字段。文件上限 25 MB；超过约 4.6 MB 时只保留在内存，刷新后需要重新导入。

## 数据边界

- 记忆正文、地点和标签不进入账号请求；账号服务只处理身份、设备、会话、权益、反馈与安全活动。
- 记忆副本写入当前标签页的 `sessionStorage`；关闭标签页后不保留。收藏只把记忆 ID 写入 `localStorage`；理解卡的确认/纠正只在当前标签页。
- 不读取浏览器定位，不请求 HealthKit，不调用模型。
- “清除本机副本”只清网页副本，不删除原生 App 或加密备份。
- 页面不包含个人快照；演示数据全部为合成内容。发布前仍需按 T18/T44 做产物扫描。

## 发布

静态文件发布到 `/var/www/flowriver/user`；2026-10-20 已按此流程部署，线上验证见 [控制台验收](../../docs/validation/USER_MEMORY_CONSOLE_2026-10-20.md)。

```sh
rsync -av --delete website/user/ root@198.23.189.187:/var/www/flowriver/user/
```

注意：

- `/assets/*` 为绝对路径；站点必须部署在域名根路径。
- 网关需把 `/v1/*` 反代到账号 API；控制台与账号服务同源。
- 建议由 Caddy 统一增加 `Content-Security-Policy`（至少 `script-src 'self'`）、`Referrer-Policy: no-referrer` 与静态缓存头。CSP 上线前需实际验证外部 SVG `<use>`、`blob:` 导出和 `style` 属性。
- `?preview=1` 仅用于演示；生产环境是否保留入口需产品决定。它不会访问账号接口。

## 已知边界

- 静态前端已于 2026-10-20 部署到 `user.flowriver.xyz`；旧版备份在服务器 `/var/backups/flowriver/`。
- 原生 App 的导出入口与字段契约尚未接入（T12/T44）；当前只能用约定 JSON 或旧快照预览。
- 真实账号与生产接口未在本轮联调；密码/注销/权限依赖服务端配置。
- 大副本加密、跨设备副本传输与多 profile 隔离未实现。
- Safari/WebKit、VoiceOver、最佳辅助字号与真实设备尚未验收。
- 账号密码、令牌、幂等键不写入页面存储；密码只存在于当前表单输入。
