# 用户记忆云空间验收 · 2026-10-20

状态：**Web 端已实现并部署；真实账号、原生 App、真机与最佳辅助技术验收待做（T45）**。本轮证据覆盖浏览器端到端加密、服务端密文接口、双设备浏览器流程与生产静态部署；不使用真实用户的日记或真实账号。

## 1. 交付范围

- 账号与设置新增第八栏目「云空间」：记忆首页、长河、合集、地点、理解、问 River、账号与设置的结构不变。
- 用户显式设置至少 12 个字符的云端口令，再次确认并勾选“理解口令丢失无法恢复”后，才允许上传；默认不开启、不自动上传。
- 浏览器在本机派生密钥并加密整份只读记忆副本，服务端只保存密文、KDF 参数、IV、格式版本、大小、白名单摘要、修订号和时间。
- 多端：另一台设备登录同一账号，进入「账号与设置 → 云空间」，输入同一口令即可下载并在本机解密。
- 删除：用户可单独删除云副本；删除本机副本不删除云副本；账号注销级联删除云副本。
- 生产静态前端、隐私政策与官网说明已同步更新。

## 2. 加密与数据边界

| 项目 | 选择 |
|---|---|
| 口令 | 12–128 个字符；NFC 规范化；不上传、不写入 localStorage/sessionStorage、不落库 |
| KDF | PBKDF2-SHA-256，600,000 次；随机 16 字节盐 |
| 加密 | AES-GCM-256；每次随机 12 字节 IV；附加认证数据 `river.cloud-mirror:v1` |
| 明文 | `river.memory-mirror` v1 只读副本：persona、entries、collections、understandings、exported_at |
| 信封 | `river.cloud-mirror` v1：format/version、KDF 参数、IV、base64 密文、客户端更新时间、白名单摘要 |
| 服务端可见 | 密文、盐、迭代次数、IV、大小、修订号、时间、段数/天数/地点数/合集数/理解数/首末日期 |
| 服务端不可见 | 口令、明文正文、位置文本、健康内容、AI 对话、原始文件 |
| 上限 | 服务端密文 16 MB、请求信封 24 MB；Web 客户端密文 8 MB |
| 口令丢失 | 无法恢复；服务端不能重置，也不存在后门 |

服务端只做密文存取，不调用 KMS 解密、不记录口令、不把密文返回给其他账号。摘要字段在服务端按白名单重建，未知字段直接拒绝，避免把正文夹带进“元数据”。

## 3. API 与存储

迁移 `0012_user_memory_mirrors` 新增 `user_memory_mirrors`：

- `user_id` 主键，`ON DELETE CASCADE`。
- `revision` 从 1 开始，每次替换 +1。
- KDF/ cipher 参数、`ciphertext bytea`、`client_updated_at`、`summary jsonb`、创建/更新时间。
- 密文 1 B–16 MB、盐 16 B、IV 12 B、迭代次数 100,000–2,000,000 的数据库约束。

接口：

| 方法 | 路径 | 行为 |
|---|---|---|
| GET | `/v1/me/memory-mirror/meta` | 只返回是否存在、rev、大小、时间、KDF/ cipher、摘要；不含密文 |
| GET | `/v1/me/memory-mirror` | 返回本人密文与参数；无副本 404 |
| PUT | `/v1/me/memory-mirror` | `If-None-Match: *` 创建；`If-Match: "<rev>"` 替换；无前置条件 428；冲突 409/412 |
| DELETE | `/v1/me/memory-mirror` | 必须 `If-Match`；无副本 404；修订不符 412 |

所有接口要求 Bearer 登录；上传/下载/删除写入 `audit_events`，不写密文或正文。用户级限流：上传 20/小时、下载 120/小时、删除 30/小时、meta 240/小时；429 带 `Retry-After`。API 的读/写超时从 10/15 秒调整为 45/45 秒，以容纳 8 MB 客户端上限；仍保留 5 秒头部超时、32 KB 头部上限和路径级 24 MB 请求上限。

## 4. 自动化与浏览器证据

### 4.1 Node

```sh
cd website/user
node --test tests/*.test.mjs
node --check assets/app.js assets/cloud-core.js assets/account-core.js assets/memory-core.js assets/demo-data.js
```

- **35 项通过**：原有 32 项 + `tests/cloud-core.test.mjs` 3 项。
- cloud-core 覆盖：加密/解密往返、密文不含明文、错误口令、篡改密文、口令策略、Base64 分块与摘要字段。
- structure 新增：云空间表单、`If-None-Match`、同意勾选、`cloud-core.js` 本地资源、无 `fetch` 明文旁路。

### 4.2 Go

```sh
cd server
TEST_DATABASE_URL='postgres://…/flowriver_test?sslmode=disable' \
  go test ./...
```

- 全部包通过（含 `TestMemoryMirrorIsScopedAndPreconditioned`）。
- 覆盖：未登录 401；空 meta；无条件创建 428；创建 201；meta 不返回密文；下载返回密文；另一账号 404；无条件替换 428；过期 rev 412；重复创建 409；删除无条件 428/过期 412/他人 404；正确删除 204；审计按账号隔离；非法 KDF 400；摘要夹带未知字段 400。
- 集成测试使用隔离 PostgreSQL 16 UTF-8 schema；线上库为 PostgreSQL 16.15。

### 4.3 浏览器双设备

Playwright Chromium，同一合成账号、两个独立 browser context：

1. A 导入 49 段合成副本，云空间设置口令并勾选同意，上传成功；请求体 28,517 字节密文，不含“烧水”等明文；服务端只看到信封。
2. B 登录同账号、无本机副本，云空间显示“已保存 v1”；错误口令返回“口令不正确，或云副本已损坏”；正确口令下载、解密并载入首页。
3. B 首页显示“加密云副本”，sessionStorage 有副本；云空间状态、首页“已加密上云”和账号活动标签一致。
4. 390×844 与 320×800：无横向溢出；账号栏目横向滚动会自动把“云空间”滚到可见位置。
5. 生产 `https://user.flowriver.xyz/#/account/cloud` 在现有 Caddy CSP 下用 mock API 完成加密上传，无 console/page error；CSP 允许同源模块、内联样式和数据 favicon，`connect-src 'self'` 允许 `/v1`。

![云空间上传](../../output/qa/user-console-2026-10-20/20-cloud-upload-desktop-soft.png)

![另一设备解密后的首页](../../output/qa/user-console-2026-10-20/21-cloud-download-home-desktop-soft.png)

![移动端云空间](../../output/qa/user-console-2026-10-20/22-cloud-mobile-soft.png)

## 5. 生产部署

- 时间：2026-10-20 12:33–22:08（Asia/Shanghai；服务器 UTC 04:33–14:08；12:45 追加限流，12:52 追加下载替换确认，13:19 同步，14:12 移除本机速记，22:08 指向原生网页副本入口）。
- API 二进制：SHA-256 `4a742806f4da4041ab9aa29065f4ab31430c64ae6a541c8402eae2efe5be70c0`（含 20/小时上传、120/小时下载、30/小时删除、240/小时 meta 的用户级限流）；旧二进制备份 `/var/backups/flowriver/flowriver-api-before-cloud-20261020T043346Z` 与 `/var/backups/flowriver/flowriver-api-before-cloud-rate-20261020T044535Z`。
- 数据库：迁移 `0012_user_memory_mirrors` 已应用，`public.user_memory_mirrors` 存在；部署前备份 `/var/backups/flowriver/db-before-cloud-20261020T043346Z.sql.gz`（SHA-256 `f50faec66ab6ed306a6b3834c17e01b8f624b81fc005629d5210194d0cb42088`）。
- 前端：部署包 `river-console-webexport-20261020.tar.gz` SHA-256 `2c9c6dfc1d93e340c7fbc86e1e17498216ceffcbd3f6be5ecda1e026a928d825`；旧前端备份 `/var/backups/flowriver/user-console-before-cloud-20261020T043611Z`、`…-v2-20261020T045239Z`、`…-v3-20261020T051936Z` 与 `user-console-before-readonly-20261020T061259Z`、`user-console-before-webexport-20261020T140758Z`。
- 线上前端：`index.html` `f5047ff6…`、`assets/app.js` `806cab91…`、`assets/account-core.js` `ea4f2950…`、`assets/cloud-core.js` `02b6f9ef…`、`assets/style.css` `133c57aa…`。
- Caddyfile SHA-256 `289ef804…` 未变；Caddy/API 均 active；`/health/live`、`/health/ready` 200；匿名 `/v1/me/memory-mirror/meta` 401。
- 资源使用 cache-busting 查询 `v=20261020-cloud`；`cloud-core.js` 为新增模块。
- 隐私页 `/privacy.html`、服务条款 `/terms.html` 与官网首页云服务说明已更新并部署，旧文件备份在 `/var/backups/flowriver/site-*-before-cloud-*.html`。
- 部署指纹：[user-cloud-deployment.json](evidence/2026-10-20/user-cloud-deployment.json)。

## 6. 明确未验

- 未使用真实账号执行生产登录后的云空间上传/下载/删除；生产浏览器测试使用合成会话 + `/v1` mock。
- 未接原生 App 导出/恢复；当前多端是 Web 控制台之间的手动快照。
- 未做 Safari/WebKit、真实 iPhone/Mac、VoiceOver、最大辅助字号与三外观人工审计。
- 未做 8 MB 边界端到端压测、数据库 TOAST/备份恢复、并发多设备真实写入、网络中断重试、浏览器配额与多 profile。
- 未做服务端密钥轮换/密码策略帮助/口令提示；口令丢失即不可恢复是设计选择。
- 未做云副本版本历史；只保留当前修订。管理后台不展示云副本内容，数据库管理员理论上可读取密文但无口令。

## 7. 仍待 T45

1. 原生导出/恢复入口接入 `river.memory-mirror`，完成真实 Mac/iPhone → 云空间 → 另一端的旅程。
2. 真实账号生产验收：401 刷新、创建/替换/删除、审计、账号注销级联。
3. Safari/WebKit、真机、VoiceOver、最佳辅助字号和三外观。
4. 8/16 MB 边界、TOAST/备份/恢复、并发冲突、网络中断和浏览器配额。
5. 可选：记忆密钥恢复/轮换设计、云端版本历史、自动同步策略（默认仍应显式）。
