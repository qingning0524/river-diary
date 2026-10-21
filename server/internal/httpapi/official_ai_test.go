package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestOfficialAIQuotaAndProviderProxy(t *testing.T) {
	api, db, _ := testAPI(t)
	ctx := context.Background()

	var providerHits atomic.Int64
	var lastBody string
	var lastAuth string
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		providerHits.Add(1)
		lastAuth = r.Header.Get("Authorization")
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		encoded, _ := json.Marshal(body)
		lastBody = string(encoded)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-test","model":"server-model","choices":[{"index":0,"message":{"role":"assistant","content":"你好"}}],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}`))
	}))
	defer provider.Close()
	api.cfg.OfficialAIBaseURL = provider.URL
	api.cfg.OfficialAIAPIKey = "server-secret"
	api.cfg.OfficialAIModel = "server-model"
	api.cfg.OfficialAIMonthlyTokenLimit = 20

	srv := httptest.NewServer(api.Handler())
	defer srv.Close()
	client := srv.Client()

	// 创建邮箱账号与登录会话。
	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var uid, iid, deviceID string
	if err = tx.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `INSERT INTO identities(user_id,provider,subject,email_canonical,email_display,verified_at) VALUES($1,'email',$2,$2,$2,now()) RETURNING id::text`, uid, "ai@example.test").Scan(&iid); err != nil {
		t.Fatal(err)
	}
	deviceID, err = upsertDevice(ctx, tx, uid, "650e8400-e29b-41d4-a716-446655440701", "macos", "fixture mac")
	if err != nil {
		t.Fatal(err)
	}
	session, err := api.createSession(ctx, tx, uid, iid, deviceID, "650e8400-e29b-41d4-a716-446655440701", false)
	if err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	status, body := doJSON(t, client, http.MethodGet, srv.URL+"/v1/ai/quota", "", session.AccessToken, nil)
	if status != 200 || !strings.Contains(string(body), `"enabled":true`) || !strings.Contains(string(body), `"remaining_tokens":20`) {
		t.Fatalf("quota status=%d body=%s", status, body)
	}
	status, _ = doJSON(t, client, http.MethodPost, srv.URL+"/v1/ai/chat", "", "", map[string]any{
		"messages":   []map[string]string{{"role": "user", "content": "测试"}},
		"max_tokens": 5,
	})
	if status != 401 {
		t.Fatalf("unauthenticated chat status=%d", status)
	}

	status, body = doJSON(t, client, http.MethodPost, srv.URL+"/v1/ai/chat", "", session.AccessToken, map[string]any{
		"messages":   []map[string]string{{"role": "user", "content": "你好"}},
		"max_tokens": 5,
	})
	if status != 200 || !strings.Contains(string(body), `"你好"`) || providerHits.Load() != 1 {
		t.Fatalf("chat status=%d body=%s hits=%d", status, body, providerHits.Load())
	}
	if lastAuth != "Bearer server-secret" || !strings.Contains(lastBody, `"model":"server-model"`) || !strings.Contains(lastBody, `"stream":false`) {
		t.Fatalf("provider request auth=%q body=%s", lastAuth, lastBody)
	}
	status, body = doJSON(t, client, http.MethodGet, srv.URL+"/v1/ai/quota", "", session.AccessToken, nil)
	if status != 200 || !strings.Contains(string(body), `"used_tokens":17`) || !strings.Contains(string(body), `"remaining_tokens":3`) {
		t.Fatalf("quota after status=%d body=%s", status, body)
	}
	status, body = doJSON(t, client, http.MethodPost, srv.URL+"/v1/ai/chat", "", session.AccessToken, map[string]any{
		"messages":   []map[string]string{{"role": "user", "content": "再来一次"}},
		"max_tokens": 5,
	})
	if status != 429 || !strings.Contains(string(body), "official_quota_exhausted") || providerHits.Load() != 1 {
		t.Fatalf("over-quota status=%d body=%s hits=%d", status, body, providerHits.Load())
	}

	// Provider 未配置时 fail closed。
	api.cfg.OfficialAIAPIKey = ""
	status, body = doJSON(t, client, http.MethodGet, srv.URL+"/v1/ai/quota", "", session.AccessToken, nil)
	if status != 200 || !strings.Contains(string(body), `"enabled":false`) {
		t.Fatalf("disabled quota status=%d body=%s", status, body)
	}
	status, body = doJSON(t, client, http.MethodPost, srv.URL+"/v1/ai/chat", "", session.AccessToken, map[string]any{
		"messages":   []map[string]string{{"role": "user", "content": "你好"}},
		"max_tokens": 5,
	})
	if status != 503 || !strings.Contains(string(body), "official_ai_unavailable") {
		t.Fatalf("disabled chat status=%d body=%s", status, body)
	}
}
