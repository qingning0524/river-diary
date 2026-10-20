# 双端原生资源接入

v2.0。`RiverGlyph.xcassets` 与 `RiverGlyph.swift` 是双端共享的唯一界面图标来源。没有 Mac/iOS 两种界面风格，也没有平台参数。

1. 将 `RiverGlyph.xcassets` 和 `RiverGlyph.swift` 加入两个 target。若在 Swift Package 内使用，应把资源放入包，并按包的资源 Bundle 调整 Image 查找；当前组件按 App 主 Bundle 查找。
2. 两端使用同一调用：

```swift
RiverGlyphView(.memory, state: isSelected ? .selected : .normal, size: 18)
RiverGlyphView(.river, state: selected ? .selected : .normal, size: 20)
```

3. 选中切换 `...Selected` 图片；系统根据 color scheme 匹配 dark。不要强制 Template，也不要用 foregroundStyle 给它整体着色。
4. iOS 应用图标导入 `RiverAppIcons-iOS.xcassets`，包含普通与深色；Mac 导入 `RiverAppIcons-macOS.xcassets`，或采用 `应用图标/RiverGlyph.icns`。每个 target 只导入对应平台的应用图标目录，避免重名 AppIcon。
5. 若工程已有 AppIcon，应替换/合并现有同名 appiconset，避免重复。普通界面目录不包含 AppIcon，因此可独立使用。

四个压缩包均自动生成：

- `RiverGlyph-双端共享.zip`：共享界面 catalog、Swift、说明与路由；适合已有应用图标的项目。
- `RiverGlyph-iOS-原生资源.zip`：共享内容、iOS 应用图标目录及应用主图。
- `RiverGlyph-macOS-原生资源.zip`：共享内容、Mac 应用图标目录及应用主图/ICNS。
- `RiverGlyph-SVG.zip`：四状态 SVG、语义/路由、设计语言与使用说明。

界面图标按 32pt @1x/2x/3x 打包，建议显示 16–32pt。资源名称为 `RiverGlyphToday` / `RiverGlyphTodaySelected`。

组件将装饰图标设为 accessibilityHidden。按钮、Tab、菜单项和行必须保留文字或父控件 accessibilityLabel；不能把组件单独当成无标签按钮。

当前 App 尚未替换旧绑定。接入后需验证双端真实页面、父控件点击区域、VoiceOver、最大辅助字号和深浅色；素材编译与图录截图不能代替真机验收。
