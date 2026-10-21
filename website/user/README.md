# 用户记忆控制台（MemoryOS Console）

`user.flowriver.xyz` 的纯静态前端。线上：<https://user.flowriver.xyz/>；演示预览：<https://user.flowriver.xyz/?preview=1>。它有三个部分，其中云空间是唯一显式开启的跨设备分支：

1. **账号服务**：登录态、设备与会话、权益与兑换、密码、安全活动、反馈与注销。请求同源 `/v1/*`，复用 `fr_session` 首方 Cookie。
2. **本机记忆副本**：用户选择一份由原生 App 导出的 JSON，在浏览器里解析、筛选、搜索和重读。默认不上传，不调用模型，不写回原生库。
3. **可选云空间**：用户设置云端口令并明确同意后，由浏览器用 PBKDF2-SHA-256（600,000 次）+ AES-GCM-256 加密整份只读副本；服务端只保存密文、公开 KDF 参数与白名单摘要，无法解密。另一台设备登录同账号、输入同一口令即可下载并本机解密。

产品与任务状态见 [主规划](../../主规划.md) §2.2 / §2.3（T44/T45）；视觉规则见 [DESIGN](../../DESIGN.md) §8；实现与契约见 [架构说明](../../docs/architecture/USER_MEMORY_CONSOLE_2026-10-20.md)。

## 数据从哪里来

控制台不产生日记，也不提供网页速记。它只有三个只读来源：

1. 用户选择的 `river.memory-mirror` JSON（含原生导出的设备上下文 `kind=context`）或旧 `entries` 快照；
2. 同一账号在另一台设备已上传、并从云空间下载解密的加密快照；
3. 内置的合成演示副本（仅预览）。

Mac 当前源码在「设置 → 隐私与备份 → 网页控制台副本」提供 `river.memory-mirror` 只读 JSON 导出；iPhone 当前源码在「设置 → 导出我的记录 → 网页控制台」提供同一格式。条目由当前本机可读的旧版 `DiaryData` 转换，并追加本机已同步到的 Mac/iPhone 设备上下文（`kind=context`）；合集/理解卡暂为空。

仍有两个边界：一是当前安装包未必包含这个新入口，需要更新构建；二是导出暂未包含 V2 长期记忆、随手记与合集/理解卡，完整 `river.memory-mirror` 映射仍属 T12。不能把空白页面误认为“已同步”。

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
| `assets/account-core.js` | Cookie 会话、刷新、401 重放、幂等、云空间请求头与错误映射 |
| `assets/cloud-core.js` | 端到端加密：PBKDF2、AES-GCM、摘要、口令策略 |
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

当前 38 项通过：记忆核心 18、账号传输 8、结构/隐私 8、云空间加密 4。浏览器流程（导入、搜索、命令面板、收藏、理解卡、账号 mock API、双设备云空间、桌面/移动布局）在本轮用 Chromium 手工验证，尚未固化为仓库内 UI 测试。

## 导入格式

优先读取 `river.memory-mirror` v2（`contexts` 会映射成只读设备上下文；v1 仍兼容）：

```json
{
  "format": "river.memory-mirror",
  "version": 2,
  "contexts": [],
  "entries": [
    { "id": "d01", "occurred_at": "2026-10-20T07:42:00+08:00", "title": "窗边的十分钟", "body": "…", "tags": ["早晨"], "place": "杭州·拱宸桥" }
  ],
  "collections": [{ "id": "c1", "title": "章节", "entryIds": ["d01"] }],
  "understandings": [{ "id": "u1", "statement": "…", "evidenceIds": ["d01"], "scope": "…", "status": "pending" }]
}
```

也兼容旧 `{ "entries": [...] }` 快照的 `date`、`title`、`thoughts`、`overview`、`did`、`tags`、`mood` 等字段。v2 的顶层 `contexts` 会被映射成 `kind: "context"` 的只读卡片；旧 v1 里的同名 entry 也兼容。设备上下文会参与长河筛选、搜索和问答。文件上限 25 MB；超过约 4.6 MB 时只保留在内存，刷新后需要重新导入。

原生网页副本导出与构建边界见 [网页副本导出验收](../../docs/validation/NATIVE_WEB_EXPORT_2026-10-20.md)。

云空间信封（`river.cloud-mirror` v1）只接受 `kdf`/`cipher`/`ciphertext`/`client_updated_at`/白名单 `summary`；客户端密文上限 8 MB，服务端 16 MB。详见 [云空间验收](../../docs/validation/USER_MEMORY_CLOUD_2026-10-20.md)。

## 数据边界

- 默认情况下，记忆正文、地点和标签不进入账号请求；账号服务只处理身份、设备、会话、权益、反馈与安全活动。只有你主动开启云空间后，账号接口才收到端到端加密密文和白名单摘要。
- 本机记忆副本写入当前标签页的 `sessionStorage`；关闭标签页后不保留。收藏只把记忆 ID 写入 `localStorage`；理解卡的确认/纠正只在当前标签页。云空间密文单独保存在账号服务，直到你删除或注销。
- 不读取浏览器定位，不请求 HealthKit，不调用模型。
- “清除本机副本”只清网页副本，不删除原生 App、云空间或加密备份；云副本在「账号与设置 → 云空间」单独删除。
- 页面不包含个人快照；演示数据全部为合成内容。发布前仍需按 T18/T44 做产物扫描。

## 发布

静态文件发布到 `/var/www/flowriver/user`；2026-10-20 已按此流程部署，线上验证见 [控制台验收](../../docs/validation/USER_MEMORY_CONSOLE_2026-10-20.md)。

```sh
rsync -av --delete website/user/ root@198.23.189.187:/var/www/flowriver/user/
```

注意：

- `/assets/*` 为绝对路径；站点必须部署在域名根路径。
- 网关需把 `/v1/*` 反代到账号 API；控制台与账号服务同源。
- 生产 Caddy 已配置 `Content-Security-Policy`、`Referrer-Policy`、HSTS 与静态缓存头；本轮已在生产 CSP 下验证同源模块、内联样式、数据 favicon、`blob:` 下载和云空间上传。修改 CSP 时仍需重跑这些路径。
- `?preview=1` 仅用于演示；生产环境是否保留入口需产品决定。它不会访问账号接口。

## 已知边界

- 控制台是只读查看器，不提供网页端速记、编辑或自动同步；首页/空态不展示“写一句”入口。
- 静态前端已于 2026-10-20 部署到 `user.flowriver.xyz`；旧版备份在服务器 `/var/backups/flowriver/`。
- Mac/iPhone 的网页副本导出入口已加入源码；Mac app 构建通过，iOS 全部 Swift 源码通过 SwiftPM 编译（完整 Xcode app bundle 仍受本机 SwiftPM 清单缓存权限阻塞）。当前 mirror 的 entries 来自旧版日记 `DiaryData`，V2 记忆/合集/理解卡仍待 T12。
- 真实账号与生产接口未在本轮联调；密码/注销/权限依赖服务端配置。
- 云空间跨设备传输已实现；原生 App 接入、8/16 MB 边界压测、多 profile 隔离与口令恢复/轮换仍未完成。
- Safari/WebKit、VoiceOver、最佳辅助字号与真实设备尚未验收。
- 账号密码、令牌、幂等键不写入页面存储；密码只存在于当前表单输入。
