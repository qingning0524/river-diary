# River Glyph · 河流图标素材库

v2.0 · 2026-10-19。**一套 80 枚图标，iOS 与 macOS 共用同一份图形、配色、状态和资源目录。**

沿用 DeepSeek 的河流设计：品牌双流、水口、向右抬升的水面、双笔画和圆端。融合刻线的轻盈与水位的层次；平台只决定界面中的显示尺寸和应用图标外形。

- [离线交互图录](展示/index.html)：搜索、分类、四状态、18/20pt 尺寸预览、双端对照与单枚下载。
- [设计语言](设计语言.md)：唯一视觉规则。
- [原生接入说明](原生资源包/README.md)：共享组件、资源目录、应用图标。
- [路由映射](共享语义/routes.json)、[语义清单](共享语义/manifest.json)、[存量迁移](共享语义/迁移映射.md)。
- [验收记录](预览/验收.md)：实际执行结果与边界。

## 目录

```text
图标素材库/
├── SVG/{light,dark,selected,selected-dark}/   80 × 4，共享矢量
├── PNG/{state}/{size}px/                    全部来自同一份 SVG
├── 共享语义/                               manifest、真实路由映射、迁移说明
├── 应用图标/                               iOS 普通/深色，Mac PNG/ICNS/iconset
├── 原生资源包/
│   ├── RiverGlyph.xcassets                 双端共用，160 个 imageset
│   ├── RiverGlyph.swift                    双端共用，80 个语义枚举
│   ├── RiverAppIcons-iOS.xcassets           普通与深色应用图标
│   ├── RiverAppIcons-macOS.xcassets         10 档 Mac 应用图标
│   ├── RiverGlyph-双端共享.zip
│   ├── RiverGlyph-iOS-原生资源.zip
│   ├── RiverGlyph-macOS-原生资源.zip
│   ├── RiverGlyph-SVG.zip
│   └── checksums.json
├── 展示/index.html
├── 预览/                                   双端场景与四状态截图
└── 工具/                                   几何、语义、构建、回归验收
```

## 规则

- 24u 画布；主体 1.75u、细节 1.25u；选中时笔画 +0.2u。
- 水位容器：普通 60% 高度、选中 46%；染色分别为 18% / 26%，右端抬升 0.8u。
- 四种状态双端相同，深浅色由资源目录匹配；选中切换 `Selected` 资源。
- 双端都用 Original 渲染，不额外强制 Template 或加 Tint。
- Mac 侧栏推荐 18pt、工具栏 20pt；iPhone Tab 20pt、工具栏 24pt。
- 图标应配文字或父控件的可访问标签；水位不表示真实数据。

## 重建与验证

```bash
python3 图标素材库/工具/build.py all
python3 图标素材库/工具/showcase.py
python3 图标素材库/工具/previews.py
python3 图标素材库/工具/verify.py
```

`build.py` 也支持 `svg`、`png`、`package` 分阶段执行。package 会重新生成全部四个 ZIP，包含 SVG 下载包。PNG 队列使用临时文件，不存储开发者绝对路径。

依赖：Python 3 + Pillow；Node + sharp + Playwright；Chrome；macOS iconutil；原生编译验证需要 Xcode。

可用 `RIVER_ICON_NODE`、`RIVER_ICON_NODE_MODULES`、`RIVER_ICON_CHROME` 覆盖工具路径。验收可用 `--output` 指定证据目录、`--project-root` 指定 App 路由来源。源数据只在 `工具/catalog.py` 修改，渲染规则只在 `工具/river_glyph.py` 修改。

## 本次边界

这次交付统一并修复图标素材、生成流程和双端原生资源。现有 App 的图标绑定与应用图标尚未自动替换；导入前不要把设计场景预览当成 App 真机截图。保留父控件文字、点击区域和系统窗口控件。
