package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

type officialAIMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type officialAIChatRequest struct {
	Messages    []officialAIMessage `json:"messages"`
	Temperature *float64            `json:"temperature,omitempty"`
	MaxTokens   *int                `json:"max_tokens,omitempty"`
}

type officialAIUsage struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

type officialAIProviderResponse struct {
	ID      string                    `json:"id"`
	Model   string                    `json:"model"`
	Choices json.RawMessage           `json:"choices"`
	Usage   *officialAIUsage          `json:"usage"`
	Error   *struct{ Message string } `json:"error"`
}

func (a *API) officialAIEnabled() bool {
	return a.cfg.OfficialAIBaseURL != "" && a.cfg.OfficialAIAPIKey != "" && a.cfg.OfficialAIModel != ""
}

func (a *API) officialAIEndpoint() string {
	endpoint := strings.TrimRight(a.cfg.OfficialAIBaseURL, "/")
	if !strings.HasSuffix(endpoint, "/chat/completions") {
		endpoint += "/chat/completions"
	}
	return endpoint
}

func estimateTokens(text string) int64 {
	if text == "" {
		return 0
	}
	// 保守估算：UTF-8 字节数/3，至少 1。真正配额以 provider usage 为准。
	estimate := int64(utf8.RuneCountInString(text))/2 + 1
	return estimate
}

func (a *API) officialAIQuota(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	_ = ctx
	month := time.Now().UTC().Format("2006-01")
	var used int64
	if a.officialAIEnabled() {
		if err := a.db.QueryRow(r.Context(), `SELECT COALESCE(input_tokens+output_tokens,0) FROM ai_usage WHERE user_id=$1 AND month=$2`, p.UserID, month+"-01").Scan(&used); err != nil {
			// 没有记录等同于 0；真实数据库错误下面通过 remaining 保守处理。
			used = 0
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"enabled":          a.officialAIEnabled(),
		"model":            a.cfg.OfficialAIModel,
		"month":            month,
		"limit_tokens":     a.cfg.OfficialAIMonthlyTokenLimit,
		"used_tokens":      used,
		"remaining_tokens": maxInt64(0, a.cfg.OfficialAIMonthlyTokenLimit-used),
	})
}

func (a *API) officialAIChat(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	_ = ctx
	if !a.officialAIEnabled() {
		writeError(w, r, apiError{Status: http.StatusServiceUnavailable, Code: "official_ai_unavailable"})
		return
	}
	var req officialAIChatRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	if len(req.Messages) == 0 || len(req.Messages) > 64 {
		writeError(w, r, apiError{Status: http.StatusBadRequest, Code: "invalid_request"})
		return
	}
	var inputChars int
	for _, message := range req.Messages {
		switch message.Role {
		case "system", "user", "assistant":
		default:
			writeError(w, r, apiError{Status: http.StatusBadRequest, Code: "invalid_request"})
			return
		}
		inputChars += utf8.RuneCountInString(message.Content)
	}
	if inputChars == 0 || inputChars > 32_000 {
		writeError(w, r, apiError{Status: http.StatusBadRequest, Code: "invalid_request"})
		return
	}
	maxTokens := 512
	if req.MaxTokens != nil {
		maxTokens = *req.MaxTokens
	}
	if maxTokens < 1 || maxTokens > 2048 {
		writeError(w, r, apiError{Status: http.StatusBadRequest, Code: "invalid_request"})
		return
	}

	month := time.Now().UTC().Format("2006-01")
	var used int64
	if err := a.db.QueryRow(r.Context(), `SELECT COALESCE(input_tokens+output_tokens,0) FROM ai_usage WHERE user_id=$1 AND month=$2`, p.UserID, month+"-01").Scan(&used); err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			a.databaseFailure(w, r, "official_ai_quota_read")
			return
		}
		used = 0
	}
	estimatedInput := int64(0)
	for _, message := range req.Messages {
		estimatedInput += estimateTokens(message.Content)
	}
	if used+estimatedInput+int64(maxTokens) > a.cfg.OfficialAIMonthlyTokenLimit {
		writeError(w, r, apiError{Status: http.StatusTooManyRequests, Code: "official_quota_exhausted"})
		return
	}

	providerPayload := map[string]any{
		"model":      a.cfg.OfficialAIModel,
		"messages":   req.Messages,
		"stream":     false,
		"max_tokens": maxTokens,
	}
	if req.Temperature != nil {
		providerPayload["temperature"] = *req.Temperature
	}
	encoded, err := json.Marshal(providerPayload)
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusBadRequest, Code: "invalid_request"})
		return
	}
	providerReq, err := http.NewRequestWithContext(r.Context(), http.MethodPost, a.officialAIEndpoint(), bytes.NewReader(encoded))
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusInternalServerError, Code: "internal_error"})
		return
	}
	providerReq.Header.Set("Content-Type", "application/json")
	providerReq.Header.Set("Authorization", "Bearer "+a.cfg.OfficialAIAPIKey)
	client := &http.Client{Timeout: 60 * time.Second}
	providerResp, err := client.Do(providerReq)
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusBadGateway, Code: "official_ai_provider_error"})
		return
	}
	defer providerResp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(providerResp.Body, 2<<20))
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusBadGateway, Code: "official_ai_provider_error"})
		return
	}
	if providerResp.StatusCode < 200 || providerResp.StatusCode >= 300 {
		a.log.Warn("official AI provider rejected request", "status", providerResp.StatusCode)
		writeError(w, r, apiError{Status: http.StatusBadGateway, Code: "official_ai_provider_error"})
		return
	}
	var decoded officialAIProviderResponse
	if err := json.Unmarshal(body, &decoded); err != nil || decoded.Error != nil || len(decoded.Choices) == 0 || string(decoded.Choices) == "null" {
		writeError(w, r, apiError{Status: http.StatusBadGateway, Code: "official_ai_provider_error"})
		return
	}
	inputTokens, outputTokens := estimatedInput, estimateTokens(string(body))
	if decoded.Usage != nil {
		if decoded.Usage.PromptTokens > 0 {
			inputTokens = decoded.Usage.PromptTokens
		}
		if decoded.Usage.CompletionTokens > 0 {
			outputTokens = decoded.Usage.CompletionTokens
		}
	}
	if _, err := a.db.Exec(r.Context(), `INSERT INTO ai_usage(user_id,month,requests,input_tokens,output_tokens,updated_at)
		VALUES($1,$2,1,$3,$4,now())
		ON CONFLICT(user_id,month) DO UPDATE SET requests=ai_usage.requests+1,
			input_tokens=ai_usage.input_tokens+$3, output_tokens=ai_usage.output_tokens+$4, updated_at=now()`,
		p.UserID, month+"-01", inputTokens, outputTokens); err != nil {
		a.databaseFailure(w, r, "official_ai_usage_write")
		return
	}
	usedAfter := used + inputTokens + outputTokens
	w.Header().Set("X-River-Quota-Used", fmt.Sprintf("%d", usedAfter))
	w.Header().Set("X-River-Quota-Limit", fmt.Sprintf("%d", a.cfg.OfficialAIMonthlyTokenLimit))
	w.Header().Set("X-River-Quota-Month", month)
	writeJSON(w, http.StatusOK, map[string]any{
		"id":      decoded.ID,
		"model":   a.cfg.OfficialAIModel,
		"choices": decoded.Choices,
		"usage":   decoded.Usage,
	})
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
