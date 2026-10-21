# 用户记忆控制台验收 · 2026-10-20

状态：**前端完成并已静态部署；本机速记已移除，控制台保持只读；Mac 网页副本导出构建通过，iOS 源码编译通过、app bundle 待验；真实账号/副本与真机验收待做（T44/T45）**。本文件覆盖本机静态前端、合成演示数据、合成账号会话与 mock API，以及生产静态部署；不覆盖真实账号登录或真实原生副本。云空间单独见 [云空间验收](USER_MEMORY_CLOUD_2026-10-20.md)。

## 1. 本轮完成

- 将 `website/user/` 从账号后台重写为 MemoryOS 只读控制台：
  **记忆首页 / 长河 / 合集 / 地点 / 理解 / 问 River / 账号与设置**。
- 三套外观：柔光（默认）、手记、夜色；保留原生海雾蓝拟态的画布、相向柔和阴影、内凹输入、24px 面板与浮动半透明顶栏。
- 桌面浮动顶栏 + 左侧空间栏；移动端固定底栏五个入口；320–1440 宽度响应式。
- 本机记忆副本导入：`river.memory-mirror` v1 与旧 `{ entries: [...] }` 快照兼容；文件只在浏览器解析，正文不经过账号接口。
- 长河筛选/搜索/日期意图；本机抽取式回答与逐条引用；收藏；理解卡确认/纠正/撤销；“那年今天”和“久未重读”。
- Mac「设置 → 隐私与备份 → 网页控制台副本」与 iPhone「设置 → 导出我的记录 → 网页控制台」的源码入口已接入；当前导出 `river.memory-mirror`（entries 来自旧版 `DiaryData`，合集/理解卡为空），Mac app 构建通过，iOS 源码 SwiftPM 编译通过、app bundle/安装待验。
- 账号八栏目：概览、设备与会话、权益与兑换、登录安全、安全活动、反馈与回复、资料与偏好、云空间；保留 401 刷新、幂等键、密码/注销流程与错误保留输入。
- River Glyph v2 通过本地雪碧图复用（`assets/glyphs.svg`，80 枚），不维护第二套网页图标。
- 空态、失败态、焦点管理、`prefers-reduced-motion`、触控目标与加深的次级文字对比。

## 2. 自动化测试

命令：

```sh
cd website/user
node --test tests/*.test.mjs
node --check assets/app.js
```

结果：

- **35 项通过，0 失败**（约 80ms）。
  - `tests/memory-core.test.mjs`：16 项，覆盖归一化、旧快照映射、日期、统计、筛选、日期意图、搜索、本机回答、那年今天、地点/标签/相关记忆、HTML 转义。
  - `tests/account-core.test.mjs`：8 项，覆盖 Cookie、 freshness、401 刷新重放、刷新键、最终 401 清会话、缺会话 fail-closed、错误文本、退出只在服务端接受后清 Cookie。
  - `tests/structure.test.mjs`：8 项，覆盖可访问文档骨架、本地资源、三外观 token、图标雪碧图、默认不上传/显式加密云空间、演示数据合成、七空间/八栏目、对话框与失败路径。
  - `tests/cloud-core.test.mjs`：3 项，覆盖 PBKDF2/AES-GCM 往返、错误口令/篡改、口令策略与摘要。
- `node --check` 对 `app.js`、`memory-core.js`、`account-core.js`、`demo-data.js` 通过。

## 3. Chromium 浏览器检查

使用 Playwright Chromium（本机缓存）在 `http://127.0.0.1:8099/?preview=1` 检查：

- 七空间 × 320/390/768/1024/1440 共 35 个页面尺寸：无横向溢出。
- 控制台无 `pageerror` / console error。
- 演示首页、长河、合集、地点、理解、问 River、账号预览、空态、夜色、手记截图见 [截图目录](../../output/qa/user-console-2026-10-20/)。
- 导入：合成 `river.memory-mirror` JSON、Swift core 生成的 `native-mirror-sample.json` 与构造的旧 `entries` 快照；报告段数/天数/地点/章节；真实登录态确认后仅当前标签页；演示模式只保留在内存；清除后回到空态。
- 交互：命令面板（⌘K、↑↓、Enter）、卡片详情、复制原话、收藏、回到那天、筛选清除、合集跳转、地点选中、理解卡确认/纠正/撤销、本机回答、主题切换。
- 移动端：390×844 首页与长河；底栏固定，日期列不换行，无横向溢出。
- 空态：清除副本后提供导入、示例、从云空间恢复（登录时）与客户端入口；控制台不提供网页速记。
- 账号隔离：合成账号 A 导入副本后切换为账号 B 并刷新，旧副本、旧收藏与当前标签页理解决定被清除，B 看到空态而不是 A 的记忆。

### 3.1 账号 mock 流程

用合成 `fr_session`、合成账号资料与 Playwright 路由拦截 `/v1/*`，实际点击：

- 概览、设备与会话、权益与兑换、登录安全、安全活动、反馈与回复、资料与偏好全部渲染。
- 密码：请求验证码 → 填写 8 位码与新密码 → 提交 → 新会话写回 → 重新读取账号资料；“密码已更新”反馈出现。
- 注销：申请 → 邮箱验证 → 提交 → 等待安全日志确认；验证码、二次确认与错误保留路径可用。
- 反馈：提交后刷新列表，草稿在失败时保留（由 `withBusy`/状态行实现）。
- 兑换：确认弹窗后提交，刷新权益。
- 设备撤销：非当前设备撤销后刷新列表；当前设备路径会退出登录。
- 无 console error。

这些是 **mock API** 结果，不是生产账号、真实邮件或真实删除。

### 3.2 生产静态部署（2026-10-20）

- 地址：<https://user.flowriver.xyz/>；演示预览 <https://user.flowriver.xyz/?preview=1>。
- 首次部署：2026-10-20 10:48–10:58（Asia/Shanghai）；本次网页副本入口版本：22:08（服务器 UTC 14:08）。
- 方式：先备份目录，再上传部署包、`rsync -a --delete` 到 `/var/www/flowriver/user/`，设置 `root:root`、目录 755、文件 644；未修改 Caddy。
- 备份：`/var/backups/flowriver/user-console-before-20261020T024810Z`（旧账号后台）、`…-20261020T025826Z-v2`（首次新控制台）、`user-console-before-cloud-20261020T043611Z`（云空间前）、`user-console-before-cloud-v2-20261020T045239Z`（下载替换确认前）、`user-console-before-cloud-v3-20261020T051936Z`（最终同步前）、`user-console-before-readonly-20261020T061259Z`（移除本机速记前）、`user-console-before-webexport-20261020T140758Z`（原生网页副本入口说明前）。
- 本次部署包：`river-console-webexport-20261020.tar.gz`，SHA-256 `2c9c6dfc1d93e340c7fbc86e1e17498216ceffcbd3f6be5ecda1e026a928d825`。
- 线上指纹：`index.html` `f5047ff6…`、`assets/app.js` `806cab91…`、`assets/cloud-core.js` `02b6f9ef…`、`assets/style.css` `133c57aa…`；Caddyfile `289ef804…` 未变。
- 生产检查：资源 200/MIME 正确；CSP/Referrer-Policy/HSTS/nosniff 生效；匿名 `/v1/me` 与 `/v1/me/memory-mirror/meta` 均 401；未登录根路径跳转登录页；Playwright 预览无 console error，长河搜索/详情/命令面板/问 River/账号预览/主题与 390 宽通过；生产 CSP 下 mock 账号完成云空间加密上传。
- 生产导入：预览合成 JSON 报告 49 段/49 天/16 地点；`sessionStorage` 为空，确认后只在内存。
- 未验：真实账号生产旅程、真实原生副本、Safari/WebKit、VoiceOver、真机与最佳辅助字号。
- 部署指纹：[user-console-deployment.json](evidence/2026-10-20/user-console-deployment.json)；云空间细节见 [云空间验收](USER_MEMORY_CLOUD_2026-10-20.md)；原生导出见 [网页副本导出验收](NATIVE_WEB_EXPORT_2026-10-20.md)。

## 4. 截图

| 截图 | 内容 |
|---|---|
| [01-home-desktop-soft](../../output/qa/user-console-2026-10-20/01-home-desktop-soft.png) | 记忆首页，柔光，1440 |
| [02-river-desktop-soft](../../output/qa/user-console-2026-10-20/02-river-desktop-soft.png) | 长河 |
| [03-collections-desktop-soft](../../output/qa/user-console-2026-10-20/03-collections-desktop-soft.png) | 合集与章节 |
| [04-places-desktop-soft](../../output/qa/user-console-2026-10-20/04-places-desktop-soft.png) | 地点 |
| [05-understanding-desktop-soft](../../output/qa/user-console-2026-10-20/05-understanding-desktop-soft.png) | 理解卡 |
| [06-ask-desktop-soft](../../output/qa/user-console-2026-10-20/06-ask-desktop-soft.png) | 本机回答 |
| [07-account-overview-desktop-soft](../../output/qa/user-console-2026-10-20/07-account-overview-desktop-soft.png) | 账号概览（mock） |
| [08-account-devices-desktop-soft](../../output/qa/user-console-2026-10-20/08-account-devices-desktop-soft.png) | 设备与会话（mock） |
| [09-home-mobile-soft](../../output/qa/user-console-2026-10-20/09-home-mobile-soft.png) | 移动首页 |
| [10-river-mobile-soft](../../output/qa/user-console-2026-10-20/10-river-mobile-soft.png) | 移动长河 |
| [11-home-desktop-night](../../output/qa/user-console-2026-10-20/11-home-desktop-night.png) | 夜色 |
| [12-home-desktop-journal](../../output/qa/user-console-2026-10-20/12-home-desktop-journal.png) | 手记 |
| [13-empty-home-desktop-soft](../../output/qa/user-console-2026-10-20/13-empty-home-desktop-soft.png) | 无副本空态 |
| [14-import-desktop-soft](../../output/qa/user-console-2026-10-20/14-import-desktop-soft.png) | 导入报告 |
| [15-account-security-desktop-soft](../../output/qa/user-console-2026-10-20/15-account-security-desktop-soft.png) | 登录安全（mock） |
| [prod-home-desktop-soft](../../output/qa/user-console-2026-10-20/prod-home-desktop-soft.png) | 生产首页，柔光，1440 |
| [prod-ask-desktop-soft](../../output/qa/user-console-2026-10-20/prod-ask-desktop-soft.png) | 生产问 River |
| [prod-home-mobile-soft](../../output/qa/user-console-2026-10-20/prod-home-mobile-soft.png) | 生产移动首页 |
| [prod-account-overview-desktop-soft](../../output/qa/user-console-2026-10-20/prod-account-overview-desktop-soft.png) | 生产账号概览（mock API） |
| [20-cloud-upload-desktop-soft](../../output/qa/user-console-2026-10-20/20-cloud-upload-desktop-soft.png) | 云空间上传（合成账号） |
| [21-cloud-download-home-desktop-soft](../../output/qa/user-console-2026-10-20/21-cloud-download-home-desktop-soft.png) | 另一设备解密后的首页 |
| [22-cloud-mobile-soft](../../output/qa/user-console-2026-10-20/22-cloud-mobile-soft.png) | 移动端云空间 |
| [23-cloud-320-soft](../../output/qa/user-console-2026-10-20/23-cloud-320-soft.png) | 320 宽云空间 |
| [24-prod-cloud-upload-desktop-soft](../../output/qa/user-console-2026-10-20/24-prod-cloud-upload-desktop-soft.png) | 生产 CSP 下云空间上传（mock API） |
| [26-native-mirror-imported-desktop](../../output/qa/user-console-2026-10-20/26-native-mirror-imported-desktop.png) | 原生 `river.memory-mirror` 样本导入后的首页 |

截图均为合成数据；账号截图为 mock API，不是真实用户。

## 5. 明确未验

- 已部署静态前端与云空间服务端；未验证真实账号登录后的生产 API 旅程。
- 未接真实账号、真实邮件、真实注销或真实生产 PostgreSQL 写入。
- 原生网页副本导出已输出 `river.memory-mirror` v1；V2 长期记忆、随手记、合集/理解卡尚未导出；iOS app bundle/安装与真实旧数据导入未验（T12/T44/T45）。
- 未做真实 Safari/WebKit、iOS/Android 真机、VoiceOver、最大辅助字号与三外观人工视觉审计。
- 未做 8/16 MB 云副本边界、浏览器配额、跨标签页多副本、多 profile 隔离与真实并发写入。
- 未把 Playwright 流程固化为仓库内 UI 测试；Node 测试只覆盖纯逻辑、传输与静态结构。

## 6. 数据与隐私声明

- 演示数据全部为合成内容，人物“林岸”、地点与句子均为虚构。
- 未把 `data/` 里的个人快照用作演示、截图或测试夹具；旧快照兼容测试使用构造的合成条目。
- 截图中的账号邮箱为 `example.com`，账号 ID 与设备为 mock。
- 本轮新增云空间服务端迁移/API，但未使用真实账号写入云副本、未发真实邮件、未创建/删除真实账号。

## 7. 仍待 T44/T45 完成

1. 原生网页副本导出（Mac app 构建通过；iOS 源码编译通过，app bundle/安装待验）；完整 V2 字段与真实旧数据导入。
2. 真实账号/生产联调：401 刷新、刷新键、密码、注销 fail-closed、设备/会话撤销、反馈与兑换。
3. 真实登录后的生产账号旅程；静态资源版本与缓存失效策略（现有 CSP/Referrer-Policy/缓存头已验证）。
4. 真机、最佳辅助字号、VoiceOver、Safari/WebKit 与三外观视觉审计。
5. 大副本加密/大小边界/会话存储降级；多 profile 隔离。
6. T45：原生导出/恢复接入、真实账号云空间旅程、8/16 MB 与并发边界、真机与辅助技术。
7. 可选：把浏览器流程固化为可重复 UI 测试并接入发布门禁。

完成标志不是“页面能打开”，而是真实账号、真实副本、真实设备和生产账号旅程上的上述路径都有证据；在此之前 T44 只算静态前端部署完成，T45 只算 Web 端与密文接口完成。
