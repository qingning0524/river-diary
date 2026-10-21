# FlowRiver 账号服务器落地教程

适用配置：Ubuntu 24.04 64 位、2 核 2 GB、约 30 GB 磁盘、美国机房，域名 `flowriver.xyz`。按本教程部署后，账号 API 的入口是 **`https://api.flowriver.xyz`**。

本教程对应当前仓库的 `server/` 实现，核对日期为 2026-10-01。服务负责注册、登录、身份、设备、会话和管理员管理台；日记内容继续保存在客户端。部署后还需要给 iOS/macOS 接入登录页面和资料隔离，才能实现“第一次使用必须注册登录”。

## 先看清楚当前能做到哪一步

| 项目 | 你需要准备什么 |
|---|---|
| 服务器 | 公网 IP、SSH 用户、SSH 端口、可使用 sudo 的账号 |
| 域名 | 能修改 `flowriver.xyz` 的 DNS 记录 |
| 管理入口 | 你的固定公网 IP 或可信 CIDR，用于限制管理员后台来源 |
| 邮箱验证码 | 支持加密 SMTP 的邮件服务、发信域验证、SMTP 账号密码 |
| Apple 登录（可选） | 若选择 `email_and_apple`，需要 Apple Developer App ID、Team ID、Key ID 和 `.p8`；`email_only` 不需要 |
| 安全变更日志 | 独立于这台 VPS 的 HTTPS 接收服务，记录账号删除和身份撤销事件 |
| 异机备份 | 独立存储、rclone 凭据、age 加密公钥，解密私钥保存在服务器以外 |

**当前仓库包含安全日志发送端，没有提供可直接部署的异机接收端，也没有完成恢复时的事件重放工具。** 因此公网账号 API 暂不能开放。你可以先部署“仅管理后台”模式：它只迁移数据库并监听 `127.0.0.1:8081`，账号 API 域名明确返回 `503`；它不会启用注册、邮件任务、Apple 授权或安全日志队列。外部依赖齐全后再切换到完整 API。

生产程序要求 SMTP 已配置。当前部署使用 `ACCOUNT_AUTH_MODE=email_only` 和 `APPLE_ENABLED=false`，仅开放邮箱验证码登录；Apple 登录、绑定和通知请求返回 provider unavailable。异机安全日志默认必需；`SECURITY_JOURNAL_MODE=login_only` 保持删除/解绑 fail-closed。不要为了绕过检查把公网服务改成开发模式：开发默认会把邮箱验证码写进日志。

### 阅读约定

- **Mac 操作**：在你的 Mac 终端执行。构建两个 Linux 安装包需要 Go 1.27+、Node.js 22.12+ 与 npm。
- **服务器操作**：通过 SSH 登录 Ubuntu 后执行。
- `REPLACE_…` 是需要替换的内容，不能原样使用。
- 本教程按一台新服务器编写。如果已有数据库或网站，先检查现有配置，再安装和替换对应文件。
- 每一步都确认结果后再继续；某条命令报错时先处理该错误。

## 第 1 步：连接服务器，确认系统与架构

**Mac 操作。** 把用户和 IP 换成云厂商提供的值。默认 SSH 端口是 22；自定义端口填写实际值。后面的上传步骤继续使用同一个 Mac 终端。

```sh
export FLOWRIVER_SSH='ubuntu@REPLACE_SERVER_IP'
export FLOWRIVER_SSH_PORT=22
ssh -p "$FLOWRIVER_SSH_PORT" "$FLOWRIVER_SSH"
```

第一次连接，核对服务器控制台提供的 SSH 指纹。需要指定密钥时，在 SSH 命令中加 `-i /你的私钥路径`，上传时也指定相同密钥。

**服务器操作：**

```sh
cat /etc/os-release
uname -m
free -h
df -h /
```

你应该看到 Ubuntu 24.04、约 2 GB 内存和实际磁盘容量。记下架构：

| `uname -m` 的结果 | 第 5 步构建使用的值 |
|---|---|
| `x86_64` | `amd64` |
| `aarch64` / `arm64` | `arm64` |

“64 位”不能判断是哪一种架构。磁盘至少预留 5 GB 空闲，之后只保留程序和短期日志，数据库备份上传异机存储。

## 第 2 步：安装服务器基础软件

**服务器操作：**

```sh
sudo apt update
sudo apt upgrade -y
sudo apt install -y postgresql-16 postgresql-client-16 curl ca-certificates \
  gnupg openssl python3 dnsutils ufw age rclone unattended-upgrades
sudo systemctl enable --now postgresql
sudo -u postgres psql -c 'SELECT version();'
```

最后应显示 PostgreSQL 16 的版本。Ubuntu 的更新采用发行版维护机制，第三方软件源的更新覆盖需要单独检查。[Ubuntu 安全更新说明](https://documentation.ubuntu.com/security/security-updates/)

服务器不需要安装 Go、Node、Redis 或 Docker。这里使用系统 PostgreSQL、一个 Go 程序和 Caddy，减少 2 GB 内存的常驻开销。

检查更新设置和是否需要重启：

```sh
sudo dpkg-reconfigure -plow unattended-upgrades
test ! -f /var/run/reboot-required || cat /var/run/reboot-required
```

如果提示需要重启，在云控制台确认可以重新登录后执行 `sudo reboot`，随后重新 SSH 登录。

## 第 3 步：配置 API 域名

**在域名 DNS 控制台操作。** 新建记录：

| 类型 | 主机记录 | 内容 | TTL |
|---|---|---|---|
| A | `api` | 服务器公网 IPv4 | 默认或 300 秒 |

最终建立两条 A 记录：`api.flowriver.xyz` 和 `admin.flowriver.xyz` 都指向服务器公网 IPv4。根域名 `flowriver.xyz` 可以以后放官网。首轮部署使用直接 DNS 解析；如果服务商有代理开关，先使用“仅 DNS”。只有服务器 IPv6 已验证可达时才添加 AAAA 记录。

**服务器操作：**

```sh
dig +short A api.flowriver.xyz
dig +short A admin.flowriver.xyz
dig +short AAAA api.flowriver.xyz
```

A 应返回你的服务器 IP。如果没有配置 IPv6，AAAA 应为空；已有错误 AAAA 记录应在 DNS 控制台修正。解析和公网端口正确后，Caddy 可以申请并续签 HTTPS 证书。[Caddy HTTPS 条件](https://caddyserver.com/docs/automatic-https)

## 第 4 步：配置防火墙，安装 HTTPS 网关

### 4.1 先放行 SSH，再启用防火墙

**服务器操作。** 下面按 SSH 使用 **22 端口** 编写；如果第 1 步使用了其他端口，把第一条命令中的 22 换成实际端口。

```sh
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw enable
sudo ufw status verbose
```

云厂商控制台的安全组也放行相同端口。SSH 可限制为你自己的公网 IP。保持当前 SSH 窗口打开，从 Mac 新开一个终端验证仍能登录，再关闭旧窗口。

8080（API）、5432（数据库）和 2019（Caddy 管理）不添加公网放行规则。SMTP、Apple 和异机日志需要服务器可以向外连接。

### 4.2 安装 Caddy

**服务器操作。** 使用 Ubuntu 已签名的软件包。该包会配置 Caddy systemd 服务。[Ubuntu 包信息](https://packages.ubuntu.com/noble/caddy)

```sh
sudo apt update
sudo apt install -y caddy
if ! sudo systemctl is-active --quiet caddy; then sudo systemctl disable --now caddy 2>/dev/null || true; fi
caddy version
```

新服务器先停掉默认站点，配置完成后再启动。如果 Caddy 已在托管其他站点，请保留现有进程，在第 9 步合并两条 FlowRiver 站点配置。始终只运行一个占用 80/443 端口的网关。

## 第 5 步：在 Mac 构建并上传后端

### 5.1 安装构建工具

**Mac 操作。** 从 Go 官方网站安装适合你的 Mac 的 Go **1.27 或以上**，然后重新打开终端确认版本。[Go 安装教程](https://go.dev/doc/install)

```sh
go version
```

### 5.2 构建并打包两个 Linux 架构

**Mac 操作。** 回到第 1 步设置过上传变量的终端，在项目根目录构建 amd64 和 arm64 两个安装包。安装包内含 API、管理员前端、服务配置、API 定义和校验摘要。

```sh
cd '/Users/fa1lingdown/Desktop/河流日记项目'
make -C server release-linux
file server/dist/flowriver-api-linux-amd64
file server/dist/flowriver-api-linux-arm64
scp -P "$FLOWRIVER_SSH_PORT" server/dist/flowriver-release-linux-amd64.tar.gz \
  server/dist/flowriver-release-linux-arm64.tar.gz "$FLOWRIVER_SSH:"
```

`file` 应显示 Linux ELF 和对应架构。这是给服务器运行的程序，不能在 Mac 直接运行。包中不包含 `.env`、数据库、邮件密码或 Apple 私钥。

### 5.3 解包并校验

**服务器操作：**

```sh
case "$(uname -m)" in
  x86_64) archive="$HOME/flowriver-release-linux-amd64.tar.gz" ;;
  aarch64|arm64) archive="$HOME/flowriver-release-linux-arm64.tar.gz" ;;
  *) echo '当前 CPU 架构未打包' >&2; exit 1 ;;
esac
mkdir -p "$HOME/flowriver-upload"
tar -xzf "$archive" -C "$HOME/flowriver-upload"
cd "$HOME/flowriver-upload"
sha256sum -c SHA256SUMS
```

应显示 `flowriver-api: OK`。如果校验失败，重新上传，不安装该文件。

## 第 6 步：创建运行账号与数据库

### 6.1 安装程序和服务定义

**服务器操作。** Linux 用户 `flowriver` 只用于运行程序；不开放它的 SSH 登录。

```sh
sudo adduser --system --group --no-create-home flowriver
sudo install -d -o root -g root -m 0755 /opt/flowriver/bin
sudo install -d -o root -g flowriver -m 0750 /etc/flowriver
sudo install -o root -g root -m 0755 "$HOME/flowriver-upload/flowriver-api" \
  /opt/flowriver/bin/flowriver-api
sudo install -o root -g root -m 0755 "$HOME/flowriver-upload/deploy/backup.sh" \
  /opt/flowriver/bin/backup.sh
sudo install -m 0644 "$HOME/flowriver-upload/deploy/flowriver-api.service" \
  /etc/systemd/system/flowriver-api.service
sudo install -m 0644 "$HOME/flowriver-upload/deploy/flowriver-admin-only.service" \
  /etc/systemd/system/flowriver-admin-only.service
sudo install -m 0644 "$HOME/flowriver-upload/deploy/flowriver-backup.service" \
  /etc/systemd/system/flowriver-backup.service
sudo install -m 0644 "$HOME/flowriver-upload/deploy/flowriver-backup.timer" \
  /etc/systemd/system/flowriver-backup.timer
sudo systemctl daemon-reload
```

现在先不启动 API。

### 6.2 创建专用数据库

为数据库选择一个独立长密码，保存在密码管理器中。使用随机十六进制密码可以避免 URL 中的特殊字符转义问题。

**服务器操作：**

```sh
sudo -u postgres psql
```

进入 `postgres=#` 提示符后，逐条执行以下 SQL 和 psql 指令：

```sql
CREATE ROLE flowriver LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
\password flowriver
CREATE DATABASE flowriver OWNER flowriver;
\connect flowriver
GRANT USAGE, CREATE ON SCHEMA public TO flowriver;
\quit
```

`\password` 会让你输入两次密码，输入不会回显。这里的数据库用户与 Linux 用户同名，但密码用途不同。应用启动时会自动建表，所以它需要自己数据库内的建表权限，不需要超级用户权限。

### 6.3 设置适合 2 GB 内存的初始参数

**服务器操作。** 这些是初始预算，后续依据真实负载调整，不代表数据库内存的硬上限。[PostgreSQL 参数说明](https://www.postgresql.org/docs/16/runtime-config-resource.html)

```sh
sudo -u postgres psql <<'SQL'
ALTER SYSTEM SET listen_addresses = '127.0.0.1';
ALTER SYSTEM SET max_connections = '20';
ALTER SYSTEM SET shared_buffers = '128MB';
ALTER SYSTEM SET work_mem = '4MB';
ALTER SYSTEM SET maintenance_work_mem = '64MB';
SQL
sudo systemctl restart postgresql
psql -h 127.0.0.1 -U flowriver -d flowriver -W -c 'SELECT current_user, current_database();'
```

最后输入刚设置的密码，应返回用户 `flowriver` 和数据库 `flowriver`。不要把生产账号库叫 `flowriver_test`，也不要在生产数据库执行仓库的集成测试。

## 第 7 步：生成生产配置，接入外部服务

### 7.1 一次性生成密钥

**服务器操作。** 下面只在首次部署执行：创建权限为 600 的配置文件，分别生成七个不同的 32 字节密钥；已有文件时退出，不覆盖密钥。

```sh
sudo python3 - "$HOME/flowriver-upload/env.example" <<'PY'
import base64
import os
from pathlib import Path
import secrets
import sys

target = Path('/etc/flowriver/server.env')
if target.exists():
    raise SystemExit('server.env already exists; edit it without regenerating keys')
values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if line and not line.startswith('#') and '=' in line:
        name, value = line.split('=', 1)
        values[name] = value
values.update({
    'APP_ENV': 'production',
    'DATABASE_URL': 'postgres://flowriver:REPLACE_DB_PASSWORD@127.0.0.1:5432/flowriver?sslmode=disable',
    'EMAIL_MODE': 'smtp',
    'ACCOUNT_AUTH_MODE': 'email_only',
    'SMTP_ADDR': '',
    'APPLE_ENABLED': 'false',
    'APPLE_PRIVATE_KEY_FILE': '/etc/flowriver/apple-signin.p8',
    'ADMIN_ENABLED': 'true',
    'ADMIN_ORIGIN': 'https://admin.flowriver.xyz',
    'ADMIN_ALLOWED_IPS': 'REPLACE_WITH_YOUR_PUBLIC_IP_OR_CIDR',
})
for name in ('AUTH_HMAC_KEY', 'OUTBOX_ENCRYPTION_KEY',
             'IDEMPOTENCY_ENCRYPTION_KEY', 'APPLE_TOKEN_ENCRYPTION_KEY',
             'SECURITY_JOURNAL_SIGNING_KEY', 'ADMIN_TOTP_ENCRYPTION_KEY',
             'ADMIN_AUDIT_HMAC_KEY'):
    values[name] = base64.b64encode(secrets.token_bytes(32)).decode('ascii')
os.umask(0o077)
with target.open('x') as output:
    output.write(''.join(f'{name}={value}\n' for name, value in values.items()))
print('Created /etc/flowriver/server.env; complete external service settings before starting')
PY
sudo nano /etc/flowriver/server.env
```

`nano` 编辑完成用 Control+O、回车保存，Control+X 退出。将数据库密码填入 `DATABASE_URL`。如果密码包含 `@`、`:`、`/`、`#` 等字符，需要对 URL 的密码部分编码；不要直接拼接。

将 `ADMIN_ALLOWED_IPS` 替换为你使用管理员后台时的公网 IPv4/IPv6 地址；需要网段时填写 CIDR，多项用逗号分隔。生产模式下，后台强制校验这个列表。使用跳板机或 VPN 时，应填管理请求实际从哪里到达该 VPS，并同时配置云防火墙。

**不要重新生成这些密钥来“更新配置”**，否则旧会话、待发邮件和已保存的 Apple 凭据可能失效。将配置和 `.p8` 另外保存在受保护的异机密钥备份中；数据库加密备份不包含这些文件。

这是 systemd 配置文件：每行 `名称=值`，不写 `export`，不要把它当 shell 脚本加载。包含空格或引号的密码按 systemd EnvironmentFile 规则加引号并转义；文件不要发进聊天或提交 Git。

### 7.2 邮箱验证码服务

此 VPS 的出站 TCP/25 已实测可达 Google MX。你希望在同一台服务器自建 SMTP；本教程会使用仅绑定 `127.0.0.1:25` 的 Postfix 作为本机出站 MTA，OpenDKIM 为验证码邮件签名，不开放 SMTP 中继给公网。直投能否进收件箱还取决于发件 IP 声誉和 DNS 身份验证。

发信域使用 `mail.flowriver.xyz`。添加 `A mail -> 198.23.189.187`，并将发件 IP 的 PTR/rDNS 设为 `mail.flowriver.xyz`。当前 PTR 仍为服务商默认主机名；Gmail 要求发送 IP 有有效 PTR，且 PTR 主机名的 A 记录回指同一 IP。[Gmail 发件人指南](https://support.google.com/mail/answer/81126?hl=zh-Hans)

为 `mail.flowriver.xyz` 添加 SPF 和 DMARC，DKIM 公钥记录将在服务器生成后给出：

```text
TXT mail: v=spf1 ip4:198.23.189.187 -all
TXT _dmarc.mail: v=DMARC1; p=none; adkim=r; aspf=r
```

添加 SPF 前再次检查该发信子域是否已有 SPF；同一域名不能并存多个 SPF TXT 记录。邮件直投也需要 SPF、DKIM、TLS 和前向/反向 DNS；未配置完前不启用发信。[Gmail 发件人指南](https://support.google.com/mail/answer/81126?hl=zh-Hans)

在 `server.env` 中填写真实配置：

```ini
EMAIL_MODE=smtp
SMTP_ADDR=127.0.0.1:25
SMTP_TLS_MODE=loopback
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_FROM=account@mail.flowriver.xyz
```

`loopback` 明文仅用于 API 与同机 Postfix 之间的 loopback 连接；Postfix 对外投递使用 TLS。它要求地址是 loopback IP 且不设置 SMTP 用户名/密码。首次发信要检查真实收件头中的 SPF/DKIM 结果及垃圾邮件分类；API 返回 202 只说明请求已处理，不证明邮件送达。

### 7.3 Apple 登录（当前移除）

当前部署选择邮箱-only，无需配置本节。Apple 登录、身份绑定和通知端点在此模式下返回 unavailable。未来取得 Developer Program 密钥后，才可改成 `email_and_apple`。

用有 Account Holder 或 Admin 权限的 Apple Developer 账号登录 [developer.apple.com/account](https://developer.apple.com/account/)，打开 **Certificates, Identifiers & Profiles**：

1. 在 **Identifiers** 找到或注册正式 iOS/macOS App ID，为主 App ID 启用 **Sign in with Apple**；相关平台的 App ID 通过 grouping 与主 ID 关联。[Apple 分组说明](https://developer.apple.com/help/account/capabilities/group-apps-for-sign-in-with-apple/)
2. 在 **Keys** 点 `+`，启用 **Sign in with Apple** 并关联主 App ID，生成并下载 `.p8` 文件。Apple 不会再次提供同一把私钥下载，立即安全保存。[创建私钥](https://developer.apple.com/help/account/capabilities/create-a-sign-in-with-apple-private-key/)
3. **Team ID** 在 Membership Details；**Key ID** 在刚创建的 Keys 详情；**APPLE_CLIENT_IDS** 填 iOS 与 macOS App 的 Bundle ID，不填 Team ID 或域名。
4. 在 Xcode 两个正式 App target 上添加 Sign in with Apple Capability。

仓库当前声明 iOS Bundle ID `local.riverdiary.app`、macOS Bundle ID `studio.riverdiary.mac`。请在 Apple Developer 的 Identifiers 和 Xcode target 中核对它们是否是准备发布的正式 ID；不要使用 QA target 的 Bundle ID。Apple 原生 App 登录使用 App ID，不需要为此 API 另建网页登录用的 Services ID。
4. 配置服务端通知地址：`https://api.flowriver.xyz/v1/provider/apple/notifications`。HTTPS 启用后再验证通知到达。

**Mac 操作。** 把文件名换成你实际下载的 `.p8`：

```sh
scp -P "$FLOWRIVER_SSH_PORT" /你的私钥路径/AuthKey_REPLACE_KEY_ID.p8 \
  "$FLOWRIVER_SSH:apple-signin-upload.p8"
```

**服务器操作：**

```sh
chmod 600 "$HOME/apple-signin-upload.p8"
sudo install -o root -g flowriver -m 0440 "$HOME/apple-signin-upload.p8" \
  /etc/flowriver/apple-signin.p8
rm "$HOME/apple-signin-upload.p8"
sudo -u flowriver test -r /etc/flowriver/apple-signin.p8
sudo nano /etc/flowriver/server.env
```

填入：

```ini
APPLE_ENABLED=true
APPLE_TEAM_ID=REPLACE_TEAM_ID
APPLE_KEY_ID=REPLACE_KEY_ID
APPLE_PRIVATE_KEY_FILE=/etc/flowriver/apple-signin.p8
APPLE_CLIENT_IDS=REPLACE_IOS_BUNDLE_ID,REPLACE_MACOS_BUNDLE_ID
```

这里使用 Apple 登录令牌实际的 `aud`（原生 App 通常是 Bundle ID），不填写域名、Team ID 或 QA 包的 ID。两端正式 ID 都要与 Apple 后台一致。当前服务按原生 App 的授权码流程实现，网页登录需要另行接入。

### 7.4 独立安全日志——当前必须补齐的依赖

该服务需要部署在**另一台机器或独立云服务**，与账号数据库备份分别保存。任意 HTTPS URL、同机文件或只返回成功的空服务，都不能满足要求。

接收端的接口约定见 [后端 README](../../server/README.md#首期接口)。它必须验证 Bearer 凭据、时间戳和签名，按 `event_id` 幂等持久化，存储成功后才回执。发送地址填写服务的基础 URL，发送端会自动追加 `/v1/events`：

```ini
SECURITY_JOURNAL_ENDPOINT=https://REPLACE_OFFSITE_JOURNAL_HOST
SECURITY_JOURNAL_TOKEN=REPLACE_JOURNAL_BEARER_TOKEN
```

`SECURITY_JOURNAL_SIGNING_KEY` 已在 7.1 生成，将相同签名密钥安全配置到接收端；Bearer token 也需两端匹配。日志保留 30 天，账号库备份初始保留 7 天，保证事件日志覆盖可恢复的备份窗口。

**接收端未实现和验收时，不能启动完整账号 API。** 当前程序会检查配置形式，但不会在 readiness 中检查异机服务是否真的存储成功。正确填完 URL 并不等于该依赖已上线。

### 7.5 外部依赖未齐时，只启动管理后台

此模式适合先完成管理后台初始化和服务器巡检。它仍要求 `APP_ENV=production`、本机 PostgreSQL、管理密钥、HTTPS Origin 和非空来源 IP 白名单。账号 API 的完整生产配置校验没有放宽。

```sh
sudo install -m 0644 "$HOME/flowriver-upload/deploy/Caddyfile.admin-only" /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl daemon-reload
sudo systemctl enable --now flowriver-admin-only caddy
sudo systemctl status flowriver-admin-only --no-pager
curl --fail --silent --show-error http://127.0.0.1:8081/admin-api/v1/auth/session
```

此时 `admin.flowriver.xyz` 提供管理界面，`api.flowriver.xyz` 预期返回 `503`。不要同时启动 `flowriver-api`，两种模式共用管理端口；备份任务也需等异机存储凭据配好后再启用。

## 第 8 步：启动 API，验证本机服务

前提：第 7 步的真实外部服务已配置，安全日志接收端已经验收；条款和隐私政策已发布，`TERMS_VERSION`、`PRIVACY_VERSION` 与客户端展示版本对应。

**服务器操作：**

```sh
sudo chmod 600 /etc/flowriver/server.env
sudo systemctl disable --now flowriver-admin-only
sudo systemctl enable --now flowriver-api

# 安装前检查：deploy/Caddyfile 只有 api/admin 两个站点。
# 如果 /etc/caddy/Caddyfile 已包含官网/登录/控制台，脚本会拒绝覆盖并提示合并，
# 避免把多站点主机的官网/登录/控制台打成 404。完整六站点用 website/deploy/Caddyfile。
sudo "$HOME/flowriver-upload/deploy/install-caddyfile.sh" "$HOME/flowriver-upload/deploy/Caddyfile"
sudo systemctl status flowriver-api --no-pager
curl --fail --silent --show-error http://127.0.0.1:8080/health/live
curl --fail --silent --show-error http://127.0.0.1:8080/health/ready
```

预期分别返回 `{"status":"ok"}`、`{"status":"ready"}`。启动时程序自动执行数据库迁移，SQL 已嵌入二进制，不需要另拷 SQL 文件。

失败时查看最近日志：

```sh
sudo journalctl -u flowriver-api -n 80 --no-pager
```

服务定义已设置开机启动、异常重启、256 MiB Go 内存软目标和 384 MiB 进程上限。达到进程上限可能被系统终止，需要根据实际峰值调整；不能据此推算可支持多少用户。

### 8.1 创建首个管理员

管理员账号不能在注册页面申请；通过 SSH 终端一次性创建。该命令不会回显密码。成功后只在交互终端显示一次 TOTP 设置 URI，用手机验证器添加账户，并把种子保存在服务器外的密码管理器中；不要把 URI 粘贴进工单、shell 命令或聊天记录。

```sh
sudo systemd-run --unit=flowriver-admin-bootstrap --pty --wait --collect \
  -p StandardOutput=tty -p StandardError=tty \
  -p User=flowriver \
  -p WorkingDirectory=/opt/flowriver \
  -p EnvironmentFile=/etc/flowriver/server.env \
  /opt/flowriver/bin/flowriver-api admin bootstrap riverflow-admin
```

`riverflow-admin` 可换成自选的管理员名。密码至少 12 个字符。下次启动后，打开 `https://admin.flowriver.xyz` 并使用密码和六位动态验证码登录。

若忘记动态验证器，先停 API，再用下面的 SSH 恢复命令签发新种子；它会撤销所有旧管理会话：

```sh
sudo systemctl stop flowriver-api
sudo systemd-run --unit=flowriver-admin-recovery --pty --wait --collect \
  -p StandardOutput=tty -p StandardError=tty \
  -p User=flowriver -p WorkingDirectory=/opt/flowriver \
  -p EnvironmentFile=/etc/flowriver/server.env \
  /opt/flowriver/bin/flowriver-api admin reset-totp riverflow-admin
sudo systemctl start flowriver-api
```

忘记密码时，使用同一 SSH 终端流程运行 `admin reset-password riverflow-admin`。管理员来源 IP 限制由 `ADMIN_ALLOWED_IPS` 控制；换网络前先更新服务器 allowlist 并重新启动 API。

## 第 9 步：启用 HTTPS

切换到完整 API 时按第 8 步安装正式 Caddyfile。已有其他网站时，把对应站点块合并进去，不覆盖其他站点。仅后台阶段使用 `deploy/Caddyfile.admin-only`，其中 API 域名固定返回 `503`。

```sh
# 同上：server/deploy/Caddyfile 只含 api/admin；已有官网/登录/控制台时
# 脚本会拒绝覆盖，必须合并站点块，或改用 website/deploy/Caddyfile。
sudo "$HOME/flowriver-upload/deploy/install-caddyfile.sh" "$HOME/flowriver-upload/deploy/Caddyfile"
sudo systemctl status caddy --no-pager
```

**Mac 操作：**

```sh
curl --fail --silent --show-error https://api.flowriver.xyz/health/live
curl --fail --silent --show-error https://api.flowriver.xyz/health/ready
curl --fail --silent --show-error --output /dev/null --write-out '%{http_code}\n' https://admin.flowriver.xyz/
```

API 健康检查应返回成功；管理台页面应返回 `200`。不要加 `-k` 跳过证书验证。证书失败先查两条域名的 DNS、80/443 安全组和 Caddy 日志，不反复重装网关。

**服务器操作，检查监听地址：**

```sh
sudo ss -lntp
```

8080、5432 和管理端口不能监听 `0.0.0.0` 或公网地址。API 必须是 `127.0.0.1:8080`，数据库本教程设置为 `127.0.0.1:5432`；80/443 可以公网监听。

## 第 10 步：配置并验证异机加密备份

### 10.1 在 Mac 生成解密私钥

**Mac 操作。** 安装 age，然后在项目外生成密钥。命令遇到已有密钥文件时先停下，不替换现有恢复密钥。[age 官方用法](https://github.com/FiloSottile/age)

```sh
brew install age
mkdir -p "$HOME/.flowriver-recovery"
chmod 700 "$HOME/.flowriver-recovery"
umask 077
age-keygen -o "$HOME/.flowriver-recovery/backup-age-key.txt"
age-keygen -y "$HOME/.flowriver-recovery/backup-age-key.txt"
```

最后显示 `age1…` 公钥。只把公钥填到服务器，解密私钥留在受保护的异机恢复资料中，并保存第二份可找回的副本。

### 10.2 配置独立存储

**服务器操作。** 在 rclone 的交互配置中接入你选定的对象存储或异机存储，remote 命名为 `flowriver-offsite`。配置所需的存储凭据，不使用云账号管理员凭据。

```sh
sudo rclone config --config /etc/flowriver/rclone.conf
sudo chown flowriver:flowriver /etc/flowriver/rclone.conf
sudo chmod 600 /etc/flowriver/rclone.conf
sudo install -o root -g root -m 0600 "$HOME/flowriver-upload/deploy/backup.env.example" \
  /etc/flowriver/backup.env
sudo nano /etc/flowriver/backup.env
```

填写以下三项：

```ini
DATABASE_URL=postgres://flowriver:REPLACE_DB_PASSWORD@127.0.0.1:5432/flowriver?sslmode=disable
BACKUP_AGE_RECIPIENT=REPLACE_AGE_PUBLIC_KEY
BACKUP_REMOTE=flowriver-offsite:REPLACE_BUCKET/account-db
```

`DATABASE_URL` 的数据库密码与 API 相同。远端路径按供应商类型填写，例如对象存储包含 bucket；不要复制占位符。凭据需要上传和读取校验对象的权限，远端过期清理交给供应商生命周期设置。

在供应商控制台设置数据库备份保留 **7 天**。脚本不执行远端删除；安全事件日志独立保留 **30 天**。延长数据库备份窗口时必须同时延长安全日志覆盖时间，不能让恢复重新启用已经删除或撤销的账号。

### 10.3 先手动验证，再启用定时任务

**服务器操作：**

```sh
sudo install -d -o flowriver -g flowriver -m 0700 /var/lib/flowriver/tmp
sudo systemctl start flowriver-backup.service
sudo systemctl status flowriver-backup.service --no-pager
sudo journalctl -u flowriver-backup.service -n 60 --no-pager
```

确认任务退出状态为成功、日志出现上传校验完成，并在远端找到新的 `.dump.age` 文件，再执行：

```sh
sudo systemctl enable --now flowriver-backup.timer
sudo systemctl list-timers flowriver-backup.timer --all
```

定时器每小时运行，带少量随机延迟。脚本在本机临时生成数据库备份，age 公钥加密后上传，下载比对密文内容，退出时清理临时文件。[rclone 校验说明](https://rclone.org/commands/rclone_check/)

备份上传成功还需要恢复验收：下载一份备份，用异机私钥解密，在隔离数据库恢复；验证表、账号、会话、安全日志读取及删除/撤销事件重放。**当前仓库尚缺日志读取/重放工具，这项完成前不要宣称恢复能力已经就绪，也不要把旧备份直接覆盖线上数据库后启动 API。** RPO 1 小时、RTO 2 小时只是待演练的目标。

## 第 11 步：用测试账号完成上线验收

按 [账号服务验收清单](../validation/BACKEND_ACCOUNT_ACCEPTANCE.md) 完成以下验证；测试使用你控制的专用邮箱和设备：

- 真实邮箱收到了 8 位验证码，确认后能够注册、登录和查询当前账号。
- Apple 登录已关闭；若将来重新启用，再验收正式 App ID、平台分组和授权撤销通知。
- 邮箱和 Apple 不会仅因邮箱相同自动合并，绑定另一种身份需要二次验证。
- 刷新会话、登出和撤销设备有效；撤销后旧访问凭据不能继续使用。
- 账号删除、身份撤销和 Apple 授权撤回收到真实异机日志回执，日志不可用时操作保持待处理。
- HTTPS 验证成功，8080/5432/2019 未公开，备份及隔离恢复演练成功。
- iOS/macOS 完成首次登录门槛、Keychain 凭据保存、旧资料迁移及 profile 隔离后再开启强制登录。

健康检查只证明 API 存活和数据库可连接；不会验证邮件送达、Apple 配置或安全日志可用。完整接口和请求字段见 [OpenAPI](../../server/api/openapi.yaml)，不要使用健康检查代替业务验收。

## 日常维护：日志、空间和更新

### 观察运行状态

**服务器操作：**

```sh
sudo journalctl -u flowriver-api --since '1 hour ago' --no-pager
sudo journalctl -u caddy --since '1 hour ago' --no-pager
df -h /
free -h
sudo journalctl --disk-usage
sudo systemctl list-timers flowriver-backup.timer --all
```

初始监控：磁盘达到 70% 预警、85% 严重告警，至少保留 5 GB 空闲；同时监控 HTTPS 可达、5xx、数据库连接等待、邮件失败、安全日志失败和备份最近成功时间。备份定时器存在不等于备份成功。不要手动删除 PostgreSQL 的 `pg_wal`。

可以限制系统日志占用。**服务器操作：**

```sh
sudo install -d -m 0755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/flowriver-limits.conf >/dev/null <<'CONF'
[Journal]
SystemMaxUse=512M
RuntimeMaxUse=128M
MaxRetentionSec=7day
CONF
sudo systemctl restart systemd-journald
```

这限制的是系统日志，不会限制数据库、远端备份或所有软件的独立日志文件。

### 更新程序

1. 在 Mac/构建环境通过测试，按第 5 步重新构建上传；保留发布版本与二进制摘要。
2. 在服务器解包校验，并手动运行备份任务，确认成功后再更新。
3. 执行下面的替换流程，随后复查 HTTPS 和真实登录。

**服务器操作：**

```sh
sudo cp /opt/flowriver/bin/flowriver-api /opt/flowriver/bin/flowriver-api.previous
sudo install -m 0755 "$HOME/flowriver-upload/flowriver-api" /opt/flowriver/bin/flowriver-api.next
sudo systemctl stop flowriver-api
sudo mv /opt/flowriver/bin/flowriver-api.next /opt/flowriver/bin/flowriver-api
sudo systemctl start flowriver-api
curl --fail --silent --show-error http://127.0.0.1:8080/health/ready
```

更新保留 `/etc/flowriver/server.env` 和私钥；不重复生成密钥、不覆盖数据库。已应用的 SQL 迁移不能原地修改，变更通过新增迁移发布。

如果需要回退，先确认上一版兼容当前数据库结构，再恢复 `.previous` 程序。回退二进制不自动回退数据库；涉及数据迁移失败时先停服务并诊断，不直接恢复旧库。

## 常见错误

| 现象 | 检查与处理 |
|---|---|
| SSH 超时或连接被拒绝 | 核对 IP、端口、云安全组和 SSH 密钥；防火墙失误从云控制台恢复 |
| `Exec format error` | 程序架构错误或上传了 Mac 程序；按服务器 `uname -m` 重建 Linux 程序 |
| 数据库密码错误 | 用第 6 步的 `psql -h 127.0.0.1 … -W` 测试，核对 URL 密码编码和数据库名 |
| `production requires …` | 对照第 7 步补齐真实 SMTP、Apple 和安全日志配置，保持生产模式 |
| Apple 私钥读取失败 | 路径是否正确，`flowriver` 用户能否读取，目录权限是否允许进入 |
| 公网返回 502 | 先检查本机 `/health/ready` 和 API 日志；网关连接不到后端时会发生 |
| HTTPS 证书申请失败 | 核对 A/AAAA、80/443 两层防火墙、端口占用和 Caddy 日志 |
| 请求验证码后没收到邮件 | 核对 SMTP TLS 模式、密码、发信域验证和邮件供应商送达记录；202 不等于送达 |
| 删除/撤销一直待处理 | 检查异机日志持久化与回执是否匹配，或 Apple 撤销任务状态；不强制删数据库绕过 |
| 备份失败 | 检查 remote 路径、读写权限、age 公钥、`backup.env` 数据库密码和可用磁盘 |

## 完成后你得到什么

完成基础部署和业务验收后，你得到一套通过 HTTPS 访问、随系统启动的账号和设备服务。完整上线还包括独立日志接收/恢复重放、真实外部服务验收和客户端首次登录接入。当前仓库的本地测试及构建结果不代表这些生产步骤已完成。

继续查阅：[后端使用说明](../../server/README.md)、[API 定义](../../server/api/openapi.yaml)、[完整后端规划](../../主规划.md)、[首发验收清单](../validation/BACKEND_ACCOUNT_ACCEPTANCE.md)。
