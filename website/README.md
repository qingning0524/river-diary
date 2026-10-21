# flowriver.xyz 网站与云服务

本目录包含官网、登录页、记忆控制台三套纯静态前端,以及统一网关(Caddy)配置。
后端 FlowRiver 账号 API(Go + PostgreSQL)由 `server/` 提供,部署在 VPS 的
`/opt/flowriver`,由 systemd 管理;网页前端不依赖 Node,直接由 Caddy 提供文件服务。

官网与管理员后台使用顶部悬浮导航和统一拟态材质，支持浅/深色外观、全屏及手机布局。官网公告、更新日志、下载状态和反馈继续使用同源 API；状态异常时不会开放旧安装包入口。

原用户中心已重写为 **MemoryOS 只读控制台**，并已部署到 `https://user.flowriver.xyz/`：记忆首页、长河、合集、地点、理解、问 River、独立云空间与账号设置八个空间。记忆正文默认只从用户主动选择的本地 JSON 副本读取；云空间是独立入口，只有用户显式加密上传后才保存密文。账号接口默认仍只处理身份、设备、权益与反馈。说明见 [`user/README.md`](user/README.md)，契约见 [`docs/architecture/USER_MEMORY_CONSOLE_2026-10-20.md`](../docs/architecture/USER_MEMORY_CONSOLE_2026-10-20.md)。

## 站点地图

| 域名 | 目录(服务器) | 内容 |
|---|---|---|
| `flowriver.xyz` 与 `www` | `/var/www/flowriver/site` | 官网(首页、服务条款、隐私政策、服务状态、`/.well-known/security.txt`、macOS 安装包下载) |
| `login.flowriver.xyz` | `/var/www/flowriver/login` | 登录 / 注册 / 找回密码(调用同源 `/v1/*`) |
| `user.flowriver.xyz` | `/var/www/flowriver/user` | 用户记忆控制台:记忆首页、长河、合集、地点、理解、问 River、账号设置与可选加密云空间(调用同源 `/v1/*`) |
| `api.flowriver.xyz` | — | 账号 API(iOS/macOS 客户端入口) |
| `admin.flowriver.xyz` | — | 管理后台(Go 进程内嵌 UI) |

关键设计:`login` / `user` 两个子域通过 Caddy 的 `handle /v1/*` 反向代理到
`127.0.0.1:8080`,前端用相对路径请求 API,天然同源、无需 CORS。会话令牌存放在
`Domain=.flowriver.xyz` 的首方 Cookie(`fr_session`)里,登录页与记忆控制台共享。

## 本地开发 / 预览

任何静态服务器即可,例如:

```sh
cd website/site && python3 -m http.server 8090
# 用户控制台另开一个终端
cd website/user && python3 -m http.server 8099
```

用户控制台可直接打开 `http://127.0.0.1:8099/?preview=1` 查看合成演示；未带 `preview=1` 时会要求登录。登录页与记忆控制台在本地没有后端,仅预览布局;真实账号流程需在线上验证。

## 更新与发布(从项目根目录)

```sh
# 1. 上传三套前端(在仓库根目录执行)
rsync -av --exclude='downloads/' --exclude='tests/' website/site/ root@198.23.189.187:/var/www/flowriver/site/
scp -r website/login/* root@198.23.189.187:/var/www/flowriver/login/
scp -r website/user/* root@198.23.189.187:/var/www/flowriver/user/

# 2. 网关配置变更时
scp website/deploy/Caddyfile root@198.23.189.187:/etc/caddy/Caddyfile
ssh root@198.23.189.187 'caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && systemctl reload caddy'
```

Caddy 对新域名自动签发 / 续期 Let's Encrypt 证书,无需手工操作。

## 后端(参考)

后端部署、更新、备份流程见 `docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md`
与 `server/README.md`。生产配置在服务器 `/etc/flowriver/server.env`(权限 600,
不入库、不入聊天记录)。当前模式:

- `ACCOUNT_AUTH_MODE=email_only`(Apple 登录未启用)
- `SECURITY_JOURNAL_MODE=login_only` — 注册 / 登录可用;账号删除、身份撤销
  依赖异机安全日志接收端,该组件上线前保持 fail-closed(记忆控制台会如实提示)
- 事务邮件经本机 Postfix(loopback)直投出站,DKIM 由 OpenDKIM 签名

## 测试

```sh
cd website/user && node --test tests/*.test.mjs
```

当前 41 项通过；浏览器流程、账号 mock API 与双设备云空间验证见 [控制台验收](../docs/validation/USER_MEMORY_CONSOLE_2026-10-20.md)、[云空间验收](../docs/validation/USER_MEMORY_CLOUD_2026-10-20.md) 与 [原生互通验收](../docs/validation/CLOUD_INTEROP_2026-10-22.md)。

## 已知边界与后续工作

1. 异机安全日志接收端 + 对象存储级第三份备份尚未配置。当前数据库备份是
   「服务器每小时 `pg_dump → age`，受控 Mac 每日两次拉取」；解密恢复、
   RPO/RTO 与缺口见 [`docs/operations/ENCRYPTED_BACKUP_CHAIN.md`](../docs/operations/ENCRYPTED_BACKUP_CHAIN.md)。
   安全日志接收端上线后才能切换 `SECURITY_JOURNAL_MODE=offsite` 并启用完整删除流程。
2. iOS TestFlight 上架后补官网下载卡片。
3. 安装包在管理员后台上传与开放，服务端存放于 `DOWNLOAD_DIR`（生产为 `/var/lib/flowriver/downloads`）。官网 `/downloads/*` 由 Caddy 转发至 API，每次下载检查开放状态；暂停后旧链接返回 404。不要将本地历史 `site/downloads/` 包直接上传为公开静态文件。
4. 2026-10-09 按所有者要求，`admin.flowriver.xyz` 支持不同网络通过管理员密码与动态验证码登录。生产 `ADMIN_ALLOWED_IPS=0.0.0.0/0,::/0`；登录限速、会话校验、CSRF、正式 Origin 和敏感操作二次验证继续启用。
5. 用户控制台静态前端与云空间服务端已部署，现有 Caddy CSP/缓存头已验证；Mac/iPhone 已有 CloudMirror 原生最小入口（本机导出→加密→上传；下载→解密→只读预览，健康默认关闭），Mac app 与 iOS app/test target 均在隔离 Xcode 环境编译通过；但真实账号生产联调、真机 UI 旅程、真实 Safari/VoiceOver、8/16 MB 边界与原生恢复写回仍是 T12/T44/T45 待办；演示入口只用合成数据。
