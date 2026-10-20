# River Glyph 新版图标库审查

> 历史审查快照：以下问题已按用户最新“一套双端共用”的决定修复，当前结果见 [统一修复验收](ICON_LIBRARY_UNIFICATION_2026-10-19.md)。旧目录和源码已备份，不再作为当前规范。

日期：2026-10-19。审查目录：项目根目录 `双端图标系统/`。旧 `图标素材库/` 仅作范围对照。

结论：**设计语言值得保留，资产完整；尚未达到直接接入双端的状态。发现 2 项 P1、6 项 P2，另有 1 项需求范围偏移。** 本轮没有修改图标、生成器、应用代码或原有验收记录。以下问题属于当前交付物，不能仅凭文件时间认定由某位作者引入。

## 已通过的独立检查

| 检查 | 实际结果 |
|---|---|
| 原验收脚本 | 在 `/tmp/river-glyph-review-20261019` 副本复跑，30/30 通过 |
| 图标完整性 | 双端各 80 枚、四状态；640 个 SVG、6400 张 PNG，预期文件和尺寸齐全 |
| SVG → PNG 一致性 | 640 个 SVG 分别重渲染为 Mac 40px / iOS 50px，像素与对应 PNG 全部一致；没有声称重渲染全部 6400 张 |
| 资源目录 | 80 个 Mac、160 个 iOS imageset 的图片与对应 PNG 逐文件一致 |
| 压缩包 | 三个包共 2167 个条目，CRC 检查通过，所含文件与当前磁盘源文件逐字节一致 |
| 从来源重建 | 在副本重建 640 个 SVG、manifest、routes、Swift，共 643 个文件均与交付物一致 |
| Xcode 资源编译 | macOS、iPhone/iPad 资源目录分别通过 `actool`，生成 Assets.car；iOS AppIcon 也通过编译 |
| Swift | 原脚本的 macOS typecheck 通过；另跑 iOS 17 模拟器 arm64 typecheck，结果见证据日志 |
| 应用图标 | 三张主图均为 1024×1024；iOS 两张完全不透明，Mac 保留透明背景；ICNS 解包检查见日志/产物 |
| 图录交互 | 双平台×四状态均显示 80 枚且下载链接指向对应 SVG；搜索空结果正常，无页面脚本错误，无失效的本地链接 |
| 画布边界复核 | 小尺寸 PNG 有 98 次边缘像素接触；扩展画布重渲染未发现阈值以上的实际越界，**不将其认定为裁切缺陷** |

资源编译和类型检查不等于 App 内截图、真机和辅助功能验收；本轮没有把新库接入 App，也没有运行真实导航旅程。

## 需求范围偏移：双端共享两套风格变成了每端固定一套

原先已确认的范围是“两套完整界面风格，双端共用，含品牌与应用图标”。新版在 [README](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/README.md:3) 和 [设计语言](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/设计语言.md:11) 中明确改为“macOS 刻线 / iOS 水位”，并禁止跨平台使用另一种表达。原生组件也把风格和平台绑定在一起；应用图标则是同一个品牌方案的双平台适配，没有两套对应的品牌方案。

影响：当前交付不能等同于“两套风格都可供双端使用”。这不是渲染错误，而是产品交付范围变化。

建议：保留刻线、水位的视觉成果，把 `family` 与 `platform` 分开：两套风格共享语义，各自提供双端适配；Mac/iOS 的默认选择可以不同。如果决定采用新版的平台分工，应明确更新需求口径，不能同时宣称完成原范围。旧库先保留为历史来源，待范围与截图验收确定后再清理。

## R1 · P1：iOS 路由不存在，Mac 同一路由有相互冲突的映射

位置：[routes.json](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/共享语义/routes.json:4)、[生成器](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/build.py:139)。

- iOS 写成 `route: today → icon: today`，但当前 [RiverAppTab](/Users/fa1lingdown/Desktop/河流日记项目/ios/RiverDiary/RiverDiary/Views/IOSExperience.swift:7) 的首项是 `timeline`，没有 `today`。正确关系应为 `timeline → today`；用户可见名称“今天”不等于路由值。
- Mac 的 `macPrimary.timeline → footprints`，而 `macSections.timeline → timeline`，两处对同一真实路由给出不同图标。当前 [RiverDestination.timeline](/Users/fa1lingdown/Desktop/河流日记项目/macos/RiverDiaryMac/Sources/RiverDiaryMac/Views/RiverShell.swift:34) 的名称是“足迹”。

影响：照“路由契约”接入，iOS 首项会查不到映射，Mac 的足迹可能在不同入口显示不同图标。目前尚未绑定，因此不是现有 App 已发生的导航回归。

修正：以实际路由枚举为准，合并单一路由映射来源；修改生成器后再生成 JSON 和说明。用五个 iOS Tab、十三个 Mac Destination 验证覆盖与语义，不按显示名称推断路由。

## R2 · P1：Mac 64 枚图标的预览选中态无法通过当前原生组件复现

位置：[渲染器](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/river_glyph.py:223)、[Swift 资源选择](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/原生资源包/RiverGlyph.swift:286)。

渲染器对普通 Mac 图标的 accent 部件乘以 0.55 透明度，选中态则恢复原透明度。因此选中变化包含 alpha 变化。对 80 枚的 40px 普通/选中 PNG 比较，64 枚的 alpha 通道不同。

但 Mac 原生目录只有普通/深色资源，`RiverGlyphView` 对 `.mac` 忽略 `state`。Template 着色会保留原图片的 alpha；调用 `.foregroundStyle` 不能把 55% 的笔画恢复为 100%。例如 `add`、`play`、`refresh` 的整条主要笔画都会受影响。

影响：图录看起来较醒目的选中效果，在原生接入后更淡。按库内浅色选中背景 `#EAF0FF`、Tint `#2F6CF5` 计算，55% 合成色约 `#83A7FA`，对比度约 2.07:1，低于本库提出的 accent ≥3:1 目标。

修正（二选一）：如果坚持“Mac 仅换 Tint”，让普通/选中 alpha 完全一致，并同步图录；如果保留透明度变化，就导出 Mac Selected imageset 并让组件切换。验收应比较 Template 的 alpha 和原生结果，不能只比较 RGB 或文件存在。

## R3 · P2：闭合圆角矩形的弧线方向反了

位置：[rect_closed](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/river_glyph.py:138)。

该函数沿矩形顺时针走，但四个角使用 `A… 0 0 0`，造成内凹圆弧。圆角变成带尖顶的收缩形状，在 `microphone`、`pause` 上尤其明显；`movement`、`lock`、`copy` 也调用同一函数。十枚水位容器的裁切路径同样使用它。

证据：[麦克风放大](/Users/fa1lingdown/Desktop/河流日记项目/output/qa/icon-library-review-2026-10-19/detail-microphone.png)、[暂停放大](/Users/fa1lingdown/Desktop/河流日记项目/output/qa/icon-library-review-2026-10-19/detail-pause.png)。均为现有 SVG 放大，未更改路径。

修正：校正闭合矩形四角的 sweep，使外轮廓与水位裁切为凸圆角。`rect_open` 的路径走向相反，不应机械地一起替换。

## R4 · P2：窄容器的“水口”被圆头笔画封死

位置：[rect_open](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/river_glyph.py:119)。

`phone` 的参数为 x=6.6、宽=10.8、r=3。函数算出的开口端点约为 13.08 与 14.00，中心线间距仅 0.92u，既小于声明的 2.7–3.1u，也小于 iOS 2.0u/选中 2.2u 的笔画宽度。圆头互相覆盖，实际开口关闭；Mac 缩放后也无法保留净开口。

修正：按“描边完成后的净间距”约束开口；窄容器使用专门的开口位置或圆角参数。应在 18/20pt 下验证，不能只检查路径是否带断点。

## R5 · P2：iOS 深色应用图标只作为文件交付，没有绑定到原生目录

位置：[AppIcon Contents.json](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/原生资源包/RiverGlyphIOS.xcassets/AppIcon.appiconset/Contents.json:2)、[生成器](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/build.py:276)。

`ios-dark-1024.png` 存在，但 AppIcon.appiconset 只有普通 `AppIcon.png`。iOS 原生 ZIP 只打包 catalog，因此也不包含深色主图。单独导入文档推荐的资源目录/压缩包，不会获得这张专门设计的深色图标。

修正：把深色应用图标加入 AppIcon 外观记录和打包流程；随后用 actool 及系统主屏实际验证。现有普通应用图标通过编译，不代表深色设计已经接入。

## R6 · P2：交互图录存在重复 SVG clipPath ID，预览发生交叉引用

位置：[clip_id 生成](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/river_glyph.py:213)、[图录内联 SVG](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/showcase.py:17)。

每个导出 SVG 内使用 `clip-<语义ID>` 本来可以独立工作；图录将双平台、四状态、导航与解剖示例全部内联，却没有为实例加命名空间。页面中 `clip-confirmations` 重复 16 次，`clip-memory` 12 次，其余八组各 8 次。

Mac/iOS 的水位裁切内缩不同。浏览器可能解析到另一实例的裁切路径。实测在 iOS 选中态 `phone` 的 32px SVG 上，仅在浏览器内给每个实例的 ID 与引用加唯一后缀，前后有 40 个颜色通道值变化（1024 个像素范围内），证明预览并非完全等价于独立导出。

修正：由图录内联环节按实例重命名 defs 中 ID 及 `url(#…)` 引用，或用独立 SVG 图像。此项影响图录精确性；独立 SVG、PNG 与原生资源不受页面 ID 冲突影响。

## R7 · P2：图录在手机宽度下横向溢出

位置：[解剖布局](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/showcase.py:180)、[窄屏规则](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/showcase.py:267)。

实测 viewport=320/375/390 时 document.scrollWidth 都为 549；768/1440 正常。解剖区内部仍是双列，内含 320px 与 132px SVG，加上间距和 padding，撑开了页面。

修正：窄屏时让解剖图改为单列或按容器缩放，处理 grid 子项的 min-width，加入 320–390 宽度检查；只设 overflow:hidden 会掩盖内容，不算修复。

证据：[375px 页面截图](/Users/fa1lingdown/Desktop/河流日记项目/output/qa/icon-library-review-2026-10-19/mobile375.png)、[浏览器检查](/Users/fa1lingdown/Desktop/河流日记项目/output/qa/icon-library-review-2026-10-19/browser-audit.json)。

## R8 · P2：重建流程不会生成或刷新 SVG 下载包

位置：[package](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/build.py:295)、[现有验收](/Users/fa1lingdown/Desktop/河流日记项目/双端图标系统/工具/verify.py:188)。

当前三个 ZIP 的内容均与源文件一致。但 `package` 只生成 macOS/iOS 两个原生 ZIP；全库脚本没有创建 `RiverGlyph-SVG.zip` 的逻辑。

复现：仅在 `/tmp` 副本删除这一个 SVG ZIP 后执行 `build.py package`，两个原生 ZIP 正常生成，SVG ZIP 仍缺失。以后修改几何并按 README 重建，会遗留旧的下载包；从干净来源也不能重建完整交付。现有验收仅以 ZIP 条目数 >100 判断通过，不能发现内容陈旧。

修正：在 package 阶段自动创建 SVG ZIP，并按 manifest 比较文件集合与摘要。不要用手工打包作为长期发布步骤。

## 建议修正顺序

1. 明确“风格 × 平台”的交付矩阵，保留现有视觉成果；先统一路线，避免同时维护四套不一致定义。
2. 修 R1 路由与 R2 原生状态；它们直接影响接入行为与可见性。
3. 修 R3/R4 几何、R5 应用图标绑定，再统一重建资源。
4. 修 R6/R7 图录、R8 打包流程，补充能发现这些问题的验收。
5. 接入 iOS 五项导航和 Mac 主要工作区，分别验证深浅色、选中态、18/20pt、VoiceOver 与真实设备截图。

设计上建议保留：共享语义 ID、双笔画层级、选择性水位、克制的蓝色强调、导航与品牌双曲线的连续性。无需推倒重画；应先让设计规则、图录、导出和原生接入表达同一结果。

## 证据与审查边界

详细日志、脚本、JSON 与新截图位于：[output/qa/icon-library-review-2026-10-19](/Users/fa1lingdown/Desktop/河流日记项目/output/qa/icon-library-review-2026-10-19)。该目录受 .gitignore 忽略。

原库审查前后文件 SHA-256 清单见 `source-hashes-before.json` / `source-hashes-after.json`；不计 Finder 的 `.DS_Store`。复跑原有会写文件的验收/重建脚本只在 `/tmp` 副本进行。本次没有修改图标库、原有验收报告或 App 绑定。
