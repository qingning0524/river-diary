package httpapi

import (
	"context"
	"flowriver/server/internal/jobs"
	"flowriver/server/internal/mailer"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPublicFeedbackRetriesAreIdempotentAndUnicodeAgentsAreSafe(t *testing.T) {
	api, db, _ := testAPI(t)
	call := func(key, body, agent string) *httptest.ResponseRecorder {
		r := httptest.NewRequest("POST", "http://test/v1/feedback", strings.NewReader(body))
		r.RemoteAddr = "203.0.113.9:1234"
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Idempotency-Key", key)
		r.Header.Set("User-Agent", agent)
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		return w
	}
	body := `{"contact_email":"qa@example.test","subject":"retry","body":"同一条反馈重试后不应重复保存"}`
	for i := 0; i < 6; i++ {
		w := call("feedback-retry-123456", body, strings.Repeat("x", 250)+strings.Repeat("中", 60))
		if w.Code != 202 {
			t.Fatalf("feedback retry status=%d body=%s", w.Code, w.Body.String())
		}
	}
	var count int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM feedback_messages`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("duplicate feedback count=%d error=%v", count, err)
	}
	if w := call("feedback-retry-123456", `{"body":"改动后的反馈不能复用原始请求标识"}`, "fixture"); w.Code != 409 {
		t.Fatalf("changed body must reject reused key: %d", w.Code)
	}
}

type uncertainOTPSender struct{}

func (uncertainOTPSender) SendOTP(context.Context, string, string) error {
	return mailer.ErrDeliveryUnconfirmed
}
func TestOTPTasksPreserveRealTerminalStatuses(t *testing.T) {
	for _, kind := range []string{"expired", "inactive", "unconfirmed"} {
		t.Run(kind, func(t *testing.T) {
			api, db, sender := testAPI(t)
			server := httptest.NewServer(api.Handler())
			defer server.Close()
			status, _ := doJSON(t, server.Client(), http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "fixture@example.test"})
			if status != 202 {
				t.Fatal(status)
			}
			var id string
			if err := db.QueryRow(context.Background(), `SELECT id::text FROM outbox_jobs WHERE kind='email_otp'`).Scan(&id); err != nil {
				t.Fatal(err)
			}
			worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
			expected := ""
			switch kind {
			case "expired":
				expected = "job_expired"
				db.Exec(context.Background(), `UPDATE outbox_jobs SET created_at=now()-interval '1 hour',expires_at=now()-interval '1 minute'`)
			case "inactive":
				expected = "challenge_inactive"
				db.Exec(context.Background(), `UPDATE auth_challenges SET consumed_at=now()`)
			case "unconfirmed":
				expected = "email_delivery_unconfirmed"
				worker.Sender = uncertainOTPSender{}
			}
			worked, err := worker.DeliverOne(context.Background())
			if err != nil || !worked {
				t.Fatal(err)
			}
			var code string
			var finished bool
			if err = db.QueryRow(context.Background(), `SELECT COALESCE(last_error_code,''),completed_at IS NOT NULL FROM outbox_jobs WHERE id=$1`, id).Scan(&code, &finished); err != nil || !finished || code != expected {
				t.Fatalf("task falsely marked delivered or retried: code=%q done=%v error=%v", code, finished, err)
			}
		})
	}
}
func TestOTPMetadataRetentionPreservesThirtyDayStatistics(t *testing.T) {
	api, db, sender := testAPI(t)
	server := httptest.NewServer(api.Handler())
	defer server.Close()
	status, _ := doJSON(t, server.Client(), "POST", server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "history@example.test"})
	if status != 202 {
		t.Fatal(status)
	}
	worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if _, err := worker.DeliverOne(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(context.Background(), `UPDATE outbox_jobs SET created_at=now()-interval '2 days',completed_at=now()-interval '2 days',expires_at=now()-interval '2 days'+interval '10 minutes'`); err != nil {
		t.Fatal(err)
	}
	if err := worker.Cleanup(context.Background()); err != nil {
		t.Fatal(err)
	}
	var count int
	var payload int
	if err := db.QueryRow(context.Background(), `SELECT count(*),COALESCE(max(octet_length(payload_ciphertext)),0) FROM outbox_jobs`).Scan(&count, &payload); err != nil || count != 1 || payload != 0 {
		t.Fatalf("metadata retention or payload erasure broken: count=%d payload=%d err=%v", count, payload, err)
	}
}
