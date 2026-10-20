package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/jobs"
	"flowriver/server/internal/migrate"
	"flowriver/server/internal/secure"
	"flowriver/server/internal/securityjournal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type captureSender struct {
	mu       sync.Mutex
	to, code string
}

func (s *captureSender) SendOTP(_ context.Context, to, code string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.to, s.code = to, code
	return nil
}
func (s *captureSender) value() (string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.to, s.code
}

type captureJournal struct{ events []securityjournal.Event }

func (j *captureJournal) Append(_ context.Context, event securityjournal.Event) error {
	j.events = append(j.events, event)
	return nil
}

func testAPI(t *testing.T) (*API, *pgxpool.Pool, *captureSender) {
	t.Helper()
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set; database integration test skipped")
	}
	parsedDatabaseURL, err := url.Parse(databaseURL)
	if err != nil || !strings.Contains(strings.ToLower(strings.Trim(parsedDatabaseURL.Path, "/")), "test") {
		t.Fatal("TEST_DATABASE_URL must name an isolated database containing 'test'")
	}
	databaseHost := net.ParseIP(parsedDatabaseURL.Hostname())
	if parsedDatabaseURL.Hostname() != "localhost" && (databaseHost == nil || !databaseHost.IsLoopback()) {
		t.Fatal("integration database must be local to this machine")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	adminCfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	admin, err := pgxpool.NewWithConfig(ctx, adminCfg)
	if err != nil {
		t.Fatal(err)
	}
	nameToken, _ := secure.RandomToken(8)
	schema := "test_" + strings.NewReplacer("-", "_", "_", "a").Replace(nameToken)
	if _, err := admin.Exec(ctx, `CREATE SCHEMA `+pgx.Identifier{schema}.Sanitize()); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	testCfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		admin.Close()
		t.Fatal(err)
	}
	testCfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	testCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, `SET search_path TO `+pgx.Identifier{schema}.Sanitize())
		return err
	}
	pool, err := pgxpool.NewWithConfig(ctx, testCfg)
	if err != nil {
		admin.Close()
		t.Fatal(err)
	}
	if err := migrate.Apply(ctx, pool); err != nil {
		pool.Close()
		_, _ = admin.Exec(context.Background(), `DROP SCHEMA `+pgx.Identifier{schema}.Sanitize()+` CASCADE`)
		admin.Close()
		t.Fatalf("migrate test schema: %v", err)
	}
	t.Cleanup(func() {
		pool.Close()
		_, _ = admin.Exec(context.Background(), `DROP SCHEMA `+pgx.Identifier{schema}.Sanitize()+` CASCADE`)
		admin.Close()
	})
	key := func() []byte { return bytes.Repeat([]byte{byte(time.Now().UnixNano())}, 32) }
	cfg := config.Config{Environment: "test", ListenAddr: "127.0.0.1:0", DatabaseURL: databaseURL, AuthHMACKey: key(), OutboxEncryptionKey: key(), IdempotencyKey: key(), AppleTokenEncryptionKey: key(), TermsVersion: "terms-test-1", PrivacyVersion: "privacy-test-1", EmailMode: "console"}
	sender := &captureSender{}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	api, err := New(pool, cfg, sender, logger)
	if err != nil {
		t.Fatal(err)
	}
	return api, pool, sender
}

func doJSON(t *testing.T, client *http.Client, method, url, idem, auth string, body any) (int, []byte) {
	t.Helper()
	data, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(method, url, bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if idem != "" {
		req.Header.Set("Idempotency-Key", idem)
	}
	if auth != "" {
		req.Header.Set("Authorization", "Bearer "+auth)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	result, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, result
}

func TestEmailSignupOutboxAndSessionRotation(t *testing.T) {
	api, db, sender := testAPI(t)
	server := httptest.NewServer(api.Handler())
	defer server.Close()
	client := server.Client()
	status, start := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "Person@Example.org"})
	if status != http.StatusAccepted {
		t.Fatalf("email start status=%d body=%s", status, start)
	}
	if bytes.Contains(start, []byte("Person@Example.org")) {
		t.Fatal("email address leaked through the response")
	}
	var challengeID string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_login'`).Scan(&challengeID); err != nil {
		t.Fatal(err)
	}
	worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	worked, err := worker.DeliverOne(context.Background())
	if err != nil || !worked {
		t.Fatalf("outbox delivery: worked=%v err=%v", worked, err)
	}
	to, code := sender.value()
	if to != "Person@Example.org" || len(code) != 8 {
		t.Fatalf("unexpected captured message recipient=%q code-length=%d", to, len(code))
	}
	var storedMac []byte
	if err := db.QueryRow(context.Background(), `SELECT secret_mac FROM auth_challenges WHERE id=$1`, challengeID).Scan(&storedMac); err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(storedMac, []byte(code)) {
		t.Fatal("database contains a plaintext OTP")
	}
	var outboxPayload []byte
	if err := db.QueryRow(context.Background(), `SELECT payload_ciphertext FROM outbox_jobs WHERE completed_at IS NOT NULL ORDER BY created_at DESC LIMIT 1`).Scan(&outboxPayload); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(outboxPayload, []byte(code)) {
		t.Fatal("outbox ciphertext contains a plaintext OTP")
	}
	instance := "650e8400-e29b-41d4-a716-446655440000"
	wrongCode := "00000000"
	if wrongCode == code {
		wrongCode = "00000001"
	}
	verifyBody := map[string]any{"challenge_id": challengeID, "code": wrongCode, "client_instance_id": instance, "platform": "macos", "device_name": "Mac", "accept_terms": true}
	status, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/verify", "verifybad1", "", verifyBody)
	if status != http.StatusUnauthorized {
		t.Fatalf("bad OTP status=%d", status)
	}
	verifyBody["code"] = code
	verifyBody["accept_terms"] = false
	status, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/verify", "verify-no-terms", "", verifyBody)
	if status != http.StatusBadRequest {
		t.Fatalf("signup without consent status=%d", status)
	}
	verifyBody["accept_terms"] = true
	status, first := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/verify", "verify-success1", "", verifyBody)
	if status != http.StatusOK {
		t.Fatalf("signup status=%d body=%s", status, first)
	}
	status, retry := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/verify", "verify-success1", "", verifyBody)
	if status != http.StatusOK || !bytes.Equal(first, retry) {
		t.Fatalf("verification retry status=%d response changed=%v", status, !bytes.Equal(first, retry))
	}
	var tokens TokenResponse
	if err := json.Unmarshal(first, &tokens); err != nil {
		t.Fatal(err)
	}
	if !tokens.Created || tokens.User.Status != "active" || tokens.RevokeToken == "" {
		t.Fatalf("unexpected signup response: %+v", tokens)
	}
	var users, devices int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM devices`).Scan(&devices); err != nil {
		t.Fatal(err)
	}
	if users != 1 || devices != 1 {
		t.Fatalf("signup created users=%d devices=%d, want one each", users, devices)
	}
	status, _ = doJSON(t, client, http.MethodGet, server.URL+"/v1/me", "", tokens.AccessToken, map[string]any{})
	if status != http.StatusOK {
		t.Fatalf("GET /me status=%d", status)
	}
	refreshBody := map[string]string{"refresh_token": tokens.RefreshToken, "revoke_token": tokens.RevokeToken, "client_instance_id": instance}
	status, rotated := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/refresh", "refresh001", "", refreshBody)
	if status != http.StatusOK {
		t.Fatalf("refresh status=%d body=%s", status, rotated)
	}
	status, retried := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/refresh", "refresh001", "", refreshBody)
	if status != http.StatusOK || !bytes.Equal(rotated, retried) {
		t.Fatalf("refresh retry status=%d or response changed", status)
	}
	var next TokenResponse
	if err := json.Unmarshal(rotated, &next); err != nil {
		t.Fatal(err)
	}
	if next.RefreshToken == tokens.RefreshToken || next.RevokeToken != tokens.RevokeToken {
		t.Fatal("refresh failed to rotate or preserve the revocation token")
	}
	status, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/refresh", "refresh-other", "", refreshBody)
	if status != http.StatusUnauthorized {
		t.Fatalf("refresh-token replay status=%d", status)
	}
	status, _ = doJSON(t, client, http.MethodGet, server.URL+"/v1/me", "", next.AccessToken, map[string]any{})
	if status != http.StatusUnauthorized {
		t.Fatalf("replayed refresh did not revoke session: GET /me=%d", status)
	}
}

func TestRateLimitPersistsAndDoesNotRevealAccountExistence(t *testing.T) {
	api, db, _ := testAPI(t)
	server := httptest.NewServer(api.Handler())
	defer server.Close()
	client := server.Client()
	status, known := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "known@example.org"})
	if status != http.StatusAccepted {
		t.Fatal(status)
	}
	status, unknown := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "other@example.org"})
	var knownResponse, unknownResponse map[string]string
	if json.Unmarshal(known, &knownResponse) != nil || json.Unmarshal(unknown, &unknownResponse) != nil || status != http.StatusAccepted || knownResponse["message"] != unknownResponse["message"] || len(knownResponse) != len(unknownResponse) || !validUUID(knownResponse["challenge_id"]) || !validUUID(unknownResponse["challenge_id"]) || knownResponse["challenge_id"] == unknownResponse["challenge_id"] {
		t.Fatal("account-enumeration response structure differs or challenge IDs are not independent")
	}
	for i := 0; i < 3; i++ {
		_, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "known@example.org"})
	}
	var count int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM auth_challenges WHERE email_canonical='known@example.org' AND consumed_at IS NULL`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("superseding email requests left %d active challenges", count)
	}
	var buckets int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM rate_limit_buckets`).Scan(&buckets); err != nil {
		t.Fatal(err)
	}
	if buckets == 0 {
		t.Fatal("rate limits were not persisted")
	}
}

func TestAccountDeletionWaitsForOffHostJournal(t *testing.T) {
	api, db, sender := testAPI(t)
	server := httptest.NewServer(api.Handler())
	defer server.Close()
	client := server.Client()
	worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "delete@example.org"})
	var challengeID string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_login'`).Scan(&challengeID); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("login delivery: worked=%v err=%v", worked, err)
	}
	_, code := sender.value()
	instance := "650e8400-e29b-41d4-a716-446655440001"
	status, body := doJSON(t, client, http.MethodPost, server.URL+"/v1/auth/email/verify", "logindelete1", "", map[string]any{"challenge_id": challengeID, "code": code, "client_instance_id": instance, "platform": "macos", "device_name": "Mac", "accept_terms": true})
	if status != http.StatusOK {
		t.Fatalf("login status=%d %s", status, body)
	}
	var login TokenResponse
	if err := json.Unmarshal(body, &login); err != nil {
		t.Fatal(err)
	}
	status, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/me/reauth/email/start", "", login.AccessToken, map[string]any{})
	if status != http.StatusAccepted {
		t.Fatalf("reauth start=%d", status)
	}
	var reauthChallenge string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_reauth'`).Scan(&reauthChallenge); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("reauth delivery: worked=%v err=%v", worked, err)
	}
	_, reauthCode := sender.value()
	status, reauthBody := doJSON(t, client, http.MethodPost, server.URL+"/v1/me/reauth/email/verify", "reauthdel1", login.AccessToken, map[string]string{"challenge_id": reauthChallenge, "code": reauthCode, "purpose": "account_delete"})
	if status != http.StatusOK {
		t.Fatalf("reauth verify=%d %s", status, reauthBody)
	}
	var proof struct {
		Token string `json:"reauth_token"`
	}
	if err := json.Unmarshal(reauthBody, &proof); err != nil {
		t.Fatal(err)
	}
	deleteBody := map[string]string{"reauth_token": proof.Token}
	status, _ = doJSON(t, client, http.MethodPost, server.URL+"/v1/me/deletion", "deletekey1", login.AccessToken, deleteBody)
	if status != http.StatusServiceUnavailable {
		t.Fatalf("deletion without journal=%d", status)
	}
	var active int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM users WHERE status='active'`).Scan(&active); err != nil {
		t.Fatal(err)
	}
	if active != 1 {
		t.Fatal("missing off-host journal changed the account")
	}
	journal := &captureJournal{}
	api.journal = journal
	status, receiptBytes := doJSON(t, client, http.MethodPost, server.URL+"/v1/me/deletion", "deletekey1", login.AccessToken, deleteBody)
	if status != http.StatusAccepted {
		t.Fatalf("delete=%d %s", status, receiptBytes)
	}
	var receipt deleteResponse
	if err := json.Unmarshal(receiptBytes, &receipt); err != nil {
		t.Fatal(err)
	}
	status, retryBytes := doJSON(t, client, http.MethodPost, server.URL+"/v1/me/deletion", "deletekey1", login.AccessToken, deleteBody)
	var retryReceipt deleteResponse
	_ = json.Unmarshal(retryBytes, &retryReceipt)
	if status != http.StatusAccepted || retryReceipt.JobID != receipt.JobID || retryReceipt.StatusToken != receipt.StatusToken || !retryReceipt.StatusExpiresAt.Equal(receipt.StatusExpiresAt) {
		t.Fatalf("delete retry=%d same job=%v same token=%v same expiry=%v", status, retryReceipt.JobID == receipt.JobID, retryReceipt.StatusToken == receipt.StatusToken, retryReceipt.StatusExpiresAt.Equal(receipt.StatusExpiresAt))
	}
	securityWorker := &jobs.SecurityWorker{DB: db, Journal: journal, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	worked, err := securityWorker.DeliverOne(context.Background())
	if err != nil || !worked {
		t.Fatalf("journal worker: worked=%v err=%v", worked, err)
	}
	if len(journal.events) != 1 || journal.events[0].Kind != "account_deleted" {
		t.Fatalf("unexpected security journal events: %+v", journal.events)
	}
	request, err := http.NewRequest(http.MethodGet, server.URL+"/v1/me/deletion-status", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Deletion-Status-Token", receipt.StatusToken)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var final map[string]any
	if err := json.NewDecoder(response.Body).Decode(&final); err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK || final["status"] != "completed" || final["server_data_deleted"] != true {
		t.Fatalf("deletion not completed: status=%d body=%v", response.StatusCode, final)
	}
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM users`).Scan(&active); err != nil {
		t.Fatal(err)
	}
	if active != 0 {
		t.Fatalf("server retained %d user rows after the signed deletion event", active)
	}
	status, afterDeleteRetry := doJSON(t, client, http.MethodPost, server.URL+"/v1/me/deletion", "deletekey1", login.AccessToken, deleteBody)
	var afterReceipt deleteResponse
	_ = json.Unmarshal(afterDeleteRetry, &afterReceipt)
	if status != http.StatusAccepted || afterReceipt.JobID != receipt.JobID || afterReceipt.StatusToken != receipt.StatusToken || !afterReceipt.StatusExpiresAt.Equal(receipt.StatusExpiresAt) {
		t.Fatalf("post-deletion retry=%d same job=%v same token=%v same expiry=%v", status, afterReceipt.JobID == receipt.JobID, afterReceipt.StatusToken == receipt.StatusToken, afterReceipt.StatusExpiresAt.Equal(receipt.StatusExpiresAt))
	}
}

func TestEmailIdentityLinkRequiresStepUpAndVerifiedCode(t *testing.T) {
	api, db, sender := testAPI(t)
	server := httptest.NewServer(api.Handler())
	defer server.Close()
	client := server.Client()
	worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	post := func(path, idem, auth string, body any) (int, []byte) {
		return doJSON(t, client, http.MethodPost, server.URL+path, idem, auth, body)
	}
	_, _ = post("/v1/auth/email/start", "", "", map[string]string{"email": "first@example.org"})
	var loginChallenge string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_login'`).Scan(&loginChallenge); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("login delivery: %v %v", worked, err)
	}
	_, code := sender.value()
	instance := "650e8400-e29b-41d4-a716-446655440002"
	status, body := post("/v1/auth/email/verify", "linklogin1", "", map[string]any{"challenge_id": loginChallenge, "code": code, "client_instance_id": instance, "platform": "ios", "accept_terms": true})
	if status != http.StatusOK {
		t.Fatalf("login: %d %s", status, body)
	}
	var tokens TokenResponse
	if err := json.Unmarshal(body, &tokens); err != nil {
		t.Fatal(err)
	}
	status, _ = post("/v1/me/reauth/email/start", "", tokens.AccessToken, map[string]any{})
	if status != http.StatusAccepted {
		t.Fatalf("reauth start: %d", status)
	}
	var reauthChallenge string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_reauth'`).Scan(&reauthChallenge); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("reauth delivery: %v %v", worked, err)
	}
	_, reauthCode := sender.value()
	status, body = post("/v1/me/reauth/email/verify", "linkreauth1", tokens.AccessToken, map[string]string{"challenge_id": reauthChallenge, "code": reauthCode, "purpose": "identity_change"})
	if status != http.StatusOK {
		t.Fatalf("reauth verify: %d %s", status, body)
	}
	var stepUp struct {
		Token string `json:"reauth_token"`
	}
	if err := json.Unmarshal(body, &stepUp); err != nil {
		t.Fatal(err)
	}
	status, _ = post("/v1/me/identities/email/start", "", tokens.AccessToken, map[string]string{"email": "second@example.org", "reauth_token": stepUp.Token})
	if status != http.StatusAccepted {
		t.Fatalf("identity link start: %d", status)
	}
	var linkChallenge string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_link'`).Scan(&linkChallenge); err != nil {
		t.Fatal(err)
	}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("identity link delivery: %v %v", worked, err)
	}
	_, linkCode := sender.value()
	linkBody := map[string]string{"challenge_id": linkChallenge, "code": linkCode, "reauth_token": stepUp.Token}
	status, _ = post("/v1/me/identities/email/complete", "linkcomplete1", tokens.AccessToken, linkBody)
	if status != http.StatusNoContent {
		t.Fatalf("identity link complete: %d", status)
	}
	status, _ = post("/v1/me/identities/email/complete", "linkcomplete1", tokens.AccessToken, linkBody)
	if status != http.StatusNoContent {
		t.Fatalf("identity link retry: %d", status)
	}
	var count int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM identities WHERE user_id=$1 AND provider='email' AND status='active'`, tokens.User.ID).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("linked email identities=%d, want 2 on one account", count)
	}
}
