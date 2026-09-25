# River Diary 河流日记

本地优先的个人证据日记：把一天发生了什么、证据从哪来、系统为什么这样判断放在一处，全部数据加密存放在本机。产品与设计基准见 [DESIGN.md](DESIGN.md)。

## 目录结构

| 路径 | 内容 |
|---|---|
| `macos/RiverDiaryMac/` | macOS 主应用（Swift Package，SwiftUI + SQLCipher） |
| `docs/` | 开发与设计文档（`DEV_BUILD_STATUS.md` 验证记录、`REFACTOR_PLAN_20260925.md` 重构计划、`designs/` 设计稿） |
| `TODOS.md` | 待决策的 P1/P2 事项（密钥恢复、加密同步等） |
| `ios/RiverDiary/` | iOS 采集端（与 macOS 通过导出 JSON 对接） |
| `pipeline/` `data/` `build.py` | 项目数据管道与构建脚本（历史数据采集） |
| `scripts/` | 工具链选择（Xcode Beta）与开发包验证脚本 |
| `dist/` | 构建产物 `River Diary.app` |
| `backups/` | 历次备份归档 |

## 构建与测试

```bash
# 全量 XCTest（需要 ~/Downloads/Xcode-beta.app，scripts/select_xcode.sh 自动选择）
cd macos/RiverDiaryMac && source ../../scripts/select_xcode.sh && "$RIVER_SWIFT_EXECUTABLE" test --disable-sandbox

# 重建发布包到 dist/
make mac

# 开发包快速验证（发布构建 + 静态检查 + XCTest）
./scripts/verify_dev_build.sh
```

## 改动前必读

- 设计系统与验收清单：`DESIGN.md`（面板体系、色彩/字号/间距 token、8 条检查规则）。颜色、字号、间距一律用 token，不写裸值。
- 数据安全基线：SQLite 文本绑定必须用 SQLITE_TRANSIENT；无法解密的本地文件只隔离、不删除；内存修改在持久化成功前必须可回滚。
- 测试跑全绿再打包；`docs/DEV_BUILD_STATUS.md` 记录每轮验证结论。
