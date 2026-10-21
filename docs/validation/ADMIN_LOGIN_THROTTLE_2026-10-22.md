# 管理台登录防爆破（Block 5）

状态：**代码与单测完成（提交 `128c0b4`）；生产尚未部署。**

## 1. 行为

- 同一管理员在 **15 分钟**内累计 **5 次失败**后，第 6 次登录请求返回 **HTTP 429**，错误码 **`rate_limited`**。
- 失败包括：密码错误、密码为空/超长、账号被禁用、TOTP 验证码错误。密码正确但未完成 MFA 不计为成功。
- 成功完成密码 + MFA 后删除该管理员的失败桶，下一次从 0 开始；密码阶段成功但 MFA 未完成不会清零。
- 每次被限速拒绝都写审计 **`admin.login.throttled`**，`result=denied`，带管理员 ID 与请求 IP 的 HMAC。
- **不做 IP 封禁**。账号桶只用管理员 ID 作为 HMAC 输入；`remote_ip` 在隧道/反代下都是服务器自身地址，按 IP 封禁会误伤所有管理员。此次同时移除了旧登录/MFA 的 IP 桶分支。
- 限速状态在 **`admin_auth_buckets`** 表（沿用现有数据库桶机制，无内存态、无新表）；桶键为 `HMAC(AdminAuditHMACKey, "admin-auth-limit", "login-failure", adminID)`。清理任务仍按 `expires_at` 回收。

## 2. 代码位置

| 内容 | 位置 |
|---|---|
| 失败桶/窗口/清零 | `server/internal/adminapi/auth.go` 的 `loginFailureBucket`、`loginFailureCount`、`recordLoginFailure`、`clearLoginFailures`、`loginThrottled` |
| 登录检查与失败记录 | `login()`；在密码校验前检查，失败后记录 |
| MFA 检查与失败记录 | `completeMFA()`；在 TOTP 校验前检查，失败后在事务内记录，成功时在事务内清零 |
| 表结构 | `server/internal/migrate/migrations/0002_admin_console.sql` 的 `admin_auth_buckets`（已有，无迁移） |
| 测试 | `server/internal/adminapi/auth_throttle_test.go` |

## 3. 验证

命令：`./scripts/test_server_isolated.sh`（一次性 PostgreSQL，全部集成测试实际执行，0 skip）

| 用例 | 结果 |
|---|---|
| `TestAdminLoginThrottlesByAccountAfterFiveFailures` | 5 次 401 后第 6 次 429 `rate_limited`；换源 IP 仍 429；另一管理员不受影响；审计事件存在 |
| `TestAdminLoginSuccessClearsFailures` | 4 次失败后密码 + MFA 成功，失败桶删除；随后 5 次失败仍 401，第 6 次 429 |
| `TestAdminMFAFailuresShareTheAccountLimit` | 同一账号 5 次错误 TOTP 后第 6 次 429，不依赖密码阶段 |
| `TestAdminLoginThrottleWindowExpires` | 窗口过期后允许新的失败，桶从 1 重新计数 |

**总计：69 个顶层服务端测试通过，0 跳过，0 失败。** 原始日志：[server-tests.log](evidence/2026-10-22/block5/server-tests.log)。

## 4. 未验证 / 不能宣称

- 生产管理台尚未部署该提交；线上仍是旧逻辑。不能宣称线上已经防爆破。
- 未在真实隧道/反向代理后做人工登录压测；单测覆盖的是 HTTP handler 与数据库行为。
- 未验证多实例共享数据库时的时钟偏差（以数据库 `now()` 为准，理论上无应用时钟依赖）。
- 没有新增告警；限速事件只进 `admin_audit_events`，需要管理台审计页或外部告警才能及时发现持续攻击。

## 5. 需要 PM

- **部署窗口**：将新服务端二进制部署到管理台 API，重启后才能生效；需要确认部署/回滚窗口。
- **运维确认**：是否需要把 `admin.login.throttled` 接到外部告警；当前仅落审计表。
