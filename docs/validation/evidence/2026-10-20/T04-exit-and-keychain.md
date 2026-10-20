# T04 退出与钥匙串故障：关库可解释、失败不留悬空绑定

日期：2026-10-20（Asia/Shanghai）
状态：**T04 本轮补了关库可解释性与登录失败回滚；停止全部服务、后台入口、Keychain 锁定与 iOS 退出关库仍待。**

## 1. 发现一：关闭数据库后写入静默失败

T02 让 Mac 在退出登录时 `v2Store.close()`。但 `V2Store.transaction()` 在数据库关闭时直接
`return false`，没有设置 `lastError`：

- 调用方拿不到原因，只能看到一次“没保存”；
- 界面若仍在（例如退出时开着的设置窗口）会显示一个没有解释的失败。

### 修复

`transaction` 在 `db == nil` 时写入：

> 数据库未打开：请先登录或完成资料认领。

### 测试

`macos/RiverDiaryMac/Tests/RiverDiaryMacTests/StoreCloseTests.swift`

1. 打开库、写入一条状态操作、关闭；
2. 关闭后读取返回空数组且不崩溃；
3. 关闭后写入返回 nil，且 `lastError` 给出“数据库未打开”；
4. `openIfNeeded()` 重开同一文件：旧数据仍在、错误清空。

## 2. 发现二：登录会话保存失败会留下悬空资料绑定

`acceptSignIn` 先写 `account-profile-binding-v1`（资料归属绑定），再保存会话。如果保存会话时
钥匙串写入失败：

- 登录确实失败了，`isSignedIn == false`；
- 但绑定已经落盘，于是**下一次用另一个账号登录会被 `local_profile_account_mismatch` 挡住**，
  而用户从未成功登录过第一个账号。

### 修复

保存会话失败时恢复登录前的绑定（没有旧值就删除），再抛出原错误并撤销未采用的令牌。

### 测试

`AccountSessionTests.testFailedSessionWriteDoesNotLeaveADanglingProfileBinding`

1. 让钥匙串写入会话失败，登录必须抛错；
2. 断言没有会话、也没有资料绑定；
3. 恢复钥匙串后同一账号可正常登录，绑定写入 `user-a`。

账号用例由 8 项增至 **9 项**。

## 3. 结果

- Core：**67 项 Swift Testing + 9 项 XCTest** 通过；
- macOS：**429 项通过**（新增 1 项关库用例，原 428 项）。

## 4. 仍未完成

- **停止全部服务**：退出时 Mac 已停采集/LAN/位置/提醒并关库，但没有端到端证据证明 AI 恢复任务、
  iCloud 同步、后台定时器全部停止；iOS 只停采集/同步/健康，未关库。
- **旧回写**：账号层的 late-401/late-200 已测；写库层“退出后旧任务回写被拒”没有专门用例。
- **Keychain 锁定**：只测了写入/删除失败，没有测钥匙串被锁定后读取失败与恢复。
- **后台入口**：macOS 无 AppIntent；iOS Shortcuts（`LogAppActivityIntent`）与后台刷新仍未逐项核对。
- **界面层**：关库错误的展示未做界面断言。
