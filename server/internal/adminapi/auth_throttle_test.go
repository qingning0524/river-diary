package adminapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"golang.org/x/crypto/argon2"
)

const throttleTestPassword = "correct horse battery staple"

func fastAdminPasswordHash(password string) string {
	salt := []byte("0123456789abcdef")
	hash := argon2.IDKey([]byte(password), salt, 1, 16*1024, 1, 32)
	return fmt.Sprintf("argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", 16*1024, 1, 1,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(hash))
}

func createLoginAdmin(t *testing.T, f adminFixture, username string) (string, []byte) {
	t.Helper()
	secret, _, err := randomTOTPSecret()
	if err != nil {
		t.Fatal(err)
	}
	id, err := randomUUID()
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := f.api.totpBox.Seal(secret, []byte("flowriver-admin-totp:"+id))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(context.Background(), `INSERT INTO admin_accounts(id,username,password_hash,totp_secret_ciphertext)
		VALUES($1,$2,$3,$4)`, id, username, fastAdminPasswordHash(throttleTestPassword), sealed); err != nil {
		t.Fatal(err)
	}
	return id, secret
}

func adminLogin(t *testing.T, f adminFixture, username, password, remoteAddr string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(loginRequest{Username: username, Password: password})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "https://admin.test/admin-api/v1/auth/login", bytes.NewReader(body))
	r.RemoteAddr = remoteAddr
	r.Header.Set("Origin", f.api.cfg.AdminOrigin)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func adminMFA(t *testing.T, f adminFixture, challenge, code, remoteAddr string) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(mfaRequest{Challenge: challenge, Code: code})
	if err != nil {
		t.Fatal(err)
	}
	r := httptest.NewRequest(http.MethodPost, "https://admin.test/admin-api/v1/auth/mfa", bytes.NewReader(body))
	r.RemoteAddr = remoteAddr
	r.Header.Set("Origin", f.api.cfg.AdminOrigin)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func responseErrorCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error body %q: %v", w.Body.String(), err)
	}
	return body.Error.Code
}

func adminChallenge(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var body struct {
		Challenge string `json:"challenge"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode challenge body %q: %v", w.Body.String(), err)
	}
	if body.Challenge == "" {
		t.Fatalf("missing challenge in %q", w.Body.String())
	}
	return body.Challenge
}

func invalidTOTP(secret []byte) string {
	valid := totpCode(secret, time.Now().UTC().Unix()/30)
	if valid == "000000" {
		return "000001"
	}
	return "000000"
}

func TestAdminLoginThrottlesByAccountAfterFiveFailures(t *testing.T) {
	f := testAdminAPI(t)
	adminA, _ := createLoginAdmin(t, f, "throttle-a")
	adminB, _ := createLoginAdmin(t, f, "throttle-b")

	for i := 0; i < 5; i++ {
		w := adminLogin(t, f, "throttle-a", "wrong password", "127.0.0.1:12345")
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("failure %d: status=%d body=%s", i+1, w.Code, w.Body.String())
		}
	}
	w := adminLogin(t, f, "throttle-a", "wrong password", "127.0.0.1:12345")
	if w.Code != http.StatusTooManyRequests || responseErrorCode(t, w) != "rate_limited" {
		t.Fatalf("sixth failure: status=%d code=%q body=%s", w.Code, responseErrorCode(t, w), w.Body.String())
	}
	// The bucket is keyed by administrator, not by the tunnel's loopback IP.
	w = adminLogin(t, f, "throttle-a", throttleTestPassword, "203.0.113.9:12345")
	if w.Code != http.StatusTooManyRequests || responseErrorCode(t, w) != "rate_limited" {
		t.Fatalf("different source IP must not bypass account throttle: status=%d body=%s", w.Code, w.Body.String())
	}
	w = adminLogin(t, f, "throttle-b", "wrong password", "127.0.0.1:12345")
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("second account was throttled: status=%d body=%s", w.Code, w.Body.String())
	}
	var audits int
	if err := f.db.QueryRow(context.Background(), `SELECT count(*) FROM admin_audit_events WHERE admin_id=$1 AND action='admin.login.throttled' AND result='denied'`, adminA).Scan(&audits); err != nil {
		t.Fatal(err)
	}
	if audits < 1 {
		t.Fatal("throttled login did not emit admin.login.throttled audit event")
	}
	var bHits int
	if err := f.db.QueryRow(context.Background(), `SELECT COALESCE((SELECT hits FROM admin_auth_buckets WHERE bucket_mac=$1),0)`, f.api.loginFailureBucket(adminB)).Scan(&bHits); err != nil {
		t.Fatal(err)
	}
	if bHits != 1 {
		t.Fatalf("second account bucket hits=%d, want 1", bHits)
	}
}

func TestAdminLoginSuccessClearsFailures(t *testing.T) {
	f := testAdminAPI(t)
	adminID, secret := createLoginAdmin(t, f, "throttle-reset")
	for i := 0; i < 4; i++ {
		if w := adminLogin(t, f, "throttle-reset", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusUnauthorized {
			t.Fatalf("failure %d: status=%d body=%s", i+1, w.Code, w.Body.String())
		}
	}
	login := adminLogin(t, f, "throttle-reset", throttleTestPassword, "127.0.0.1:12345")
	if login.Code != http.StatusOK {
		t.Fatalf("valid password: status=%d body=%s", login.Code, login.Body.String())
	}
	challenge := adminChallenge(t, login)
	code := totpCode(secret, time.Now().UTC().Unix()/30)
	mfa := adminMFA(t, f, challenge, code, "127.0.0.1:12345")
	if mfa.Code != http.StatusOK {
		t.Fatalf("valid MFA: status=%d body=%s", mfa.Code, mfa.Body.String())
	}
	var bucketRows int
	if err := f.db.QueryRow(context.Background(), `SELECT count(*) FROM admin_auth_buckets WHERE bucket_mac=$1`, f.api.loginFailureBucket(adminID)).Scan(&bucketRows); err != nil {
		t.Fatal(err)
	}
	if bucketRows != 0 {
		t.Fatal("successful MFA did not clear the account failure bucket")
	}
	for i := 0; i < 5; i++ {
		if w := adminLogin(t, f, "throttle-reset", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusUnauthorized {
			t.Fatalf("post-reset failure %d: status=%d body=%s", i+1, w.Code, w.Body.String())
		}
	}
	if w := adminLogin(t, f, "throttle-reset", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusTooManyRequests {
		t.Fatalf("post-reset sixth failure: status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestAdminMFAFailuresShareTheAccountLimit(t *testing.T) {
	f := testAdminAPI(t)
	_, secret := createLoginAdmin(t, f, "throttle-mfa")
	login := adminLogin(t, f, "throttle-mfa", throttleTestPassword, "127.0.0.1:12345")
	if login.Code != http.StatusOK {
		t.Fatalf("valid password: status=%d body=%s", login.Code, login.Body.String())
	}
	challenge := adminChallenge(t, login)
	for i := 0; i < 5; i++ {
		if w := adminMFA(t, f, challenge, invalidTOTP(secret), "127.0.0.1:12345"); w.Code != http.StatusUnauthorized {
			t.Fatalf("bad MFA %d: status=%d body=%s", i+1, w.Code, w.Body.String())
		}
	}
	w := adminMFA(t, f, challenge, invalidTOTP(secret), "127.0.0.1:12345")
	if w.Code != http.StatusTooManyRequests || responseErrorCode(t, w) != "rate_limited" {
		t.Fatalf("sixth bad MFA: status=%d code=%q body=%s", w.Code, responseErrorCode(t, w), w.Body.String())
	}
}

func TestAdminLoginThrottleWindowExpires(t *testing.T) {
	f := testAdminAPI(t)
	adminID, _ := createLoginAdmin(t, f, "throttle-window")
	for i := 0; i < 5; i++ {
		if w := adminLogin(t, f, "throttle-window", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusUnauthorized {
			t.Fatalf("failure %d: status=%d body=%s", i+1, w.Code, w.Body.String())
		}
	}
	if w := adminLogin(t, f, "throttle-window", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusTooManyRequests {
		t.Fatalf("sixth failure: status=%d body=%s", w.Code, w.Body.String())
	}
	if _, err := f.db.Exec(context.Background(), `UPDATE admin_auth_buckets SET window_start=now()-interval '16 minutes' WHERE bucket_mac=$1`, f.api.loginFailureBucket(adminID)); err != nil {
		t.Fatal(err)
	}
	if w := adminLogin(t, f, "throttle-window", "wrong password", "127.0.0.1:12345"); w.Code != http.StatusUnauthorized {
		t.Fatalf("expired window must allow a new failure: status=%d body=%s", w.Code, w.Body.String())
	}
	var hits int
	if err := f.db.QueryRow(context.Background(), `SELECT hits FROM admin_auth_buckets WHERE bucket_mac=$1`, f.api.loginFailureBucket(adminID)).Scan(&hits); err != nil {
		t.Fatal(err)
	}
	if hits != 1 {
		t.Fatalf("expired window hits=%d, want 1", hits)
	}
}
