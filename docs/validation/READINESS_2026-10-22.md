# 就绪检查与状态页邮件队列（Block 7）

状态：**API、状态页与 Caddy 路由代码完成；生产尚未部署。**

## 1. `/health/ready` 新口径

保留数据库探活：数据库不可用时仍返回 **503 `temporarily_unavailable`**（这是无法判断，不是业务降级）。

数据库可用时，一次查询读取：

| 字段 | 含义 | 降级条件 |
|---|---|---|
| `mail_failures_5m` | 最近 5 分钟已终态失败的 `email_otp` 任务数（`completed_at` 非空且 `last_error_code` 非空） | `> 0` |
| `outbox_unfinished` | 所有未完成 outbox 任务数（不限于邮件） | 与最老任务年龄一起判断 |
| `outbox_oldest_unfinished_seconds` | 最老未完成 outbox 任务的年龄；无任务为 0 | `> 600` 秒且确有未完成任务 |
| `status` | `ready` / `degraded` | 任一条件命中即 `degraded` |
| `degraded_reasons` | `mail_failures_5m`、`outbox_oldest_unfinished_seconds` | 稳定机器可读键 |
| `checked_at` | 本次检查时间（UTC） | — |

**异常返回 HTTP 200 + `status=degraded`，不是 500**；只有数据库不可用才 503。状态页可直接展示降级原因。响应带 `Cache-Control: no-store`。

## 2. `/status` 页面

- 新增第三张卡片「邮件投递与任务队列」，读取同源 `/health/ready`。
- 正常显示“邮件队列正常”；降级显示“已降级：5 分钟失败 N 次，最老未完成 N 分钟”，圆点为警示色。
- 健康接口没有 `mail_failures_5m` / `outbox_unfinished` 字段时显示“健康检查未提供邮件队列指标”，不把旧服务端误报为正常。
- `/health/ready` 请求失败时显示“暂时无法获取”，不影响账号/下载两张卡片的独立结果。
- 页面版本升为 `status-2 · 2026-10-22`，`status.css/js` 查询串升为 `20261022b`。
- Caddy 官网增加 `handle /health/*` 反代到 `127.0.0.1:8080`，状态页才可同源读取；`api.flowriver.xyz/health/ready` 仍可直连。

## 3. 验证

| 项目 | 结果 | 证据 |
|---|---|---|
| 服务端全量 | **73 个顶层测试通过，0 跳过，0 失败** | [server-tests.log](evidence/2026-10-22/block7/server-tests.log) |
| 新增 readiness 用例 | 健康队列 ready；5 分钟内失败 degraded 且 HTTP 200；最老未完成任务 degraded；6 分钟前失败不降级 | `server/internal/httpapi/readiness_test.go` |
| 页面成功态 | 1280×1100 无头 Chrome：三卡均正常，`aria-busy=false` | [status-ready.png](evidence/2026-10-22/block7/status-ready.png) |
| 页面降级态 | mock `mail_failures_5m=2`、`oldest=720s`：显示“已降级：5 分钟失败 2 次，最老未完成 12 分钟” | [status-degraded.png](evidence/2026-10-22/block7/status-degraded.png) |
| 手机布局 | 390×900：降级文案换行正常 | [status-degraded-mobile.png](evidence/2026-10-22/block7/status-degraded-mobile.png) |
| Caddy 配置 | 远端 staging `caddy validate`：`Valid configuration`（未 reload） | [caddy-validate.txt](evidence/2026-10-22/block7/caddy-validate.txt) |

页面渲染原始输出：[status-render.txt](evidence/2026-10-22/block7/status-render.txt)。

## 4. 未验证 / 不能宣称

- **生产尚未部署**：新 `/health/ready` 需要新服务端二进制；`/status` 新卡片需要同步 site 静态文件并 reload Caddy。当前线上 `/status` 仍是 `status-1`，不能宣称已上线。
- 没有制造真实邮件失败或真实 outbox 积压；测试是数据库 fixture，不等于线上告警验证。
- 状态页把 HTTP 200 `degraded` 当展示状态；负载均衡器若只看 HTTP 码仍会继续转发。这是 PM 要求的“非 500”，但不是自动摘流。
- 未接入外部监控/告警；只在打开页面时检查。
- Caddy 只做了 staging validate，没有在生产 reload；`/var/www/flowriver/user` 未触碰。

## 5. 需要 PM

- **部署窗口**：部署新服务端二进制 + 同步 `website/site` + 安装已验证的 Caddyfile 并 reload；三个动作需要一起做，否则状态页会显示“未提供邮件队列指标”。
- **告警策略**：是否把 `degraded` 接到外部监控；当前只有页面可见。
- 生产 `user` 控制台保持不动（按指令不部署、不覆盖）。
