# 用户记忆控制台重写 · 2026-10-20

## 范围

将 `website/user/` 从“账号七栏目后台”重写为 MemoryOS 只读控制台，仍为纯静态、同源 `/v1/*`、无 Node 构建依赖。

## 交付

- 七空间：记忆首页、长河、合集、地点、理解、问 River、账号与设置。
- 三外观：柔光、手记、夜色；沿用海雾蓝拟态、24px 面板、内凹输入与 River Glyph v2。
- 本机记忆副本：`river.memory-mirror` v1 + 旧 `entries` 快照；25 MB 上限；仅内存/当前标签页会话存储。
- 记忆能力：筛选、搜索、日期意图、本机抽取式回答、那年今天、久未重读、收藏、理解卡确认/纠正/撤销、快速速记。
- 账号能力：原有七栏目、401 刷新、幂等键、密码/注销/设备/会话/权益/反馈。
- 文档：主规划 §2.2/T44、DESIGN §8、[架构](../../architecture/USER_MEMORY_CONSOLE_2026-10-20.md)、[验收](../../validation/USER_MEMORY_CONSOLE_2026-10-20.md)、[website/README](../../../website/README.md)。

## 文件

- 重写：`website/user/index.html`、`website/user/assets/style.css`、`website/user/assets/app.js`
- 新增：`memory-core.js`、`account-core.js`、`demo-data.js`、`assets/glyphs.svg`、`tools/build_glyphs.py`、`tests/*.test.mjs`、`website/user/README.md`
- 旧文件备份：`archive/backups/2026-10-20-user-console-before-memoryos/`
- 旧 `assets/console.js` 与 `tests/console.test.mjs` 已由新控制器和 32 项新测试替代；备份见 `archive/backups/2026-10-20-user-console-before-memoryos/`

## 验证

- 32 项 Node 测试通过；`node --check` 通过。
- Chromium 七空间 × 320/390/768/1024/1440 无横向溢出、无 console error。
- 导入/搜索/回答/收藏/理解卡/账号 mock 流程通过；截图见 `output/qa/user-console-2026-10-20/`。
- 详细边界与未验项见 [验收](../../validation/USER_MEMORY_CONSOLE_2026-10-20.md)。

## 未完成

原生导出入口与真实副本、真实账号/生产联调、真实设备/辅助技术验收。状态：**静态前端已部署、真实联调待验（T44）**。

## 发布

已部署静态前端到 `https://user.flowriver.xyz/`（2026-10-20 10:48–10:58 Asia/Shanghai）。旧版备份在服务器 `/var/backups/flowriver/user-console-before-20261020T024810Z`；首次新控制台备份在 `...-20261020T025826Z-v2`。部署包 SHA-256 `ae26c9b9…`；线上 `app.js` `378a3f6f…`、`index.html` `7078bcdc…`。未修改 Caddy。部署指纹见 [evidence](../../validation/evidence/2026-10-20/user-console-deployment.json)。`website/user/` 仍是未提交工作区；未提交、未创建 PR。
