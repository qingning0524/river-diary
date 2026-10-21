# 反自欺最小能力验收 · 2026-10-22

状态：**规则版已实现，Core 11 项 + Mac 4 项映射测试通过，D 阶段门禁在提交 `2b7d2fe` 上 PASSED；只在本机渲染，不接模型、不发网络请求。** 本轮只做 PM 指定的一条能力：自述与同一天客观记录明显矛盾时，给一句无评判提示。阈值是保守初值，尚未用真实用户文本做误报率评估。

## 1. 规则边界

| 项目 | 本轮做法 |
|---|---|
| 触发条件 | 同一天、用户自己写下的文字，与睡眠/步数/屏幕总时长/完成事项之一明显相反 |
| 输出 | 最多一句，陈述“你写到什么 / 记录是什么 / 可以放在一起看看” |
| 不做什么 | 不判断真假、不评价人格、不要求改正、不生成建议、不调用模型、不写回日记 |
| 数据缺失 | 缺失字段是 nil，不按 0 处理；没有对应事实就不提示 |
| 平台 | Mac 今日页与 iPhone 今日页共用 Core 规则；Mac 走 `SelfReportFactsBridge` 映射，iPhone 直接用当天健康/步数/屏幕字段 |

### 阈值与短语

| 事实 | 触发阈值 | 只在自述出现这些短语时检查 |
|---|---|---|
| 完成事项 | ≥ 3 项 | 什么都没做、一事无成、什么都没完成、什么也没做成 |
| 睡眠 | < 5.0 小时 | 睡得很好、睡得不错、睡够了、睡饱了、睡眠很好、睡到自然醒 |
| 屏幕 | ≥ 360 分钟 | 很少看屏幕、屏幕时间很少、今天几乎没看屏幕 |
| 步数 | < 1,500 步 | 走了很多、走了很多路、运动很多、运动了很多、步数很多、一直在外面走 |

优先级是完成事项 → 睡眠 → 屏幕 → 步数；即使多条同时矛盾，也只返回一句。完成事项优先，因为“记录里有几项”比时长更具体，解释成本最低。

### 已做的误报防护

- 正向睡眠/步数短语前 6 个字符出现“没 / 不 / 未”就不算正向自述，例如“没睡得很好”“不觉得睡得很好”；
- “什么都没做”前出现“不是 / 并非”时视为双重否定，不触发；
- 阈值取边界值时不触发（睡眠 5.0 小时、1,500 步、359 分钟屏幕、2 项完成）；
- 普通疲惫表达（“今天很累，但也不知道忙了什么”）没有匹配短语，不触发；
- 没有客观事实时永远返回 nil；
- 屏幕规则只匹配“屏幕总时长”的自述，不把“没怎么碰手机”当成总屏幕少，因为 Mac 的电脑使用也会计入屏幕时长。

## 2. 代码与入口

| 文件 | 作用 |
|---|---|
| `Packages/RiverDiaryCore/Sources/RiverDiaryCore/SelfReportConsistency.swift` | `SelfReportFacts` + 纯函数规则，无 Foundation 之外的依赖 |
| `macos/.../Features/Health/SelfReportFactsBridge.swift` | 把当天 `DiaryEntry` 的 `ios_health`、`screen_h`、`didItems` 映射成规则输入；优先用活动管道总时长，缺失时回退到 `screen_h` |
| `macos/.../Views/TodayDashboardView.swift` | 在“今天的轮廓”摘要下方渲染提示；带 VoiceOver 合并标签“River 注意到：…” |
| `ios/.../Views/RiverAutomaticTodayView.swift` | 在“今日自动小结”卡片内渲染同一句；使用当天睡眠/步数/`screen_h`，iOS 模型没有完成事项字段，因此不触发完成事项规则 |

只在本机渲染，不写入数据库、不上传、不触发 AI。用户不打开当天页面就看不到提示；本轮没有做推送、弹窗或强制阻断。

## 3. 测试证据

```sh
source scripts/select_xcode.sh
swift test --disable-sandbox --package-path Packages/RiverDiaryCore
```

结果：**109 tests / 10 suites，0 失败**（新增 `SelfReportConsistencyTests` 11 项，其中包含上表所有正向、边界、否定、双否定、缺失数据与“只一句”断言）。

```sh
./scripts/test_macos_isolated.sh --disable-sandbox --filter SelfReportFactsBridgeTests
```

结果：**4 项通过，0 失败**：

- 管道 450 分钟优先于 `screen_h=9.0`，睡眠 4.2、步数 820、完成事项 3 项被正确映射；
- 管道不可用时回退到 `screen_h=7.5`；
- 缺失字段保持 nil，不用 0 冒充；
- 空白完成事项不计入。

完整 Mac 回归：

```sh
./scripts/test_macos_isolated.sh --disable-sandbox
```

结果：**495 项执行，0 failure，1 项环境跳过**（`DiskFullTests` 因沙箱无法挂载临时磁盘镜像；与上一块相同，未算作通过）。

iOS app 编译：`** BUILD SUCCEEDED **`。D 阶段门禁随后在同一提交上复跑，结果见第 6 节。

> 说明：规则测试验证的是输入到句子的映射，不是“真实用户看到后觉得被冒犯”的产品验收。语气、阈值和平台差异仍需真实日记样本与人工阅读。

## 4. 尚未验证 / 不能宣称

1. **没有真实日记语料误报率**：11 个 Core 用例是构造文本，不是用户样本；阈值 5 小时/1,500 步/6 小时/3 项没有经过统计校准。
2. **没有视觉截图**：Mac/iOS 都编译通过，入口代码也在对应视图里，但没有在真机/模拟器里实际走到“有矛盾数据”的那一天并截图；不能把编译通过当成 UI 验收。
3. **没有 VoiceOver 实机**：只加了合并标签和文案，未用辅助技术走查。
4. **iOS 屏幕自述覆盖有限**：iOS 没有系统屏幕总时长采集，只有导入的 `screen_h` 才可能触发屏幕规则；完成事项字段在 iOS 模型里不存在。
5. **不是“反自欺”完整能力**：只覆盖 4 类事实和有限短语；讽刺、反问、隐喻、跨天叙述、他人转述都不在规则内，可能漏报，也可能在极少数语境误报。

## 5. 下一步

1. 用 20–30 条真实（脱敏）日记做误报/漏报标注，再决定是否调整阈值；不因为“看起来聪明”而放宽。
2. 在 Mac 与 iPhone 各截一张有提示/无提示的对照图，补 VoiceOver 走查。
3. 若 PM 认为提示打扰，可增加“这一天不再提示”的本机偏好；本轮没有加，避免扩大范围。


## 6. D 阶段门禁

```sh
./scripts/release_gate.sh --d-phase --report /tmp/river-gate-block3-report.json
```

结果：**GATE PASSED (D 阶段)**，0 失败、0 未验证、1 步显式豁免（iOS 单测，T23 欠账），报告绑定提交 `2b7d2fe9b9a7b6ea912a92c69b7804e12b53c3eb`。

| 步骤 | 结果 |
|---|---|
| privacy-scan | PASS |
| python-node | PASS，# pass 41 |
| core-tests | PASS，109 tests / 10 suites |
| mac-tests | PASS，495 项执行，0 failure |
| server-tests | PASS，65 个顶层测试 |
| mac-tests-cover | PASS，495 项执行；1 项环境跳过：`DiskFullTests` 沙箱无法挂载临时磁盘镜像 |
| ios-test-build | PASS |
| ios-tests | EXEMPT，D 阶段豁免，T23 欠账 |
| build-privacy | PASS |

完整输出：[gate.log](evidence/2026-10-22/anti-self-deception/gate.log)，JSON：[gate-report.json](evidence/2026-10-22/anti-self-deception/gate-report.json)。这份门禁仍只证明编译、规则单测和既有回归，不证明真机上的语气/布局可接受。
