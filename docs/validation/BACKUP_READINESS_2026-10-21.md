# 异机备份就绪检查（2026-10-21）

## 结论

**未就绪。** 当前服务器只有备份二进制依赖，没有可用的异机备份配置；不能把同机 `/var/backups/flowriver` 当作异机备份。

## 只读检查结果

在 `198.23.189.187` 上运行 `deploy/backup-doctor.sh`：

```text
PASS  found pg_dump: /usr/bin/pg_dump
PASS  found pg_restore: /usr/bin/pg_restore
PASS  found psql: /usr/bin/psql
PASS  found age: /usr/bin/age
PASS  found rclone: /usr/bin/rclone
FAIL  BACKUP_AGE_RECIPIENT is not set
FAIL  BACKUP_REMOTE is not set
FAIL  RCLONE_CONFIG is not set
FAIL  DATABASE_URL is not set
FAIL  flowriver-backup.timer is not active

Result: 5 error(s), 0 warning(s)
```

另外确认：

- `/etc/flowriver/backup.env` 不存在。
- `/etc/flowriver/rclone.conf` 不存在。
- `flowriver-backup.timer` inactive。
- 服务器只有一块 29G 系统盘；`/var/backups/flowriver` 是同机目录，不是异机副本。

## 需要用户提供/决定

1. **异机存储**：对象存储或第二台主机，及受限的 rclone 凭据；remote 路径（例如 `flowriver-offsite:bucket/account-db`）。
2. **age 公钥**：在 Mac/离线环境生成 age 密钥，私钥保存在服务器之外；只把公钥填到服务器。
3. **数据库连接**：`DATABASE_URL`，与 API 使用同一数据库账号。
4. **对象生命周期/保留**：供应商侧 7 天保留；是否需要对象锁/不可变窗口。
5. **恢复演练**：下载密文、异机私钥解密、隔离数据库恢复、核对账号/会话/安全日志；当前仓库仍缺日志读取/重放工具。

## 当前风险

- 数据库/Linux/账号服务故障时，没有可用的异机恢复点。
- 现有 `/var/backups/flowriver` 只保护文件误删/发布回滚，不防整机或磁盘故障。
- 正式对外宣称“备份完成”前必须先补齐上述配置并完成一次恢复演练。
