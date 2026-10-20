# 主规划整合与过期代码清理 · 2026-10-19

状态：整合与已确认过期代码清理完成；iOS目标编译通过，UI实际运行仍待环境恢复。此次未实现主规划中的新功能，也未将全产品发布门槛标为通过。

## 主规划与规格

- 当前唯一完整规划：[根目录主规划](../../主规划.md)。融合产品目标、五页/五工作区、AI定位、功能拓展、生命周期、恢复、任务依赖与验收；43条任务保留T01–T42（T08拆a/b）。
- 主项目移除9份已合并/完成/被替代的规划；聊天工作区移除4份草案，只留指向桌面主规划的入口。没有将旧工作区源码覆盖到主项目。
- README、文档索引、目录说明、设计规范、架构/管道说明、账号操作/验收和日期记录的规划链接已统一。历史报告继续保留并标日期，不把旧四入口截图当当前设计。
- 删除旧的“以后改CloudKit整文件同步”和多管理员扩展建议；保留现有原生加密复制、单管理员服务与仍使用的旧数据兼容入口。模型接入保留协议/恢复/预算要求，去掉过时型号与单价的长期绑定。

移出的主项目规划：

- `规划.md`
- `docs/planning/ACCOUNT_REFACTOR_PLAN.md`
- `docs/planning/FLOWRIVER_MAIL_REFACTOR_2026-10-09.md`
- `docs/planning/GPT6_MIGRATION_PLAN.md`
- `docs/planning/IOS_REFACTOR_PLAN.md`
- `docs/planning/MAC_REFACTOR_PLAN.md`
- `docs/planning/SERVER_FULL_AUDIT_2026-10-10.md`
- `docs/planning/personal-context-learning-strategy.md`
- `docs/designs/ios/river-ios-personal-memory-os.md`

## 已确认过期的源代码

移除以下无生产调用的文件/脚本：

- `ios/RiverDiary/RiverDiary/Views/RiverTimelineHomeView.swift`
- `ios/RiverDiary/RiverDiary/Views/RiverDayReadingView.swift`
- `ios/RiverDiary/RiverDiary/Views/MoodEditorSheet.swift`
- `ios/RiverDiary/RiverDiary/Views/RiverThemeTimeWindow.swift`
- `scripts/check_theme_time_windows.swift`

另外移除 `RiverDayReadingStatistics` 和 `RiverThemeSectionMasthead` 两个无调用声明。`RiverDayReadingMath` 仍由今天/足迹/River使用，`RiverThemeReadingLead` 仍由足迹和活动详情使用，均保留并核对引用。

上述旧首页链路不被RootView或任何当前路由创建；新入口为RootView→RiverAutomaticTodayView。Xcode同步目录自动收集当前文件，已用独立干净derivedData编译应用和UI runner，不依赖旧缓存中的类型。

## UI回归契约迁移

旧的SystemRedesign、ModernStyles、SecondaryReading、IOSOptimization四套UI文件已从当前目标移除；它们的旧首页箭头、手写优先层级、四入口名称、地图/时间线切换和旧确认详情操作已经不符合五页设计。有效行为按下表迁移，实际运行结果另行记录。

| 仍需覆盖的行为 | 当前落点 |
|---|---|
| 五页导航、共用日期、标题滚动 | RiverApprovedDesignUITests |
| 空数据补充、草稿重启、保存后搜索 | RiverApprovedDesignUITests |
| 地图与时间线同时可用、搜索筛选、原始依据 | RiverApprovedDesignUITests |
| 内联事实纠正仅关闭其卡片，地点问题保留 | RiverApprovedDesignUITests |
| 三种外观切换与重启后偏好、最大字号写作/可选评分 | RiverApprovedDesignUITests |
| 收藏跨重启、档案继续写作 | RiverApprovedDesignUITests |
| 普通与最大字号River键盘/发送/底栏恢复 | 保留RiverProductPolishUITests两个专项 |
| 登录/验证码/密码/找回/大字号表单 | 保留RiverLoginDesignUITests五个专项 |
| 条件性QA密钥导入与Keychain读回 | 保留RiverDiaryQASmokeUITests，缺专用测试密钥时如实skip |
| 按日期/用途隔离草稿、写失败保留输入 | 保留RiverLocalDraftStoreTests |

UI用例由35项整理为15项，其中当前五页套件由2项补为7项。数量减少不表示自动获得同等全部覆盖：真实全局日期选择→跨页→问题草稿往返，以及全部分类/二级页面的大字号组合仍列在主规划T10/T13/T23待操作验收。不能用下列编译成功替代这些旅程。

## 本轮验证

| 检查 | 结果 |
|---|---|
| Mac隔离XCTest | 420项通过，0失败 |
| Python管道 | 12项通过 |
| 保留的时间/区间算法检查 | 9项通过，含重叠/重复/跨日/未知与实际零 |
| iOS QA应用与当前UI runner build-for-testing | TEST BUILD SUCCEEDED，含新五页用例编译/链接/模拟器签名 |
| iOS两项定向UI运行尝试 | runner连接DTServiceHub/lockdown失败；85秒停止本轮进程，无用例断言完成，不能称通过 |
| Core / Go | 可执行代码未变，本轮未重复运行；先前审查结果保留原日期边界 |
| Git空白检查 | git diff --check通过；另校验新增主规划任务ID和链接 |

取消UI运行后出现的Xcode终止堆栈是工具进程中断日志，不作为应用逻辑崩溃证据。没有卸载正式App、迁移真实数据库或变更正式密钥。

验证文件见 [verification.json](../../output/qa/master-plan-consolidation-2026-10-19/verification.json)、[UI迁移明细](../../output/qa/master-plan-consolidation-2026-10-19/ui-coverage-map.json)、[Mac摘要](../../output/qa/master-plan-consolidation-2026-10-19/mac-test-summary.txt)、[iOS构建](../../output/qa/master-plan-consolidation-2026-10-19/ios-build.log)、[iOS运行阻断](../../output/qa/master-plan-consolidation-2026-10-19/ios-runtime-attempt.log)。output为本机忽略产物，不纳入发布包。

## 备份与恢复

删除/改写前的93个原文件已按字节复制并核对SHA-256，备份位置：[river-master-20261019-013518](/Users/fa1lingdown/.codex/plan-cleanup-backups/river-master-20261019-013518)。

`manifest-before.json`保存每个文件原路径、备份路径、摘要和大小；code/documentation-cleanup-actions分别说明为何更新或移除；`manifest-after.json`记录本轮结果。恢复时按单个文件核对本轮后指纹，再取原字节，不要整包覆盖主项目其它聊天的未提交工作。

没有替用户提交/推送其它未完成改动。今后只在主规划维护取舍和待办，日期证据留在validation/changes，实现说明留在architecture，避免再次分裂。
