# 服务状态、安全联系与法律页面验收（Block 4）

状态：**代码、静态页面与文档已完成；生产尚未部署。** `/status` 依赖 Caddy 的 `redir`，`/.well-known/security.txt` 依赖静态目录同步；两者部署前不能对外宣称已上线。App 内“关于”只完成编译验证，没有真机点按截图。

## 1. 交付内容

| 物料 | 位置 | 说明 |
|---|---|---|
| 服务状态页 | `website/site/status.html` | 只检查账号 API 与下载分发是否响应；不展示 uptime 历史，不宣称 SLA |
| 状态页样式/脚本 | `website/site/assets/status.css`、`status.js` | 同源 `fetch('/v1/site-status')`；成功显示“可响应”和当前 macOS 下载版本，失败显示“暂时无法获取（可能网络或服务异常）” |
| `/status` 路径 | `website/deploy/Caddyfile` | `redir /status /status.html permanent`，与现有 `/terms`、`/privacy` 同一模式 |
| 安全联系 | `website/site/.well-known/security.txt` | RFC 9116 字段：Contact、Expires、Preferred-Languages、Canonical、Policy |
| 隐私政策 | `website/site/privacy.html` | 版本升到 `privacy-2 · 2026-10-22`；补健康摘要单独同意与真实备份链路 |
| 服务条款 | `website/site/terms.html` | 版本升到 `terms-2 · 2026-10-22`；补健康摘要进入密文的边界 |
| 官网入口 | `website/site/index.html`、`privacy.html`、`terms.html`、`website/user/index.html` | 页脚增加“服务状态” |
| App 内“关于” | macOS `AppearanceSettingsView.swift`；iOS `SettingsView.swift` | 隐私政策、服务条款、服务状态、安全联系四个 HTTPS 链接 |
| 共享链接常量 | `Packages/RiverDiaryCore/Sources/RiverDiaryCore/LegalLinks.swift` | 双端不再各自硬编码 URL；`LegalLinksTests` 固定 host/scheme/path |
| 备份运维手册 | `docs/operations/ENCRYPTED_BACKUP_CHAIN.md` | 服务器每小时 `pg_dump → zstd → age`，Mac 每日 03:20/15:20 拉取；含 RPO/RTO、密钥保管与隔离恢复步骤 |
| 旧教程校正 | `docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md` | 第 10 步加“2026-10-22 现状校正”，把 rclone 旧方案标为历史，指向新手册 |

## 2. 验证

### 2.1 代码与测试

| 项目 | 结果 | 证据 |
|---|---|---|
| Core 测试 | **110 tests / 11 suites passed**（新增 `LegalLinksTests` 1 项） | [core-tests.log](evidence/2026-10-22/block4/core-tests.log) |
| Mac 全量测试 | **495 项执行，0 failure，1 项环境跳过**（`DiskFullTests` 无法挂载临时磁盘镜像） | [mac-tests.log](evidence/2026-10-22/block4/mac-tests.log) |
| Mac app 构建 | `Build complete!` | 本机 `swift build --disable-sandbox --package-path macos/RiverDiaryMac` |
| iOS app 构建 | `** BUILD SUCCEEDED **`（隔离 HOME、arm64、禁用 Swift 前端 sandbox） | [ios-build.log](evidence/2026-10-22/block4/ios-build.log) |
| 静态文件 | `/status.html` 200 `text/html`；`/.well-known/security.txt` 200 `text/plain`；CSS/JS 200 | [website-smoke.txt](evidence/2026-10-22/block4/website-smoke.txt) |

### 2.2 状态页的两条路径

用无头 Chrome 在 1280×1000 与 390×844 下渲染：

- **成功路径**：mock `/v1/site-status` 返回 `macOS 1.0.0`，页面显示“账号 API 可响应”“macOS 1.0.0 可下载”，`aria-busy=false`。截图：[桌面](evidence/2026-10-22/block4/status-desktop.png)、[手机](evidence/2026-10-22/block4/status-mobile.png)。
- **失败路径**：静态服务器对 `/v1/site-status` 返回 404，页面显示“暂时无法获取（可能网络或服务异常）”与“随账号 API 一起检查”，不冒充服务正常。截图：[失败态](evidence/2026-10-22/block4/status-failure-desktop.png)。

**注意：** 成功路径的 `1.0.0` 是 mock 响应，不是生产下载数据；这里只证明前端分支和布局，不证明生产账号 API 已响应。

### 2.3 备份链路只读核对

数据采集于 2026-10-21 18:16 UTC（只读，未改服务器）：

- `flowriver-backup-local.timer` 下一次 19:00:45 UTC；上一次 18:01:50 UTC，`ExecMainStatus=0`；
- `backup-state.json`：`last_success_utc=2026-10-21T18:01:51Z`，对象 `flowriver-20261021T180150Z.sql.zst.age`，29,312 bytes；
- 备份目录 3 个密文，权限 `600 root:root`；
- Mac LaunchAgent `xyz.flowriver.backup-pull` 已加载，`runs=3`，`last exit code=0`；
- Mac 状态文件：`pulled_at_utc=2026-10-21T16:42:02Z`，`decrypt_verify=true`；最新服务器对象 18:01 尚未到下一次 19:20 UTC 拉取点。

原始输出：[backup-observation.txt](evidence/2026-10-22/block4/backup-observation.txt)。

## 3. 与实际一致的口径

- 云空间是**手动上传的只读快照**，不是自动同步；日记默认只在本机。
- 健康摘要默认不进入云副本；只有单独勾选“包含健康数据”并再次确认后才进入密文。服务端只保存密文与 `includes_health` 客户端声明，不能读取健康内容。
- 数据库备份不是“对象存储异机备份”：服务器本机保留 7 天，唯一异机副本由 Mac 每日两次拉取。RPO 最坏约 12 小时，不是 1 小时。
- 状态页没有 uptime 历史、没有第三方监控、没有外部告警；`/v1/site-status` 能响应不等于所有登录/上传路径都健康。
- `security.txt` 的联系邮箱是现有 `account@mail.flowriver.xyz`，没有单独的 `security@` 邮箱；`Expires` 为 2027-04-22。

## 4. 尚未验证 / 不能宣称

1. **生产未部署**：`https://flowriver.xyz/status` 目前不会返回状态页；`/.well-known/security.txt` 也未同步。必须 rsync `website/site/`、更新 Caddyfile 并 reload 后才能验收。
2. **Caddy 对 dotfile 的实际行为未测**：本地 Python 静态服务器返回 200；生产 Caddy 的 `file_server` 是否会直接提供 `.well-known/security.txt` 需要部署后 `curl -i` 确认。如果被拦截，应加显式 `handle` 而不是假设可用。
3. **App 内“关于”没有真机截图**：双端均编译通过，共享 URL 有单测；但没有在 iPhone/Mac 上点按打开 Safari 的截图或 VoiceOver 走查。
4. **状态页的成功数据是 mock**：生产 `/v1/site-status` 的真实响应尚未在同一页面验证。
5. **备份恢复没有完整演练**：只做了解密 + zstd 解压校验；没有在隔离 PostgreSQL 重放并核对行数，不能宣称 RTO。
6. **没有外部告警/第三份副本**：timer 失败只进 journal，Mac 拉取失败只进 launchd 日志；Mac 与服务器可能处于同一地区。
7. **法律文本未经律师审阅**：本次只做事实一致性修订，不构成法律意见。

## 5. 需要 PM

- **部署窗口与回滚确认**：同步 `website/site/` 与 `website/user/`，更新 `website/deploy/Caddyfile` 到 `/etc/caddy/Caddyfile` 并 reload；部署后跑 `/status`、`/.well-known/security.txt`、隐私/条款三个 URL 的 curl 验收。未获批准前保持现状。
- **安全联系邮箱**：确认继续用 `account@mail.flowriver.xyz` 接收安全报告，还是新设 `security@`；若要新设，需要邮箱/转发资源。
- **法律审阅**：隐私政策/条款涉及跨境、健康数据与备份保留，正式商用前需要 PM/法务确认；本次只保证与代码和运维事实一致。
- **备份告警与第三份副本**：若要达到“异机备份可用”的对外承诺，需要外部告警和对象存储/第二台异地设备；当前不能这样写。
