# 官方 AI 试用额度（服务端代理）

状态：**服务端已实现并测试；生产未配置 Provider Key，客户端尚未接入。** 当前产品仍以 BYOK 为主。

## 能力

- `GET /v1/ai/quota`：返回当前账号本月已用/剩余 token；服务端未配置时 `enabled=false`。
- `POST /v1/ai/chat`：OpenAI-compatible chat 代理；服务端持有 Provider Key，客户端不接触官方 Key。
- 每月按账号累计 `input_tokens + output_tokens`，默认上限 200,000；超过返回 `429 official_quota_exhausted`。
- 请求前用估算值 + `max_tokens` 做预留检查；响应后按 Provider `usage` 记账。
- 不记录消息正文；只记录 token 数、请求数和时间。
- Provider 未配置返回 `503 official_ai_unavailable`；Provider 失败返回 `502`，不扣额度。

## 配置

```ini
OFFICIAL_AI_BASE_URL=https://api.deepseek.com
OFFICIAL_AI_API_KEY=REPLACE_PROVIDER_KEY
OFFICIAL_AI_MODEL=deepseek-chat
OFFICIAL_AI_MONTHLY_TOKEN_LIMIT=200000
```

- `OFFICIAL_AI_BASE_URL` 可以是 base（自动补 `/chat/completions`）或完整接口地址。
- Provider Key 只放服务器环境；不要写进客户端、仓库或备份明文。
- 没有 Provider Key 时保持端点关闭，不要给用户显示“官方额度可用”。

## 数据表

`ai_usage`（migration `0013_official_ai_usage.sql`）：

- `user_id`, `month` 主键；
- `requests`, `input_tokens`, `output_tokens`, `updated_at`；
- 删除账号级联删除。

## 测试

```sh
./scripts/test_server_isolated.sh
```

`TestOfficialAIQuotaAndProviderProxy` 使用本地 fake provider 验证：认证、配额累计、429 预留拒绝、Provider Key 只出现在服务端请求、未配置时 503。

## 仍需完成

- 客户端选择官方额度、展示剩余额度、错误回退到 BYOK。
- 生产 Provider Key、预算与全局上限。
- 成本看板/滥用监控与用户同意文案。
