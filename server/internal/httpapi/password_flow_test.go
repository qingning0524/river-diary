package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"flowriver/server/internal/jobs"
	"flowriver/server/internal/secure"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestUserPasswordSetLoginResetAndReplay(t *testing.T) {
	api, db, sender := testAPI(t)
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()
	client := srv.Client()
	post := func(path, key, token string, body any) (int, []byte) {
		return doJSON(t, client, http.MethodPost, srv.URL+"/v1"+path, key, token, body)
	}
	get := func(path, token string) (int, []byte) {
		return doJSON(t, client, http.MethodGet, srv.URL+"/v1"+path, "", token, nil)
	}
	deliver := func() {
		t.Helper()
		worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
		worked, e := worker.DeliverOne(context.Background())
		if e != nil || !worked {
			t.Fatalf("mail fixture failed: %v", e)
		}
	}
	challenge := func(path, email string) string {
		t.Helper()
		s, b := post(path, "", "", map[string]string{"email": email})
		if s != 202 {
			t.Fatalf("challenge status %d: %s", s, b)
		}
		var v struct {
			ID string `json:"challenge_id"`
		}
		if json.Unmarshal(b, &v) != nil || v.ID == "" {
			t.Fatal("missing challenge")
		}
		return v.ID
	}
	parseTokens := func(s int, b []byte) TokenResponse {
		t.Helper()
		if s != 200 {
			t.Fatalf("token response status=%d: %s", s, b)
		}
		var v TokenResponse
		if e := json.Unmarshal(b, &v); e != nil || v.AccessToken == "" {
			t.Fatal("missing tokens")
		}
		return v
	}
	email := "PasswordOwner@Example.org"
	instance := "650e8400-e29b-41d4-a716-446655440201"
	loginChallenge := challenge("/auth/email/start", email)
	deliver()
	_, code := sender.value()
	s, b := post("/auth/email/verify", "password-signup-1", "", map[string]any{"challenge_id": loginChallenge, "code": code, "client_instance_id": instance, "platform": "ios", "accept_terms": true})
	original := parseTokens(s, b)
	pass := "a quiet river phrase 2026"
	resetBody := map[string]any{"challenge_id": loginChallenge, "code": code, "new_password": pass, "client_instance_id": instance, "platform": "ios", "device_name": "test phone"}
	s, _ = post("/auth/password/reset/complete", "wrong-purpose-1", "", resetBody)
	if s != 401 {
		t.Fatalf("login challenge used to change a password: %d", s)
	}
	loginBody := map[string]any{"email": email, "password": pass, "client_instance_id": instance, "platform": "ios", "device_name": "test phone"}
	s, b = post("/auth/password/login", "not-configured-1", "", loginBody)
	if s != 401 || !bytes.Contains(b, []byte("invalid_credentials")) {
		t.Fatal("unconfigured password must be generic")
	}
	resetChallenge := challenge("/auth/password/reset/start", email)
	deliver()
	_, code = sender.value()
	resetBody["challenge_id"] = resetChallenge
	resetBody["code"] = code
	resetBody["new_password"] = "short"
	s, _ = post("/auth/password/reset/complete", "weak-password-1", "", resetBody)
	if s != 400 {
		t.Fatal("weak password accepted")
	}
	resetBody["new_password"] = pass
	wrong := "00000000"
	if wrong == code {
		wrong = "00000001"
	}
	resetBody["code"] = wrong
	s, _ = post("/auth/password/reset/complete", "wrong-reset-code-1", "", resetBody)
	if s != 401 {
		t.Fatal("bad reset proof accepted")
	}
	resetBody["code"] = code
	s, first := post("/auth/password/reset/complete", "set-password-1", "", resetBody)
	set := parseTokens(s, first)
	s, retry := post("/auth/password/reset/complete", "set-password-1", "", resetBody)
	if s != 200 || !bytes.Equal(first, retry) {
		t.Fatal("reset retry did not return same session")
	}
	s, _ = post("/auth/password/reset/complete", "set-password-replay-1", "", resetBody)
	if s != 401 {
		t.Fatal("single-use reset challenge replay accepted")
	}
	s, _ = get("/me", original.AccessToken)
	if s != 401 {
		t.Fatal("prior session survived password setting")
	}
	s, b = get("/me/password", set.AccessToken)
	if s != 200 || !bytes.Contains(b, []byte(`"password_enabled":true`)) {
		t.Fatalf("password status incorrect %d %s", s, b)
	}
	var hash string
	if e := db.QueryRow(context.Background(), `SELECT password_hash FROM user_password_credentials WHERE user_id=$1`, set.User.ID).Scan(&hash); e != nil || !bytes.HasPrefix([]byte(hash), []byte("argon2id$")) || bytes.Contains([]byte(hash), []byte(pass)) {
		t.Fatal("credential not stored as hash")
	}
	loginBody["password"] = "another incorrect password"
	s, b = post("/auth/password/login", "wrong-password-1", "", loginBody)
	if s != 401 || !bytes.Contains(b, []byte("invalid_credentials")) {
		t.Fatal("bad password response must be generic")
	}
	loginBody["email"] = "missing@example.org"
	s, b = post("/auth/password/login", "missing-user-1", "", loginBody)
	if s != 401 || !bytes.Contains(b, []byte("invalid_credentials")) {
		t.Fatal("unknown user response differs")
	}
	loginBody["email"] = email
	loginBody["password"] = pass
	s, first = post("/auth/password/login", "password-success-1", "", loginBody)
	signed := parseTokens(s, first)
	s, retry = post("/auth/password/login", "password-success-1", "", loginBody)
	if s != 200 || !bytes.Equal(first, retry) {
		t.Fatal("login retry did not return same session")
	}
	loginBody["password"] = pass + "x"
	s, _ = post("/auth/password/login", "password-success-1", "", loginBody)
	if s != 409 {
		t.Fatal("idempotency key reuse with different password accepted")
	}
	loginBody["password"] = pass
	resetChallenge = challenge("/auth/password/reset/start", email)
	deliver()
	_, code = sender.value()
	// A second mailbox proof issued at the same credential version must become stale.
	staleID := "650e8400-e29b-41d4-a716-446655440299"
	if _, e := db.Exec(context.Background(), `INSERT INTO auth_challenges(id,purpose,email_canonical,email_display,user_id,password_version,secret_mac,expires_at) SELECT $1,purpose,email_canonical,email_display,user_id,password_version,$2,expires_at FROM auth_challenges WHERE id=$3`, staleID, secure.MAC(api.authMAC, "email-otp-v1", staleID, code), resetChallenge); e != nil {
		t.Fatal(e)
	}
	newPass := "another calm river phrase 2026"
	resetBody["challenge_id"] = resetChallenge
	resetBody["code"] = code
	resetBody["new_password"] = newPass
	s, b = post("/auth/password/reset/complete", "reset-password-2", "", resetBody)
	reset := parseTokens(s, b)
	resetBody["challenge_id"] = staleID
	s, _ = post("/auth/password/reset/complete", "stale-proof-2", "", resetBody)
	if s != 401 {
		t.Fatal("previous credential version proof survived reset")
	}
	resetBody["challenge_id"] = resetChallenge
	s, _ = get("/me", signed.AccessToken)
	if s != 401 {
		t.Fatal("existing session survived reset")
	}
	s, _ = post("/auth/password/login", "old-password-2", "", loginBody)
	if s != 401 {
		t.Fatal("old password survived reset")
	}
	loginBody["password"] = newPass
	s, b = post("/auth/password/login", "new-password-2", "", loginBody)
	_ = parseTokens(s, b)
	verifyAdminPasswordReset(t, db, reset.User.ID)
	s, _ = post("/auth/password/login", "admin-reset-old-1", "", loginBody)
	if s != 401 {
		t.Fatal("prior password survived administrator reset")
	}
	loginBody["password"] = "administrator recovery phrase 2026"
	s, b = post("/auth/password/login", "admin-reset-new-1", "", loginBody)
	_ = parseTokens(s, b)
	// Revoking the email identity also blocks its password, without deleting the user.
	if _, e := db.Exec(context.Background(), `UPDATE identities SET status='revoked' WHERE provider='email' AND user_id=$1`, reset.User.ID); e != nil {
		t.Fatal(e)
	}
	s, _ = post("/auth/password/login", "revoked-email-1", "", loginBody)
	if s != 401 {
		t.Fatal("revoked email authenticated")
	}
	if _, e := db.Exec(context.Background(), `UPDATE identities SET status='active' WHERE provider='email' AND user_id=$1`, reset.User.ID); e != nil {
		t.Fatal(e)
	}
	// Disabled users cannot authenticate even with a valid password.
	if _, e := db.Exec(context.Background(), `UPDATE users SET status='recovery_required' WHERE id=$1`, reset.User.ID); e != nil {
		t.Fatal(e)
	}
	s, _ = post("/auth/password/login", "disabled-user-1", "", loginBody)
	if s != 401 {
		t.Fatal("disabled user authenticated")
	}
}
func TestPasswordResetUnknownExpiredAndAttemptLimits(t *testing.T) {
	api, db, _ := testAPI(t)
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()
	instance := "650e8400-e29b-41d4-a716-446655440202"
	s, b := doJSON(t, srv.Client(), "POST", srv.URL+"/v1/auth/password/reset/start", "", "", map[string]string{"email": "unknown@example.org"})
	if s != 202 {
		t.Fatalf("unknown response %d", s)
	}
	var v struct {
		ID string `json:"challenge_id"`
	}
	_ = json.Unmarshal(b, &v)
	for i := 0; i < 5; i++ {
		s, _ = doJSON(t, srv.Client(), "POST", srv.URL+"/v1/auth/password/reset/complete", "attempt-key-"+time.Now().Format("150405.000000000"), "", map[string]any{"challenge_id": v.ID, "code": "99999999", "new_password": "a quiet river phrase 2026", "client_instance_id": instance, "platform": "ios"})
		if s != 401 {
			t.Fatalf("bad proof status %d", s)
		}
	}
	var consumed bool
	if e := db.QueryRow(context.Background(), `SELECT consumed_at IS NOT NULL FROM auth_challenges WHERE id=$1`, v.ID).Scan(&consumed); e != nil || !consumed {
		t.Fatal("attempt limit did not consume challenge")
	}
	s, b = doJSON(t, srv.Client(), "POST", srv.URL+"/v1/auth/password/reset/start", "", "", map[string]string{"email": "expired@example.org"})
	if s != 202 {
		t.Fatal("start failed")
	}
	_ = json.Unmarshal(b, &v)
	if _, e := db.Exec(context.Background(), `UPDATE auth_challenges SET created_at=now()-interval '20 minutes',expires_at=now()-interval '1 minute' WHERE id=$1`, v.ID); e != nil {
		t.Fatal(e)
	}
	s, _ = doJSON(t, srv.Client(), "POST", srv.URL+"/v1/auth/password/reset/complete", "expired-reset-1", "", map[string]any{"challenge_id": v.ID, "code": "99999999", "new_password": "a quiet river phrase 2026", "client_instance_id": instance, "platform": "ios"})
	if s != 401 {
		t.Fatal("expired proof accepted")
	}
}
