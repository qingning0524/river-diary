# 加密备份链路与恢复手册 · 2026-10-22

状态：**链路已在本机与生产只读核对；恢复只做过“解密 + zstd 解压校验”，没有在独立数据库做过完整重放演练。** 这份文档描述当前真实配置，不把计划写成已完成。

## 1. 一句话

服务器每小时 `pg_dump → zstd → age(公钥)`，密文留在服务器本机 7 天；一台受控 Mac 每天 03:20 / 15:20 把密文拉到本机，用只存在于 Mac 的 age 私钥做解密与解压校验。**服务器没有私钥，也没有对象存储级的第三份副本。**

```text
PostgreSQL
  │ pg_dump --no-owner --no-privileges
  ▼
/var/lib/flowriver/tmp/dump.XXXXXX
  │ zstd -19
  ▼
/var/lib/flowriver/tmp/dump.XXXXXX.zst
  │ age -r <BACKUP_AGE_RECIPIENT>
  ▼
/var/lib/flowriver/backups/flowriver-YYYYMMDDTHHMMSSZ.sql.zst.age
  │ rsync over SSH（Mac 发起）
  ▼
Mac:~/Backups/flowriver/  →  age -d -i ~/.config/flowriver-backup/age.key | zstd -t
```

## 2. 服务器端

| 项 | 实际值（2026-10-22 只读核对） |
|---|---|
| 脚本 | `/opt/flowriver/bin/backup-local.sh` |
| systemd service | `flowriver-backup-local.service`，`Type=oneshot`，`UMask=0077`，`ProtectSystem=strict`，只写 `/var/lib/flowriver` |
| timer | `flowriver-backup-local.timer`，`OnCalendar=hourly`，`RandomizedDelaySec=3m`，`Persistent=true` |
| 环境文件 | `/etc/flowriver/backup.env`（`DATABASE_URL`、`BACKUP_AGE_RECIPIENT`、`BACKUP_KEEP_HOURS`；不在仓库） |
| 输出目录 | `/var/lib/flowriver/backups` |
| 保留 | `BACKUP_KEEP_HOURS` 默认/当前 168 小时（7 天），脚本按 mtime 删除旧文件 |
| 状态文件 | `/var/lib/flowriver/backup-state.json`：最后成功时间、对象名、字节数、sha256、耗时 |
| 最近观察 | 2026-10-21 18:01:50 UTC 运行成功（status=0），目录内有 3 个 `flowriver-*.sql.zst.age`，每个约 29 KB |

脚本要点：

- `pg_dump` 不落明文到持久目录；临时文件在 `/var/lib/flowriver/tmp`，加密后立即删除；
- 服务器只持有 age **公钥**；`age -r` 加密，明文不经过网络；
- 每次写入后计算 `sha256` 并更新状态文件，便于 Mac 侧比对；
- 失败会以非零退出，systemd 记录在 `journalctl -u flowriver-backup-local`；当前**没有外部告警**。

只读检查：

```sh
ssh root@198.23.189.187 \
  'systemctl list-timers --all | grep flowriver; cat /var/lib/flowriver/backup-state.json; ls -lh /var/lib/flowriver/backups | tail'
```

## 3. Mac 端（异地副本）

| 项 | 实际值 |
|---|---|
| LaunchAgent | `~/Library/LaunchAgents/xyz.flowriver.backup-pull.plist` |
| 程序 | `/bin/bash /Users/<user>/.hermes/scripts/flowriver_backup_pull.sh` |
| 时间 | `RunAtLoad=true`，每天 03:20 与 15:20（本机时区） |
| 本机目录 | `~/Backups/flowriver/`，保留 14 天 |
| 私钥 | `~/.config/flowriver-backup/age.key`，权限 `600`，只在 Mac |
| 状态 | `~/.hermes/profiles/m-r/cache/flowriver_backup_status.json` |
| 日志 | 同目录 `flowriver_backup_pull.log` / `.err.log` |
| 最近观察 | LaunchAgent 已加载，`runs=3`，`last exit code=0`；状态文件显示 2026-10-21 16:42:02 UTC 拉到 `...164011Z`，`decrypt_verify=true` |

脚本每次：

1. `rsync -az --partial` 从服务器拉整个备份目录；
2. 取最新 `.age`，`age -d -i <key> | zstd -t` 做真实解密和解压校验；
3. 读取服务器 `backup-state.json`，把本地文件年龄、解密结果、服务器最后成功时间/字节数/sha256 写入状态文件；
4. 删除本机 14 天前的 `.age`。

> 2026-10-22 核对时，服务器最新对象是 18:01 UTC，Mac 最新本地对象仍是 16:40 UTC；下一次定时拉取是 03:20 本机时间。这是链路正常的“尚未到拉取点”，也说明**异地副本的新鲜度不是 1 小时**，见下一节。

## 4. RPO / RTO（必须按这个口径说）

| 场景 | 最坏损失 | 说明 |
|---|---|---|
| 服务器磁盘/主机故障，Mac 未被波及 | **约 12 小时** | Mac 每天只拉两次；服务器本机的每小时备份随主机一起丢失 |
| 数据库误删/逻辑损坏，服务器仍在 | 约 1 小时 | 可从服务器本机最近一次 dump 恢复；先复制到安全位置再操作 |
| Mac 与服务器同时损坏/丢失 | 全部未拉取的备份 | 没有第三份对象存储副本；这是当前明确缺口 |
| age 私钥丢失 | 所有备份不可解密 | 私钥不在服务器；丢失不可恢复，必须离线另存 |

**RTO 未实测。** 没有在独立 PostgreSQL 实例上做完整 `psql` 重放并校验表行数；只验证了密文能解密、zstd 能解压。真实恢复时间取决于 dump 大小、目标机性能和迁移脚本。

## 5. 恢复演练（只在隔离库，绝不覆盖生产）

```sh
# 1) 选最新密文并复制到临时目录；不要直接在备份目录里解密
newest=$(ls -t ~/Backups/flowriver/flowriver-*.sql.zst.age | head -1)
mkdir -p /tmp/flowriver-restore
age -d -i ~/.config/flowriver-backup/age.key "$newest" \
  | zstd -d > /tmp/flowriver-restore/flowriver.sql

# 2) 建一个一次性数据库（示例名必须与生产不同）
createdb flowriver_restore_check
psql flowriver_restore_check -v ON_ERROR_STOP=1 -f /tmp/flowriver-restore/flowriver.sql

# 3) 校验关键表存在、行数与最近时间合理；不要只看到“无报错”就结束
psql flowriver_restore_check -c '\dt'
psql flowriver_restore_check -c 'SELECT count(*) FROM users;'
psql flowriver_restore_check -c 'SELECT count(*) FROM user_memory_mirrors;'

# 4) 清理临时明文
dropdb flowriver_restore_check
rm -f /tmp/flowriver-restore/flowriver.sql
```

注意：

- 解密后的 `.sql` 是**全量明文**，必须放在加密磁盘/临时目录，校验完立即删除；
- 不要在 `/var/lib/flowriver/backups` 内解密，避免明文落进备份目录；
- 恢复前先确认 `DATABASE_URL` 指向隔离库；生产恢复需要单独维护窗口和 PM 确认；
- 若备份来自旧 schema，先跑迁移再校验，不能把“表存在”当成“数据正确”。

## 6. 密钥保管与轮换

- 私钥 `~/.config/flowriver-backup/age.key` 只保存在受控 Mac，权限 600；不要放进仓库、网盘同步目录或服务器；
- 至少离线保存一份恢复副本（例如加密 U 盘/密码管理器），并记录对应的**公钥指纹**；只备份公钥没有用；
- 轮换：在 Mac 生成新 keypair → 把新公钥写入服务器 `BACKUP_AGE_RECIPIENT` → 重启 timer → 用新私钥验证下一份密文 → 旧私钥至少保留到旧备份全部过期（7 天）后再归档；
- 私钥丢失时，服务器上的旧密文无法恢复；不要删除旧密文，直到确认新链路可用。

## 7. 监控与已知缺口

当前可观察：

```sh
ssh root@198.23.189.187 'systemctl status flowriver-backup-local.timer --no-pager; journalctl -u flowriver-backup-local -n 40 --no-pager'
launchctl print gui/$(id -u)/xyz.flowriver.backup-pull | sed -n '1,40p'
cat ~/.hermes/profiles/m-r/cache/flowriver_backup_status.json
```

缺口（不能宣称已解决）：

1. **没有外部告警**：timer 失败只进 journal；Mac 拉取失败只进 launchd 日志，没有人会被主动通知。
2. **没有第三份副本**：Mac 是唯一异机副本，且可能和服务器处于同一网络/同一地区。
3. **没有完整恢复演练**：只做了解密/解压校验，没有独立库重放与行数核对。
4. **没有备份加密轮换记录**：当前只有一把 age 密钥；轮换流程写在上面，尚未实际执行。
5. **备份不含对象存储/下载包**：只覆盖 PostgreSQL；`/var/lib/flowriver/downloads`、Caddy 配置、网站静态文件不在 dump 内，需要单独备份/重建。

## 8. 变更记录

- 2026-10-21：Hermes PM 部署本机 age 加密备份与 Mac 拉取 agent。
- 2026-10-22：只读核对 units/脚本/状态，补本手册；未修改服务器配置，未执行恢复。
