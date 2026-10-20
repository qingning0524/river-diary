# FlowRiver 官网上线与云服务验收 — 2026-10-04

本次交付把 `flowriver.xyz` 从「只有 API 和管理后台」扩展为完整的对外门面与自服务入口:
官网、登录页、用户中心三套网页前端全部上线并通过端到端验收,防火墙与邮件通道完成加固修复。
后端(Go 账号 API + PostgreSQL + Caddy + Postfix/OpenDKIM)沿用既有部署,未改动二进制。

## 上线范围

| 域名 | 内容 | 状态 |
|---|---|---|
| `flowriver.xyz` / `www`(301→裸域) | 官网:理念、能力、云服务边界、macOS 下载、FAQ、[服务条款](https://flowriver.xyz/terms.html)(terms-1)、[隐私政策](https://flowriver.xyz/privacy.html)(privacy-1) | ✅ HTTPS 200 |
| `login.flowriver.xyz` | 验证码登录/注册、密码登录、忘记密码;静态页 + 同源 `/v1/*` 反代 | ✅ 真实登录流程 UI 验收通过 |
| `user.flowriver.xyz` | 用户中心:概览、设备管理、权益兑换、安全(密码/删除账号);同源 `/v1/*` 反代 | ✅ 概览/设备/安全实测通过 |
| `api.flowriver.xyz` | 账号 API(原生客户端入口,未改动) | ✅ health live/ready 200 |
| `admin.flowriver.xyz` | 管理后台(未改动) | ✅ 200 |

源码:`website/`(site / login / user / deploy/Caddyfile),更新发布方法见 `website/README.md`。

## 架构要点

- **同源代理免 CORS**:服务端无 CORS 中间件;`login`/`user` 的 `/v1/*` 由 Caddy 反代到
  `127.0.0.1:8080`,前端用相对路径请求,浏览器不产生跨域。`api.` 子域行为与原来完全一致。
- **跨子域会话**:登录页把会话令牌写入 `Domain=.flowriver.xyz` 的首方 Cookie(`fr_session`,
  Secure、SameSite=Lax),用户中心同域读取;401 时自动用 refresh_token 轮换(带幂等键)。
- **安全头**:三站统一 CSP(`script-src 'self'`,无外部脚本)、HSTS、X-Frame-Options DENY、nosniff。
  静态资产带 7 天缓存与 `?v=` 版本参数,更新 HTML 时请同步升版本号。
- **fail-closed 如实呈现**:当前 `SECURITY_JOURNAL_MODE=login_only` —— 注册/登录正常;
  账号删除与身份撤销需异机安全日志确认,用户中心会明确提示"暂不可用,数据保持完整"。

## 本次服务器变更(root@198.23.189.187,Ubuntu 24.04)

1. **Caddyfile** 替换为六站点版本(旧文件备份于 `/etc/caddy/Caddyfile.before-web-20261004`);
   四个新域名证书由 Caddy 自动签发(Let's Encrypt)。
2. **静态站点**部署于 `/var/www/flowriver/{site,login,user}`,属主 root、全局可读。
3. **防火墙**:ufw 启用(默认拒绝入站),放行 22/tcp、80 tcp+udp、443 tcp+udp(HTTP/3)、
   55795/udp(hysteria 代理,避免破坏既有用途);fail2ban 已启用并盯守 sshd。
4. **Postfix 修复**:`mydestination` 未含发信域导致退信死循环(队列中卡了 10/1 的 DSN,
   每 70 分钟重试连自己的公网 25 端口被拒)。已加 `virtual_alias_maps = regexp:/etc/postfix/virtual-regexp`,
   将 `*@flowriver.xyz` 与 `*@mail.flowriver.xyz` 重写为 `root@localhost` 本地投递;卡住的
   DSN 已删除,队列清空。**副作用(有意)**:发往本域任意地址的邮件都会落在 `/var/mail/root`,
   可用于内部验收,不会外泄。
5. 部署二进制经比对与当前源码一致(`server/` 无更新的源文件),未重建。

## 邮件身份(DNS 已齐备,无需再操作)

`mail.flowriver.xyz` 的 A、SPF(`v=spf1 ip4:198.23.189.187 -all`)、DKIM
(`flowriver._domainkey`,`opendkim-testkey` 验证 key OK)、DMARC(p=none)以及
IP 反解 PTR 均已就位。验证码邮件链路:API → loopback Postfix → OpenDKIM 签名 → 出站直投。

## 端到端验收记录

- **API 层**(公网 HTTPS):`/v1/auth/email/start` 202 → 本地收信取码 →
  `/v1/auth/email/verify` 200(TokenResponse,created=true)→ `/v1/me`、`/v1/me/devices` 200。
  产生验收账号 `ops-check@flowriver.xyz`(ID `f531103a…e02c`)。
- **浏览器层**(真实 Chromium):
  - 官网首页/云服务/下载区渲染正常,下载链接 200(7,383,231 字节,SHA-256 页面可核对);
  - 登录页完整走通"发码 → 收码 → 勾选条款 → 登录"→ 302 到用户中心;
  - 用户中心概览(账号状态/身份/条款版本)、设备页(浏览器设备标"本设备",
    E2E 脚本设备 9 分钟前活跃)、安全页(未设置密码 + 删除账号 fail-closed 说明)全部正常。
- 期间修复两处前端问题:`.aux` 的 `display:flex` 覆盖 `hidden` 属性(补 `[hidden]{display:none!important}`);
  资产缓存无版本参数(补 `?v=20261004a`)。

## 遗留事项(按优先级)

1. **异机安全日志接收端**未部署 → 删除账号/身份撤销保持 fail-closed(用户可见提示)。
   完成后:`server.env` 改 `SECURITY_JOURNAL_MODE=offsite` 并填 endpoint/token。
2. **异机备份**(rclone remote + age 公钥)未配置 → `flowriver-backup.timer` 未启用。
   按 `docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md` 第 10 步执行,并做一次恢复演练。
3. **macOS 安装包**为 10/1 构建;发新版时更新 `website/site/downloads/` 与首页 SHA-256/日期。
4. **iOS TestFlight** 上架后补官网下载卡片。
5. `server/` 目录尚未纳入 git(整个目录 untracked),建议尽快提交以便追溯部署内容。
6. 可选:管理员后台 `ADMIN_ALLOWED_IPS` 当前为服务器自身 IP(需经代理访问);
   直连管理时改为你的出口 IP 并 `systemctl restart flowriver-api`。
7. 可选:root 仍为密码登录(强密码 + fail2ban);建议在确认 SSH 密钥可用后关闭密码认证。
