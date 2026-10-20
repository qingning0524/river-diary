# T03 账号刷新门禁：请求 ID 跨重启与旧成功隔离

日期：2026-10-20（Asia/Shanghai）
状态：**T03 本轮可验证部分已补齐；资料上下文集成仍依赖 T02，真实账号服务旅程未做。**

## 1. 原有基础

`RiverAccountSessionStore` 已实现：

- 同一时刻只允许一个刷新任务（`refreshTask` 合并并发请求）；
- 每次登录/退出递增 `generation`，迟到的刷新、权益、401 都要先核对代际；
- 退出时只持久化撤销令牌，重启后 `retryPendingSignOuts()` 继续撤销；
- 旧 401 不能清掉更新的登录；
- 凭证删除失败不能靠重启「复活」已退出会话。

本轮补的是两个此前没有自动证据的行为。

## 2. 新增验证

文件：`Packages/RiverDiaryCore/Tests/RiverDiaryCoreTests/AccountSessionTests.swift`

### 重启复用刷新请求 ID

`testRestartReusesThePersistedRefreshRequestID`

1. 会话过期后发起刷新，请求发出前就把 `pendingRefreshRequestID` 写进会话与钥匙串；
2. 断言落盘的会话确实带着这个 ID；
3. 用同一份钥匙串构造「重启后」的 store，再次刷新；
4. 断言第二次请求的 `Idempotency-Key` 与第一次完全相同，刷新成功后该字段清空。

这保证强杀/重启后不会用一个新 ID 重放同一个刷新，避免服务端把它当成两次独立请求。

### 旧的成功响应不能覆盖新登录

`testLateSuccessfulRefreshCannotOverwriteANewerLogin`

1. 发起一次会被延迟的刷新；
2. 在响应回来之前退出并重新用密码登录（新会话 `login-access`）；
3. 让旧刷新以 **200** 返回新令牌；
4. 断言当前会话仍是新登录，且未被旧响应改写；
5. 旧响应携带的、未被采用的撤销令牌会进入撤销队列并触发登出请求（`logoutCount ≥ 1`）。

原先只有「旧 401」用例，缺了更危险的「旧 200」。

## 3. 结果

`swift test --package-path Packages/RiverDiaryCore`：

- Swift Testing **54 项通过**（3 个 suite）；
- XCTest 账号用例 **8 项通过**（原 6 + 新增 2）。

合计 62 项，0 失败。

## 4. 仍未完成

- 资料上下文（T02）与刷新/退出队列的联调：本轮只验证账号存储本身，没有把 T02 的延迟开库/关库与刷新失败串起来做旅程级证据。
- 真实账号服务：全部用例使用进程内模拟 transport；刷新合并、401、撤销在真实网络与真实服务端的表现仍需联调。
- Keychain 故障注入只覆盖「删除会话失败」，未覆盖写入失败与锁定。
