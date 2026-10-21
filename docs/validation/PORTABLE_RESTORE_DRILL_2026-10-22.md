# 可移植恢复演练（2026-10-22）

## 结论

**通过。** 同一台 Mac 上使用两个独立进程、两个独立 `CFFIXED_USER_HOME`、两套独立 Keychain 命名空间，模拟“源 Mac → 目标 Mac”的可移植备份恢复：

- 源进程用本机 key A 写入合成日记、旧库、V2 事实库，导出 `.riverportable`；
- 目标进程用本机 key B，只拿恢复码和可移植文件；
- 目标端重新加密两个数据库，走现有恢复/回滚流程；
- 校验日记正文、旧库答案和 V2 地点事件；
- 结果：`DRILL_IMPORT_OK`。

这不等于第二台物理 Mac，但覆盖了“不同本机密钥 + 不同用户目录 + 不同 Keychain”的核心差异。

## 命令

```sh
make portable-drill
```

脚本：`scripts/run_portable_restore_drill.sh`

实际输出（2026-10-22）：

```text
DRILL_EXPORT_OK path=.../portable.riverportable bytes=689814
DRILL_IMPORT_OK text=DRILL-EXPORT-2026-10-22 legacy=DRILL-LEGACY-ANSWER place=DRILL-V2-PLACE
PORTABLE_DRILL_PASS bytes=689814
```

## 覆盖

- 恢复码外层加密；
- 日记 state 迁移；
- 兼容 SQLite 库重新加密；
- V2 事实库重新加密；
- 现有恢复检查点/回滚路径；
- 错误恢复码（单元测试 `PortableBackupTests`）拒绝打开。

## 未覆盖 / 下一步

- 第二台物理 Mac 的真实 Gatekeeper、文件选择器、磁盘空间和钥匙串 ACL。
- 恢复后继续写入、同步、再备份的长时间运行。
- 生产服务器账号删除/恢复的 E2E。
