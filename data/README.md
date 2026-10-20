# 本机项目数据

| 文件 | 用途 |
|---|---|
| `raw.json` | 原有日记内容的原始快照，是 Python 数据管道的输入 |
| `data.json` | 清洗与汇总后的快照，由 `build.py` 生成，供网页预览和平台打包使用 |
| `ios-user-data.json` | 本机采集评分与健康汇总，供管道合并 |
| `.build-state.json` | 原有构建状态记录 |
| `.ios-sync-hash` | 原有 iOS 同步校验记录 |

这些数据文件保持在本机，不纳入 Git。原来的 `raw.json.bak_notion_migrate` 已归入 `archive/backups/data/`。

构建管道仍会生成 iOS 资源快照，并在 iCloud 目录存在时尝试同步。执行 `python3 build.py` 或带有 `build` 依赖的 Makefile 命令时应理解该行为；目录整理的验证没有运行这段数据同步流程。

目前原生应用的加密运行数据保存于各自应用的数据目录，具体边界见 [River Node 架构](../docs/architecture/RIVER_NODE_ARCHITECTURE.md)。
