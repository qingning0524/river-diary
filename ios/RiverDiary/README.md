# 河流日记 iOS · AI 自动日记

产品与开发唯一入口：[主规划](../../主规划.md)；本文件说明当前实现与运行方式。

本轮将已确定的五页拟态设计接入现有自动记录核心：今天、足迹、待确认、River、我的。顶部共用 RIVER DIARY 与全局日期；不会恢复已删除的工具排。

## 产品主线

授权后的位置到访/显著位置变化、运动识别、健康摘要、本机照片线索，以及快捷指令和跨设备事件，会自动写入既有 RiverLocalDatabase / RiverDiaryCore Event 流。事实先保存并呈现，不依赖 AI 返回或用户逐条确认。

连接本机或获准网络模型后，新增输入会在安静 45 秒后自动安排当日整理，自动调用最短间隔为 5 分钟。沿用 AnalysisJob、输入指纹、来源白名单和 canonical Artifact 机制；自动生成的日记进入“我的 → 自动日记”。日界切换会更新自动任务键，前台周期同步会重新检查调度。

待确认处理模糊地点、不确定事实解释和习惯提问。用户决定进入现有共享 State Operation，纠正和跨端复制沿用原有链路。手动文字是可选补充，不是创建每段活动的必经步骤。

时间分布使用已观察到且有时长的来源区间，按日裁剪、重叠去重；不要求用户填写时长，不把缺失时段当作休息或零值。

## 打开和构建

打开 `RiverDiary.xcodeproj`，正式应用选择 `RiverDiary` scheme。需按本机环境设置 `DEVELOPER_DIR`：

```bash
DEVELOPER_DIR=/Users/fa1lingdown/Downloads/Xcode-beta.app/Contents/Developer \
xcodebuild -project ios/RiverDiary/RiverDiary.xcodeproj -scheme RiverDiary \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/river-auto-release build CODE_SIGNING_ALLOWED=NO
```

上述构建检查不等于签名分发或手机安装。正式设备运行保留工程现有 Team 与签名设置。

## 首次连接

在设置中一次性选择并授权记录来源、同步目录及 AI 输入范围。位置、照片、健康与运动受 iOS 权限控制；应用使用事件依赖用户配置的 Shortcuts 自动化，不能读取任意 App 的正文。网络 AI 只有在独立同意与模型配置后才使用已选择的数据类型；账号接口不接收日记、位置和健康正文。

## 验证与预览

- `swift test --package-path Packages/RiverDiaryCore`：54 项通过，包括自动应用事件无需手动文字/确认即可形成时段、跨端复制与用户纠正，以及新的来源时段统计测试。
- QA Debug（带模拟器签名）与正式 Release 构建通过。
- 五页原生预览：`ios/previews/automatic/index.html`。数据来自独立 QA 合成事件与 AI 产物，不是对真实模型质量或后台采集的实测声明。
- 真机位置/运动/健康权限、后台唤醒、真实模型服务和双设备 File Provider 链路仍需设备与连接验证。此前该 SDK 的 UI runner 连接失败，不能把构建或截图计为完整界面测试通过。

设计和版本来源见 [iOS构建基线](../BUILD_BASELINE.md)。2026-10-19进一步清理无调用的旧首页链路和四入口UI断言，保留当前五页实现；代码/测试迁移和本轮验证见 [整合记录](../../docs/maintenance/MASTER_PLAN_CONSOLIDATION_2026-10-19.md)。历史通过数只对应当时运行。
