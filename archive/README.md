# 历史归档

这里保存有保留价值的旧资料。当前源码、开发计划和当前安装包分别在平台目录、`docs/` 和 `dist/`。

| 文件夹 | 用途 |
|---|---|
| `backups/` | 原有完整重构备份和 UI 改造前备份；`make backup` 的新备份也写到这里 |
| `backups/data/` | 原始数据迁移前的历史副本 |
| `backups/ddist/` | 与其他旧包内容不同的历史安装包 |
| `releases/macos/` | 原有 Mac 旧安装包与 ZIP，保留不同的可执行版本 |
| `releases/ios/` | 原有 iOS 模拟器安装包 ZIP；与 ZIP 完全相同的解包副本已合并 |
| `design/` | 十主题和个人记忆 OS 的原始交互页面与历史资料 |
| `design-packages/` | 旧主题设计 ZIP 和当时的生成脚本 |
| `personal/` | 原有视频脚本等个人创作资料 |

`design-packages/build_theme_design.py` 是历史生成稿。它依赖的旧设计 Markdown、主题 JSON 和图片保存于同目录的主题设计 ZIP 中；需要恢复当时的输入结构后才能运行。

备份、旧安装包和个人资料保持在本机，不纳入 Git。两份原有备份 TAR 含完整历史源文件及不同日期的数据，已保留；与 TAR 内容重复的解包目录及其编译缓存已移除。
