package adminapi

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"mime/multipart"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/migrate"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type adminFixture struct {
	api   *API
	db    *pgxpool.Pool
	token string
	csrf  string
}

// Use the same isolated, local database convention as the account API tests.
func testAdminAPI(t *testing.T) adminFixture {
	t.Helper()
	databaseURL := os.Getenv("TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("TEST_DATABASE_URL is not set; database integration test skipped")
	}
	u, err := url.Parse(databaseURL)
	if err != nil || !strings.Contains(strings.ToLower(strings.Trim(u.Path, "/")), "test") {
		t.Fatal("TEST_DATABASE_URL must name an isolated database containing 'test'")
	}
	ip := net.ParseIP(u.Hostname())
	if u.Hostname() != "localhost" && (ip == nil || !ip.IsLoopback()) {
		t.Fatal("integration database must be local to this machine")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	admin, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	token, err := secure.RandomToken(8)
	if err != nil {
		admin.Close()
		t.Fatal(err)
	}
	schema := "test_admin_" + strings.NewReplacer("-", "_", "_", "a").Replace(token)
	if _, err := admin.Exec(ctx, `CREATE SCHEMA `+pgx.Identifier{schema}.Sanitize()); err != nil {
		admin.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = admin.Exec(context.Background(), `DROP SCHEMA `+pgx.Identifier{schema}.Sanitize()+` CASCADE`)
		admin.Close()
	})
	poolCfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	poolCfg.ConnConfig.RuntimeParams["timezone"] = "UTC"
	poolCfg.AfterConnect = func(ctx context.Context, conn *pgx.Conn) error {
		_, err := conn.Exec(ctx, `SET search_path TO `+pgx.Identifier{schema}.Sanitize())
		return err
	}
	db, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	if err := migrate.Apply(ctx, db); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{Environment: "test", AdminEnabled: true, AdminOrigin: "https://admin.test", AdminTOTPEncryptionKey: bytes.Repeat([]byte{1}, 32), AdminAuditHMACKey: bytes.Repeat([]byte{2}, 32), DownloadDir: t.TempDir()}
	api, err := New(db, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)), nil)
	if err != nil {
		t.Fatal(err)
	}
	var id string
	if err := db.QueryRow(ctx, `INSERT INTO admin_accounts(username,password_hash,totp_secret_ciphertext) VALUES('regression-fixture','fixture',decode('01','hex')) RETURNING id::text`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	f := adminFixture{api: api, db: db, token: "regression-session-token-32-characters-long", csrf: "regression-csrf-token"}
	if _, err := db.Exec(ctx, `INSERT INTO admin_sessions(token_mac,admin_id,csrf_mac,idle_expires_at,absolute_expires_at,ip_mac,reauthenticated_until)
		VALUES($1,$2,$3,now()+interval '10 minutes',now()+interval '1 hour',$4,now()+interval '5 minutes')`, secure.Digest(f.token), id, secure.Digest(f.csrf), secure.MAC(cfg.AdminAuditHMACKey, "admin-request-ip", "127.0.0.1")); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f adminFixture) request(method, path string, body io.Reader, contentType string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, "https://admin.test/admin-api/v1"+path, body)
	r.RemoteAddr = "127.0.0.1:12345"
	r.Header.Set("Origin", f.api.cfg.AdminOrigin)
	r.Header.Set("Content-Type", contentType)
	r.Header.Set("X-CSRF-Token", f.csrf)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.token})
	r.AddCookie(&http.Cookie{Name: csrfCookie, Value: f.csrf})
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func TestUserSearchFiltersAndStablePagination(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	for i, email := range []string{"owner@example.org", "owner.team@example.org", "owner_other@example.org", "", "disabled@example.org"} {
		id := "650e8400-e29b-41d4-a716-44665544030" + string(rune('1'+i))
		if _, err := f.db.Exec(ctx, `INSERT INTO users(id,created_at,disabled_at) VALUES($1,'2026-10-01T00:00:00Z',CASE WHEN $2 THEN now() ELSE NULL END)`, id, i == 4); err != nil {
			t.Fatal(err)
		}
		if email != "" {
			if _, err := f.db.Exec(ctx, `INSERT INTO identities(user_id,provider,subject,email_canonical,email_display,verified_at) VALUES($1,'email',$2,$2,$2,now())`, id, email); err != nil {
				t.Fatal(err)
			}
		}
	}
	type response struct {
		Users []userListRow `json:"users"`
		Next  string        `json:"next_cursor"`
	}
	read := func(path string) response {
		t.Helper()
		w := f.request(http.MethodGet, path, nil, "")
		if w.Code != http.StatusOK {
			t.Fatalf("%s: status=%d body=%s", path, w.Code, w.Body.String())
		}
		var result response
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	for _, tc := range []struct {
		name, query string
		count       int
	}{
		{"exact email", "owner@example.org", 1},
		{"exact user ID", "650e8400-e29b-41d4-a716-446655440304", 1},
		{"missing email", "missing@example.org", 0},
		{"prefix", "owner", 3},
		{"literal underscore prefix", "owner_", 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result := read("/users?q=" + url.QueryEscape(tc.query))
			if len(result.Users) != tc.count {
				t.Fatalf("query %q returned %d users, want %d", tc.query, len(result.Users), tc.count)
			}
		})
	}
	active := read("/users?status=active")
	if len(active.Users) != 4 {
		t.Errorf("normal filter returned %d users, want 4", len(active.Users))
	}
	for _, user := range active.Users {
		if user.Disabled {
			t.Error("normal filter included a disabled account")
		}
	}
	w := f.request(http.MethodGet, "/overview", nil, "")
	var counts struct {
		Active int `json:"active_accounts"`
		All    int `json:"all_accounts"`
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &counts) != nil || counts.Active != 4 || counts.All != 5 {
		t.Errorf("overview must distinguish usable accounts from all accounts: status=%d body=%s", w.Code, w.Body.String())
	}
	seen := map[string]bool{}
	cursor := ""
	for page := 0; page < 4; page++ {
		result := read("/users?limit=2&cursor=" + url.QueryEscape(cursor))
		for _, user := range result.Users {
			if seen[user.ID] {
				t.Fatal("pagination repeated a user")
			}
			seen[user.ID] = true
		}
		cursor = result.Next
		if cursor == "" {
			break
		}
	}
	if len(seen) != 5 || cursor != "" {
		t.Errorf("pagination covered %d users with remaining cursor %q, want all 5", len(seen), cursor)
	}
	if w := f.request(http.MethodGet, "/users?cursor=invalid", nil, ""); w.Code != http.StatusBadRequest {
		t.Errorf("invalid cursor status=%d", w.Code)
	}
}

func TestProtectedAPIPreservesSessionDuringDatabaseFailure(t *testing.T) {
	f := testAdminAPI(t)
	f.db.Close()
	w := f.request(http.MethodGet, "/overview", nil, "")
	if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "temporarily_unavailable") {
		t.Fatalf("database failure status=%d body=%s", w.Code, w.Body.String())
	}
	if len(w.Result().Cookies()) != 0 {
		t.Fatal("database failure cleared administrator cookies")
	}
}

func TestAnnouncementUnicodeLimitsAndLinkSafety(t *testing.T) {
	valid := func() announcementPayload {
		return announcementPayload{Level: "info", Placement: "banner", Title: strings.Repeat("河", 120), Body: strings.Repeat("流", 500)}
	}
	if p := valid(); !p.validate() {
		t.Fatal("Chinese content at the documented character limits was rejected")
	}
	for _, href := range []string{"", "/download", "https://flowriver.xyz/download", "#download", "/更新说明"} {
		p := valid()
		p.Href = href
		if !p.validate() {
			t.Errorf("safe link %q rejected", href)
		}
	}
	for _, href := range []string{"javascript:alert(1)", "data:text/html,hello", "//evil.example", "https://", "https://user:password@example.org", "/\\evil.example", "https://example.org/\nfoo"} {
		p := valid()
		p.Href = href
		if p.validate() {
			t.Errorf("unsafe link %q accepted", href)
		}
	}
	p := valid()
	p.Title += "河"
	if p.validate() {
		t.Error("title beyond 120 characters accepted")
	}
	p = valid()
	p.Body += "流"
	if p.validate() {
		t.Error("body beyond 500 characters accepted")
	}
}

func TestDownloadNoteRollsBackWhenAuditFails(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	var id string
	if err := f.db.QueryRow(ctx, `INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256,note) VALUES('macos','1.0','fixture.zip',4,$1,'old note') RETURNING id::text`, strings.Repeat("a", 64)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(ctx, `ALTER TABLE admin_audit_events ADD CONSTRAINT reject_note_audit CHECK (action <> 'admin.download.note')`); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodPost, "/downloads/"+id+"/note", strings.NewReader(`{"note":"new note"}`), "application/json")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed audit status=%d body=%s", w.Code, w.Body.String())
	}
	var note string
	if err := f.db.QueryRow(ctx, `SELECT note FROM download_artifacts WHERE id=$1`, id).Scan(&note); err != nil {
		t.Fatal(err)
	}
	if note != "old note" {
		t.Fatal("failed operation changed download metadata without an audit record")
	}
}

func TestDownloadFailedUploadDoesNotBlockRetry(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	if _, err := f.db.Exec(ctx, `ALTER TABLE admin_audit_events ADD CONSTRAINT reject_upload_audit CHECK (action <> 'admin.download.upload')`); err != nil {
		t.Fatal(err)
	}
	upload := func() *httptest.ResponseRecorder {
		var body bytes.Buffer
		m := multipart.NewWriter(&body)
		_ = m.WriteField("platform", "macos")
		_ = m.WriteField("version", "1.0")
		file, err := m.CreateFormFile("file", "retry.zip")
		if err != nil {
			t.Fatal(err)
		}
		_, _ = file.Write([]byte("PK\x03\x04fixture archive"))
		_ = m.Close()
		return f.request(http.MethodPost, "/downloads", &body, m.FormDataContentType())
	}
	if w := upload(); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("failed upload status=%d body=%s", w.Code, w.Body.String())
	}
	if _, err := os.Stat(filepath.Join(f.api.cfg.DownloadDir, "retry.zip")); !os.IsNotExist(err) {
		t.Error("failed upload left a published file and prevented a same-name retry")
	}
	if _, err := f.db.Exec(ctx, `ALTER TABLE admin_audit_events DROP CONSTRAINT reject_upload_audit`); err != nil {
		t.Fatal(err)
	}
	if w := upload(); w.Code != http.StatusCreated {
		t.Fatalf("retry upload status=%d body=%s", w.Code, w.Body.String())
	}
	w := upload()
	if w.Code != http.StatusConflict {
		t.Errorf("duplicate filename status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestDownloadUploadOutlivesOrdinaryReadAndWriteTimeouts(t *testing.T) {
	f := testAdminAPI(t)
	var body bytes.Buffer
	m := multipart.NewWriter(&body)
	_ = m.WriteField("platform", "macos")
	_ = m.WriteField("version", "1.0")
	file, err := m.CreateFormFile("file", "slow-upload.zip")
	if err != nil {
		t.Fatal(err)
	}
	archive := []byte("PK\x03\x04slow upload fixture")
	_, _ = file.Write(archive)
	_ = m.Close()
	server := httptest.NewUnstartedServer(f.api.Handler())
	server.Config.ReadTimeout = 200 * time.Millisecond
	server.Config.WriteTimeout = 200 * time.Millisecond
	server.Start()
	defer server.Close()
	reader, writer := io.Pipe()
	defer reader.Close()
	go func() {
		defer writer.Close()
		raw := body.Bytes()
		_, _ = writer.Write(raw[:len(raw)/2])
		time.Sleep(400 * time.Millisecond)
		_, _ = writer.Write(raw[len(raw)/2:])
	}()
	req, err := http.NewRequest(http.MethodPost, server.URL+"/admin-api/v1/downloads", reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Origin", f.api.cfg.AdminOrigin)
	req.Header.Set("Content-Type", m.FormDataContentType())
	req.Header.Set("X-CSRF-Token", f.csrf)
	req.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.token})
	req.AddCookie(&http.Cookie{Name: csrfCookie, Value: f.csrf})
	client := server.Client()
	client.Timeout = 3 * time.Second
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("slow upload failed: %v", err)
	}
	defer resp.Body.Close()
	result, err := io.ReadAll(resp.Body)
	if err != nil || resp.StatusCode != http.StatusCreated {
		t.Fatalf("slow upload status=%d body=%s error=%v", resp.StatusCode, result, err)
	}
	got, err := os.ReadFile(filepath.Join(f.api.cfg.DownloadDir, "slow-upload.zip"))
	if err != nil || !bytes.Equal(got, archive) {
		t.Fatal("slow upload did not preserve the complete archive")
	}
}
