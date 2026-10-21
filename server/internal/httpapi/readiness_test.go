package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

type readinessBody struct {
	Status                        string   `json:"status"`
	Database                      string   `json:"database"`
	MailFailures5m                int64    `json:"mail_failures_5m"`
	OutboxUnfinished              int64    `json:"outbox_unfinished"`
	OutboxOldestUnfinishedSeconds int64    `json:"outbox_oldest_unfinished_seconds"`
	DegradedReasons               []string `json:"degraded_reasons"`
}

func callReadiness(t *testing.T, api *API) (int, readinessBody) {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, "http://test/health/ready", nil)
	w := httptest.NewRecorder()
	api.Handler().ServeHTTP(w, r)
	var body readinessBody
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode readiness body %q: %v", w.Body.String(), err)
	}
	return w.Code, body
}

func TestReadinessReportsHealthyMailQueue(t *testing.T) {
	api, db, _ := testAPI(t)
	if _, err := db.Exec(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,completed_at,expires_at)
		VALUES('email_otp',decode('00','hex'),now(),now()+interval '10 minutes')`); err != nil {
		t.Fatal(err)
	}
	status, body := callReadiness(t, api)
	if status != http.StatusOK || body.Status != "ready" || body.Database != "ok" {
		t.Fatalf("healthy readiness status=%d body=%+v", status, body)
	}
	if body.MailFailures5m != 0 || body.OutboxUnfinished != 0 || body.OutboxOldestUnfinishedSeconds != 0 || len(body.DegradedReasons) != 0 {
		t.Fatalf("healthy metrics = %+v", body)
	}
}

func TestReadinessDegradesOnRecentMailFailureWithoutHTTP500(t *testing.T) {
	api, db, _ := testAPI(t)
	if _, err := db.Exec(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,completed_at,expires_at,last_error_code)
		VALUES('email_otp',decode('00','hex'),now(),now()+interval '10 minutes','email_delivery_failed')`); err != nil {
		t.Fatal(err)
	}
	status, body := callReadiness(t, api)
	if status != http.StatusOK {
		t.Fatalf("degraded readiness must stay HTTP 200, got %d: %+v", status, body)
	}
	if body.Status != "degraded" || body.MailFailures5m != 1 {
		t.Fatalf("degraded metrics = %+v", body)
	}
	if len(body.DegradedReasons) != 1 || body.DegradedReasons[0] != "mail_failures_5m" {
		t.Fatalf("degraded reasons = %v", body.DegradedReasons)
	}
}

func TestReadinessDegradesOnStaleOutboxTask(t *testing.T) {
	api, db, _ := testAPI(t)
	if _, err := db.Exec(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,created_at,expires_at)
		VALUES('email_otp',decode('00','hex'),now()-interval '11 minutes',now()+interval '10 minutes')`); err != nil {
		t.Fatal(err)
	}
	status, body := callReadiness(t, api)
	if status != http.StatusOK {
		t.Fatalf("degraded readiness must stay HTTP 200, got %d: %+v", status, body)
	}
	if body.Status != "degraded" || body.OutboxUnfinished != 1 || body.OutboxOldestUnfinishedSeconds < 600 {
		t.Fatalf("stale outbox metrics = %+v", body)
	}
	found := false
	for _, reason := range body.DegradedReasons {
		if reason == "outbox_oldest_unfinished_seconds" {
			found = true
		}
	}
	if !found {
		t.Fatalf("stale outbox reasons = %v", body.DegradedReasons)
	}
}

func TestReadinessIgnoresMailFailuresOlderThanFiveMinutes(t *testing.T) {
	api, db, _ := testAPI(t)
	if _, err := db.Exec(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,completed_at,expires_at,last_error_code)
		VALUES('email_otp',decode('00','hex'),now()-interval '6 minutes',now()+interval '10 minutes','email_delivery_failed')`); err != nil {
		t.Fatal(err)
	}
	status, body := callReadiness(t, api)
	if status != http.StatusOK || body.Status != "ready" || body.MailFailures5m != 0 {
		t.Fatalf("old failure must not degrade readiness: status=%d body=%+v", status, body)
	}
}
