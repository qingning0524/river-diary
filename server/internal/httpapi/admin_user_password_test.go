package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"flowriver/server/internal/adminapi"
	"flowriver/server/internal/config"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5/pgxpool"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func verifyAdminPasswordReset(t *testing.T, db *pgxpool.Pool, userID string) {
	t.Helper()
	ctx := context.Background()
	cfg := config.Config{AdminEnabled: true, AdminOrigin: "https://admin.test", AdminTOTPEncryptionKey: bytes.Repeat([]byte{1}, 32), AdminAuditHMACKey: bytes.Repeat([]byte{2}, 32)}
	api, err := adminapi.New(db, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	if err != nil {
		t.Fatal(err)
	}
	var adminID string
	if err = db.QueryRow(ctx, `INSERT INTO admin_accounts(username,password_hash,totp_secret_ciphertext) VALUES('password-fixture','fixture',decode('01','hex')) RETURNING id::text`).Scan(&adminID); err != nil {
		t.Fatal(err)
	}
	token := "fixture-session-token-32-characters-long"
	csrf := "fixture-csrf-token"
	if _, err = db.Exec(ctx, `INSERT INTO admin_sessions(token_mac,admin_id,csrf_mac,idle_expires_at,absolute_expires_at,ip_mac) VALUES($1,$2,$3,now()+interval '10 minutes',now()+interval '1 hour',$4)`, secure.Digest(token), adminID, secure.Digest(csrf), secure.MAC(cfg.AdminAuditHMACKey, "admin-request-ip", "127.0.0.1")); err != nil {
		t.Fatal(err)
	}
	call := func(method, path, key string, withCSRF bool) (int, []byte) {
		raw, _ := json.Marshal(map[string]string{"new_password": "administrator recovery phrase 2026", "reason_code": "user_request"})
		r := httptest.NewRequest(method, "https://admin.test/admin-api/v1"+path, bytes.NewReader(raw))
		r.RemoteAddr = "127.0.0.1:12345"
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Idempotency-Key", key)
		r.Header.Set("Origin", cfg.AdminOrigin)
		r.AddCookie(&http.Cookie{Name: "__Host-flowriver-admin", Value: token})
		if withCSRF {
			r.AddCookie(&http.Cookie{Name: "__Host-flowriver-admin-csrf", Value: csrf})
			r.Header.Set("X-CSRF-Token", csrf)
		}
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		return w.Code, w.Body.Bytes()
	}
	path := "/users/" + userID + "/password/reset"
	if s, _ := call("POST", path, "admin-reset-1", false); s != 403 {
		t.Fatal("CSRF not enforced")
	}
	if s, b := call("POST", path, "admin-reset-1", true); s != 403 || !bytes.Contains(b, []byte("recent_mfa_required")) {
		t.Fatal("recent MFA not enforced")
	}
	if _, err = db.Exec(ctx, `UPDATE admin_sessions SET reauthenticated_until=now()+interval '5 minutes' WHERE admin_id=$1`, adminID); err != nil {
		t.Fatal(err)
	}
	s, first := call("POST", path, "admin-reset-1", true)
	if s != 200 {
		t.Fatalf("reset %d %s", s, first)
	}
	s, retry := call("POST", path, "admin-reset-1", true)
	if s != 200 {
		t.Fatalf("retry %d %s", s, retry)
	}
	var a, b map[string]any
	_ = json.Unmarshal(first, &a)
	_ = json.Unmarshal(retry, &b)
	if a["status"] != b["status"] {
		t.Fatal("replay response changed")
	}
	var hash string
	var auditCount int
	if err = db.QueryRow(ctx, `SELECT password_hash FROM user_password_credentials WHERE user_id=$1`, userID).Scan(&hash); err != nil || !secure.VerifyUserPassword(hash, "administrator recovery phrase 2026") {
		t.Fatal("new password not set")
	}
	if err = db.QueryRow(ctx, `SELECT count(*) FROM admin_audit_events WHERE action='admin.user.password.reset' AND target_id=$1`, userID).Scan(&auditCount); err != nil || auditCount != 1 {
		t.Fatal("reset audit missing or duplicated")
	}
	s, detail := call("GET", "/users/"+userID, "", true)
	if s != 200 || !bytes.Contains(detail, []byte(`"password_enabled":true`)) || bytes.Contains(detail, []byte("argon2id")) {
		t.Fatalf("status or secret exposure %d %s", s, detail)
	}
}
