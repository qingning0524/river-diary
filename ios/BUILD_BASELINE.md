# iOS 构建基线 · 2026-10-17

本聊天纠正后的设计基线来自 `0697` 工作区的「完善 iOS 五个页面样本」聊天及其 2026-10-15 拟态五页实现，不是桌面主项目里较早的四入口页面。

正式导航：**今天 / 足迹 / 待确认 / River / 我的**。保留 `RIVER DIARY` 共用品牌与全局日期；页面标题随内容滚动；今天为自动日记与四张功能卡；足迹为地图、待确认提示和卡片细轴；保留原拟态材质与减少动态效果适配。

设计源工作区：`/Users/fa1lingdown/.codex/worktrees/0697/河流日记项目`。

引用：`ios/IMPLEMENTATION.md`、源工作区 `ios/previews/automatic/` 与 `samples/ios-redesign/`。

本轮保留的底层修复：账号刷新合并与过期响应隔离、可重试的退出撤销、新安装空数据处理、健康批次去重、退出后的采集暂停与迟到位置回调守卫。没有用旧页面覆盖五页设计。

较早基于桌面四入口生成的 iOS 包已经撤回，不作为交付或新版设计验收证据。界面验收使用 `RiverApprovedDesignUITests`；旧四入口/手写优先UI套件已于2026-10-19移出当前目标；有效回归合入 `RiverApprovedDesignUITests`，键盘/登录/密钥专项保留。完整映射和未运行项见主规划与整合记录。

构建时应核对 `Views/RootView.swift` 的五个 Tab、`RiverAutomaticTodayView.swift`、`RiverNeumorphicSurface.swift` 和 `RiverMotion.swift`；不要只用相同的 Git HEAD 或目录最近修改时间判断版本。
