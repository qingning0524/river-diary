# FlowRiver 账号 API

Go API 和后台任务共用一个进程，PostgreSQL 保存账号、身份、设备、验证码与服务会话。账号库默认不接收 RiverDiary Event、日记正文、位置、AI 对话或同步密钥；只有用户显式开启云空间时，才保存一份端到端加密的密文和少量同步元数据，服务端不持有口令、不能解密。

Ubuntu 24.04 服务器部署步骤见 [服务器落地教程](../docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md)。`make release-linux` 会构建管理员前端，并打包 Linux amd64/arm64 安装包。教程包含 Mac 构建、DNS、数据库、生产配置、HTTPS、备份和更新方法。

`deploy/Caddyfile` 只包含 api/admin 两个站点，适合纯账号 API 主机。若同一台主机还承载官网、登录页或用户控制台，必须使用 `website/deploy/Caddyfile`（六站点），或把 api/admin 站点块合并进现有配置；直接覆盖 `/etc/caddy/Caddyfile` 会让官网/登录/控制台 404。安装时请用 `deploy/install-caddyfile.sh`：它会检测多站点目标、拒绝 API-only 覆盖、备份旧文件并在校验失败时回滚。

管理员后台已整合在同一 Go 服务的 `127.0.0.1:8081` 专用监听端口，Caddy 在 `admin.flowriver.xyz` 终止 TLS 并反向代理。独立的管理员账户使用 Argon2id 密码、TOTP、HttpOnly 会话 Cookie、Origin/CSRF 校验、IP/CIDR 限制、限速及设备撤销逐次审计。部署后通过 SSH 的 `admin bootstrap` 一次性创建第一个管理员。

用户首登邮箱验证码和激活码权益流程已纳入 iOS/macOS 客户端；后台支持按批次生成/导入、统计、查看尾号和撤销未用兑换码。部署与权益边界见[账号登录与权益兑换说明](../docs/operations/FLOWRIVER_ACTIVATION_CODES.md)。

若 SMTP、Apple 或异机安全日志暂未就绪，可用 `flowriver-api admin serve` 和 `deploy/flowriver-admin-only.service` 单独运行管理后台。该显式子命令仍要求 `APP_ENV=production`、生产 PostgreSQL、本地回环监听、管理密钥、正式 HTTPS Origin 和来源 IP 白名单；普通无参数启动继续执行全部账号服务生产校验。暂存用 `deploy/Caddyfile.admin-only` 将 `api.flowriver.xyz` 固定为 `503`，不会启动注册 API 或后台任务。外部依赖通过验收后，先停掉 admin-only unit，再安装正式 Caddyfile 并启用 `flowriver-api`。

管理台功能面(2026-10 扩展):更新日志管理(官网「更新日志」时间线与 `/v1/changelog` 由后台发布/编辑/删除驱动)、公告管理(官网公告条与 `/v1/site-status`、`/v1/announcements/active` 实时读取)、下载管理(上传安装包到 `DOWNLOAD_DIR`、一键开放/暂停下载,官网下载卡片自动切换「紧急修复中/开放下载」)、用户管理增强(邮箱前缀搜索、封禁/解封、强制下线、按用户查看与撤销会话、直接授予/撤销权益)、管理员管理(后台内创建/禁用管理员、在线管理会话查看与撤销、UI 重置 TOTP)、邮件任务重试、限流检查器(按邮箱/IP 查询并清零限流桶)、运营统计(30 天注册/兑换/邮件趋势)、备份历史(`backup_runs` 表,由 backup.sh 每次运行落库)、审计过滤(按操作/结果/时间)。所有写操作沿用「会话 + CSRF + 步进式 MFA + fail-closed 审计」链路;`DOWNLOAD_DIR` 为可选环境变量,不配置时下载管理仅展示不可上传。

页面是静态 Vue/Vite 文件并打入 Go 二进制，不在 2 核 2 GB VPS 上运行 Node 服务。用户、设备、邮件、安全事件、操作记录和 Linux 内存/系统盘/负载读取真实服务状态；备份脚本也会写入最近一次状态。恢复演练按钮只记录管理员报告的结果，不运行数据库恢复。[后台接口定义](api/admin-openapi.yaml)、[管理后台设计与落地状态](../docs/architecture/FLOWRIVER_ADMIN_CONSOLE_DESIGN.md)。

## 本地启动

2026-10 邮件重构：管理员邮件使用统一品牌模板（支持回复/产品通知/账号通知），HTML 与纯文本双版本，支持发送前预览、线程回复标识和发送历史内容快照。验证码也使用同一品牌体系。管理邮件先持久记录与审计，再提交 SMTP；稳定幂等键避免重复发送，未确认的投递显示待确认而不会自动重发。迁移 `0010_mail_formatting` 增加格式化快照及新入站邮件的去重摘要，既有历史保留原样。

2026-10-10 稳定性修复：公共反馈支持可选 `Idempotency-Key`，同一来源 IP、同一内容与键在 24 小时内重试只落库一次；变更内容复用键返回 409。旧客户端未传键时保持兼容。验证码任务明确区分过期、作废与 SMTP 结果待确认；待确认不会自动重发。已结束任务立即清除加密验证码载荷，仅保留 30 天任务状态元数据用于统计，无法补回此前已清理的历史。后台手动重试仅接受尚有效、未被工作进程租用、载荷尚在且等待再次投递的失败任务，不延长验证码有效期。备份健康状态区分无记录、近期成功、超过 2 小时未更新、失败和进行中；历史成功不能代表当前正常。同机发布快照不等于异机备份。


前端传输测试：`cd admin-ui && npm test`。后台邮箱验收仍需隔离 PostgreSQL，不能把线上库用于测试。邮件样式示例与本轮验收材料在 `output/mail-upgrade-20261009/`。

管理员界面采用顶部胶囊导航，保留全部 14 个模块并支持深浅外观与全屏。迁移 `0009_admin_session_ids` 给既有管理会话增加独立公开 UUID；会话令牌摘要继续留在服务端，旧版本程序兼容该新增列。

安装包由账号 API 的 `GET/HEAD /downloads/{filename}` 提供，Caddy 须将官网 `/downloads/*` 转发到账号服务。每次请求检查后台开放状态，支持区间和条件请求；暂停返回 404，响应不缓存。`DOWNLOAD_DIR` 应由 `flowriver` 用户私有读写（生产 `/var/lib/flowriver/downloads`），无需给 Caddy 文件读取权限。安装包上传/下载使用单请求 10 分钟期限，其他 API 保持原超时。

需要 Go 1.27+、Node.js 22.12+ 与 Docker Compose。开发环境数据库只绑定 `127.0.0.1`：

```sh
docker compose up -d postgres
cp .env.example .env
```

生成并填入四个不同的 32 字节密钥；本地开发时管理员接口关闭：

```sh
openssl rand -base64 32
```

`.env` 只供本机开发并设置为当前用户可读写（`chmod 600 .env`）；生产 secrets 通过 `/etc/flowriver/server.env` 配置，由 systemd 读取。

开发模式 `EMAIL_MODE=console` 会把验证码写入本地标准错误日志，不能用于共享机器或生产。生产环境支持 `ACCOUNT_AUTH_MODE=email_only`（邮箱认证（验证码及已实现密码接口），要求 `APPLE_ENABLED=false`）和 `email_and_apple`（需要 Apple Developer 凭据）。`email_only` 时 Apple 登录、绑定和通知接口返回 provider unavailable。`SECURITY_JOURNAL_MODE=login_only` 可在没有异机接收端时运行注册/登录；账号删除和身份撤销仍 fail-closed，不会创建本地日志替代异机日志。

同机自建的出站 Postfix 可通过 `SMTP_ADDR=127.0.0.1:25`、`SMTP_TLS_MODE=loopback` 接入；该模式仅接受 loopback IP 且禁止 SMTP 用户名/密码，只用于 API 到本机 MTA 的连接。Postfix 对外投递仍需启用 TLS，并配置 SPF/DKIM/DMARC 与匹配的 A/PTR 记录；loopback SMTP 不代表邮件已验证送达。

若要在本机打开管理台，另外生成并填写不同的 `ADMIN_TOTP_ENCRYPTION_KEY` 和 `ADMIN_AUDIT_HMAC_KEY`，设置 `ADMIN_ENABLED=true`、`ADMIN_ORIGIN=http://127.0.0.1:5173`、`ADMIN_ALLOWED_IPS=127.0.0.1,::1`。启动 API 后，在另一终端运行 `cd admin-ui && npm ci && npm run dev`。管理员使用 `go run ./cmd/api admin bootstrap NAME` 一次性初始化；TOTP 设置 URI 只显示一次。

```sh
set -a
. ./.env
set +a
go run ./cmd/api
```

API 默认监听 `127.0.0.1:8080`。服务自动运行校验过 SHA-256 的 SQL 迁移。生产环境通过 Caddy 提供 HTTPS；数据库和 API 端口不对公网开放。不要把 `.env`、Apple `.p8`、密钥或邮件密码提交到仓库。

本地测试和 Linux 构建：

```sh
go test -race ./...
TEST_DATABASE_URL='postgres://flowriver:local-only-change-this@127.0.0.1:5432/flowriver_test?sslmode=disable' go test ./...
make build-linux GOARCH=amd64  # 若服务器是 ARM，设 GOARCH=arm64
```

集成测试会在数据库中创建并删除 `test_*` schema；测试只接受 loopback 主机和数据库名含 `test` 的 `TEST_DATABASE_URL`，不要把线上账号库用作测试库。测试库必须使用 UTF8 编码；SQL_ASCII 会让中文 `User-Agent` 的字符长度检查误报。

## 首期接口

接口定义见 [`api/openapi.yaml`](api/openapi.yaml)。每次邮箱验证码确认和 Apple 登录完成都需要 `Idempotency-Key`。设备标识由客户端为每个资料 profile 创建 UUID，与 River Node 的 `RiverDeviceID` 分开。

用户可在已登录并完成二次验证后绑定另一种登录身份。服务端绝不会按 Apple 邮箱自动合并账号。更换或移除身份会生成异机安全事件；最后一种登录方式不能直接移除。Apple 账号授权撤回、用户删除和服务端身份移除分别处理，不复用成同一种事件。

刷新请求须提交当前 `refresh_token`、同一 profile 的 `client_instance_id` 和 `revoke_token`。客户端先持久化幂等请求 ID；刷新成功后，以一个 Keychain 状态快照原子写入返回的 access、refresh 和 revoke token。登出可用 access token 在线撤销；access 过期或客户端离线时使用仅有撤销权限的 revoke token。

邮箱验证码是 8 位随机数，存储 HMAC 摘要；发信 outbox 使用 AES-GCM 加密。事务邮件首期使用 SMTP STARTTLS 或 implicit TLS。不要启用供应商内容调试或 SMTP 原文日志。

`SECURITY_JOURNAL_ENDPOINT` 是独立于本机数据库和备份的异机 HTTPS 服务，路径为 `/v1/events`。本服务使用 `Authorization: Bearer` 与 HMAC-SHA256 (`X-FlowRiver-Timestamp`, `X-FlowRiver-Signature: v1=<hex of HMAC(timestamp + LF + exact body)>`) 推送只含随机用户/身份 ID、事件类型和时间的签名事件；异机服务须幂等保存并回 `200/201/409` 与 `{"event_id":"...","stored":true}`。服务端删除账号数据前等待该回执。未接入异机日志服务时，生产配置校验会失败或删除操作返回暂不可用，不得将同机文件当作异机备份。

## 端到端加密云空间

`0012_user_memory_mirrors` 增加可选的 `user_memory_mirrors` 表。用户先在浏览器用云端口令派生密钥（PBKDF2-SHA-256，600,000 次），再用 AES-GCM-256 加密整份只读记忆副本；服务端只接收密文、盐、IV、KDF 参数、格式版本、大小、白名单摘要和修订号。口令不上传、不落库，服务端没有解密能力，也没有口令重置。

接口：

- `GET /v1/me/memory-mirror/meta`：只返回是否存在、修订号、大小、时间和公开加密参数，不下载密文。
- `GET /v1/me/memory-mirror`：返回该用户自己的密文与参数。
- `PUT /v1/me/memory-mirror`：创建用 `If-None-Match: *`；替换用 `If-Match: "<当前修订号>"`。请求体上限 24 MB，密文上限 16 MB（Web 客户端 8 MB），摘要只接受 `entries/days/places/collections/understandings/first/last` 白名单字段。
- `DELETE /v1/me/memory-mirror`：必须带 `If-Match`；删云副本不删除本机或原生 App。

所有接口按登录用户隔离；下载、上传、删除写入 `audit_events`（只记事件类型，不记密文）。用户级限流为上传 20/小时、下载 120/小时、删除 30/小时、meta 240/小时；429 附带 `Retry-After`。账号删除由 `ON DELETE CASCADE` 级联清理云副本。没有默认开启、自动上传或自动合并：多端是手动快照，版本变化用前置条件阻止静默覆盖。

## 当前交付边界

- 已实现：邮箱验证码登录/注册、Apple 原生令牌验签和授权码兑换、两种身份的内部归属、会话与刷新轮换、服务设备列表和撤销、邮箱二次验证、用户删除队列、Apple 授权通知、事务邮件发送任务。
- 已实现显式邮箱/Apple 身份绑定与身份撤销队列；撤销、账号删除和 Apple 授权撤回必须被异机安全日志确认后才变更/删除账号数据。
- `deploy/backup.sh` 使用 `pg_dump`、age 公钥加密和 rclone 验证上传；安装前仍需配置异机 remote 生命周期、age 公钥和受限 rclone 凭据，并按月完成独立恢复演练。

官方 AI 试用额度的服务端代理与配额表已实现，配置和边界见 [OFFICIAL_AI.md](OFFICIAL_AI.md)。生产未配置 Provider Key 时该端点保持关闭；客户端尚未接入，当前仍以 BYOK 为主。
- 首期异机数据库备份保留 7 天、安全变更日志保留 30 天；存储生命周期需在供应商侧配置，脚本不自动清理远端。`flowriver-backup.timer` 每小时运行。恢复仍要求停掉 API、从异机安全日志重放删除/身份撤销事件，再启动服务；日志读取/重放工具和恢复演练尚未完成。延长备份窗口时，必须同时延长安全日志覆盖范围。
- Apple 账号删除只撤销 FlowRiver 的 Apple 身份；有独立邮箱身份时仍允许用户进入账号。邮箱与 Apple 不自动按邮箱合并。第三方 key、SMTP relay、Apple App ID、异机安全日志、真实 DNS 及服务器 SSH 尚需部署配置。
- 账号 API 默认不上传资料库；用户显式开启的云空间只保存端到端加密密文，不能撤销旧 iCloud 同步密钥或擦除离线设备；账号登录门槛需客户端另行集成 `ProfileContext` 后才生效。
- 实际负载、真机网络、邮件送达和恢复目标需要部署环境验收；本地编译与自动化用例不代表线上能力已验证。

## 用户密码登录

已验证邮箱账号可设置密码，并保留邮箱验证码登录。iOS 登录页可切换两种方式，账号设置提供设置或修改密码，忘记密码通过独立邮箱验证码恢复。新账号仍通过验证码注册并确认条款。接口见 `api/openapi.yaml` 的 `/auth/password/*` 和 `/me/password`。

迁移 `0004_user_passwords` 在服务启动时应用，部署前需备份数据库与程序。密码为 NFC 规范化后的 15–128 个字符，支持空格长短语；仅保存 Argon2id 摘要。重置会撤销既有会话，并使旧密码及旧改密证明失效。
