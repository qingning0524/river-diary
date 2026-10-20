# 用户密码登录

用户要求在现有高端登录页加入密码登录。实现范围：普通用户密码登录、已验证邮箱设置/忘记密码、iOS 两种登录方式与账号设置入口；密码通过邮箱所有权证明设置，不为未验证邮箱直接创建密码账号。保留原验证码注册和本机资料与账号绑定保护。

端点：POST /v1/auth/password/login、POST /v1/auth/password/reset/start、POST /v1/auth/password/reset/complete、GET /v1/me/password。新增迁移 0004，旧迁移不修改。设置或重置后撤销该用户既有会话并签发当前设备新会话；证据挑战有独立 purpose、尝试次数和单次消费，注册邮件挑战不能用于改密码。

用户密码支持 15–128 个 Unicode 字符、空格和长短语，NFC 规范化；数据库只存 Argon2id 摘要（64 MiB、3 次、单并发槽），客户端不保存密码。最低长度参考 [NIST](https://www.nist.gov/cybersecurity-and-privacy/how-do-i-create-good-password)，存储参考 [OWASP](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html)。

状态：已实现并部署到 api.flowriver.xyz 与 admin.flowriver.xyz，迁移 0004 已应用。iPhone QA 版已更新安装，保留本机资料。正式应用 Release 编译已验证；未替换另一 bundle 的正式安装版。

## 管理后台

用户 → 查看 → 登录密码，展示是否设置密码及最后更新时间。管理员可输入并确认新密码、选择原因后重置。接口 POST /admin-api/v1/users/{id}/password/reset，要求管理员会话、CSRF 和 5 分钟内 MFA；重试幂等，操作审计与密码更新在同一事务。重置撤销用户旧会话，递增凭据版本使旧改密验证码失效，不提供密码摘要或原密码。

## 设置闪退修复

实机崩溃日志 RiverDiaryQA-2026-10-03-105657.ips：主线程 EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE，Swift 泛型元数据解析栈，调用源为 SettingsView.rootPage 内的复杂 NavigationLink 目的视图。将 settingsPage 的返回值限定为 AnyView，截断传播到首页的复杂泛型类型；保留布局及页面功能。设置 → 账号 → 返回的模拟器回归测试通过；更新后的 iPhone 已打开设置子页面并取得实机截图。

## 验证

- 独立本机 PostgreSQL 测试库执行 go test -race ./... 通过，包括登录、设置、重置、幂等、验证码目的隔离、过期、次数限制、凭据版本失效、旧会话撤销、邮箱身份撤销、管理员 CSRF/MFA/审计与旧密码失效。
- 三主题密码登录与找回入口 UI 测试通过；改密表单的 8 位验证码、长度提示、两次密码不一致提示通过。
- 设置与账号目的页面回归测试通过。实机自动 XCTest runner 未能连接，不将该次失败计为通过；另通过安装、直接启动和截图验证实机设置可用。
- 管理后台 TypeScript 检查与构建通过；390px 表单无横向溢出，输入框 44px，密码不一致禁用提交，匹配时可提交。布局使用本机合成账号，实际数据库行为由隔离集成测试验证。
- 公网 HTTPS 健康 200，新接口错误分支符合预期，后台静态 bundle 含新功能；服务 NRestarts=0，无发布后错误日志。不向真实邮箱发送测试验证码、不修改实际用户密码。

## 发布与恢复

用户密码 API 发布前备份：服务器 /var/backups/flowriver/password-20261003T0345Z（程序、配置、PostgreSQL dump）。后台功能发布前追加备份 /var/backups/flowriver/admin-password-20261003T0310Z（程序、PostgreSQL dump）。目录仅 root 可读，未记录连接密码。

最终服务器程序 SHA-256：02bf080d4b016343a8ae107583482ed2d244783f281fb40a53362d704b11dd8b。原子替换程序后重启 flowriver-api.service；健康检查正常。回退时使用对应备份程序原子替换并重启；迁移为增量兼容，避免覆盖实时用户数据库。
