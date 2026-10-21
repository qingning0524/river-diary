# 文档索引

[主规划](../主规划.md) · [项目目录说明](../目录说明.md) · [设计规范](../DESIGN.md)

## 唯一当前规划

根目录 `主规划.md` 统一产品目标、双端设计、AI定位、功能拓展、任务依赖、迁移恢复与发布验收。旧总规划、平台/账号/学习/模型草案和已完成的邮件专项不再并行维护；合并/清理记录见 [2026-10-19整合记录](maintenance/MASTER_PLAN_CONSOLIDATION_2026-10-19.md)。

## 当前实现参考

- [River Node与加密复制](architecture/RIVER_NODE_ARCHITECTURE.md)
- [架构背景](architecture/ARCHITECTURE.md)：历史Web/Python背景与实现参考，以当前源码及主规划界定现状
- [数据管道](architecture/DATA_PIPELINE.md)
- [数据源采集方案](architecture/DATA_SOURCES.md)：各来源的触发、范围、落盘、状态与已知缺口
- [MemoryOS 跨端设备上下文](architecture/MEMORYOS_CROSS_DEVICE_CONTEXT.md)：DayContext 事实投影、双端展示与网页镜像
- [管理员界面/权限/API](architecture/FLOWRIVER_ADMIN_CONSOLE_DESIGN.md)
- [用户记忆控制台、本机副本与加密云空间契约](architecture/USER_MEMORY_CONSOLE_2026-10-20.md)
- [iOS构建基线](../ios/BUILD_BASELINE.md) · [五页实现说明](../ios/IMPLEMENTATION.md)

架构文件描述实现；功能取舍和未完成任务只维护在主规划。

## 操作与验证

- [服务器部署操作](operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md)
- [Mac 演示版试用清单](operations/DEMO_QA_CHECKLIST.md)
- [SMTP与DNS](operations/FLOWRIVER_SELF_HOSTED_SMTP_DNS.md)
- [激活码操作](operations/FLOWRIVER_ACTIVATION_CODES.md)
- [River验收](validation/RIVER_DIARY_ACCEPTANCE.md) · [账号验收](validation/BACKEND_ACCOUNT_ACCEPTANCE.md)
- [构建验证记录](validation/DEV_BUILD_STATUS.md) · [10月17日验收](validation/RELEASE_AUDIT_2026-10-17.md)
- [10月19日双端审查](validation/DUAL_END_AUDIT_2026-10-19.md)
- [10月20日用户记忆控制台验收](validation/USER_MEMORY_CONSOLE_2026-10-20.md)
- [10月20日用户加密云空间验收](validation/USER_MEMORY_CLOUD_2026-10-20.md)
- [10月20日原生网页副本导出验收](validation/NATIVE_WEB_EXPORT_2026-10-20.md)

- [图标库统一修复验收](validation/ICON_LIBRARY_UNIFICATION_2026-10-19.md)

## 设计与历史证据

- [手机图册](designs/ios/手机端UI设计图/index.html) · [图册说明](designs/ios/手机端UI设计图/README.md)
- [Mac样例](designs/macos/samples/index.html)
- [10月4日iOS视觉审查](designs/ios/river-ios-os-visual-review.md)：历史四入口快照，仅作当时证据，不能用于当前五页验收
- `changes/` 保存按日期的平台/账号/网站/后台交付；`maintenance/` 保存结构整理；历史图稿保留其来源意义，不恢复过期产品契约。
