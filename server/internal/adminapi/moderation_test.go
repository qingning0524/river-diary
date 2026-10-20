package adminapi

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"flowriver/server/internal/migrate"
	"flowriver/server/internal/secure"
)

type listedAdminSession struct {
	ID    string `json:"id"`
	IsYou bool   `json:"is_you"`
}

func readAdminSessions(t *testing.T, f adminFixture) []listedAdminSession {
	t.Helper()
	w := f.request(http.MethodGet, "/admin-sessions", nil, "")
	if w.Code != http.StatusOK {
		t.Fatalf("management sessions: status=%d body=%s", w.Code, w.Body.String())
	}
	if strings.Contains(w.Body.String(), hex.EncodeToString(secure.Digest(f.token))) {
		t.Fatal("management response disclosed the authentication token digest")
	}
	var response struct {
		Sessions []listedAdminSession `json:"sessions"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	for _, item := range response.Sessions {
		if !isUUID(item.ID) {
			t.Fatalf("session needs a public UUID, got %q", item.ID)
		}
	}
	return response.Sessions
}

func TestAdminSessionManagementUsesPublicIDs(t *testing.T) {
	f := testAdminAPI(t)
	current := readAdminSessions(t, f)
	if len(current) != 1 || !current[0].IsYou {
		t.Fatalf("initial session: %#v", current)
	}
	var otherID string
	if err := f.db.QueryRow(context.Background(), `INSERT INTO admin_sessions(token_mac,admin_id,csrf_mac,idle_expires_at,absolute_expires_at,ip_mac)
		SELECT $1,admin_id,csrf_mac,now()+interval '10 minutes',now()+interval '1 hour',ip_mac
		FROM admin_sessions WHERE token_mac=$2 RETURNING id::text`, secure.Digest("other-session-fixture"), secure.Digest(f.token)).Scan(&otherID); err != nil {
		t.Fatal(err)
	}
	items := readAdminSessions(t, f)
	if len(items) != 2 {
		t.Fatalf("want both administrator sessions, got %#v", items)
	}
	for _, item := range items {
		if item.IsYou != (item.ID == current[0].ID) {
			t.Fatalf("is_you must identify this browser session, got %#v", items)
		}
	}
	w := f.request(http.MethodPost, "/admin-sessions/"+otherID+"/revoke", bytes.NewBufferString(`{}`), "application/json")
	if w.Code != http.StatusOK {
		t.Fatalf("revoke public ID: status=%d body=%s", w.Code, w.Body.String())
	}
	remaining := readAdminSessions(t, f)
	if len(remaining) != 1 || remaining[0].ID != current[0].ID || !remaining[0].IsYou {
		t.Fatalf("revoking another browser must preserve this session: %#v", remaining)
	}
	var revoked bool
	if err := f.db.QueryRow(context.Background(), `SELECT revoked_at IS NOT NULL FROM admin_sessions WHERE id=$1`, otherID).Scan(&revoked); err != nil || !revoked {
		t.Fatalf("session not revoked: revoked=%v error=%v", revoked, err)
	}
}

func TestAdminSessionIDMigrationKeepsExistingLogin(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	// This fixture owns an isolated test schema. Simulate a populated 0008 database.
	if _, err := f.db.Exec(ctx, `ALTER TABLE admin_sessions DROP COLUMN id;
		DELETE FROM schema_migrations WHERE version='0009_admin_session_ids'`); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodGet, "/admin-sessions", nil, "")
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("missing public ID column must reproduce the old 503: status=%d body=%s", w.Code, w.Body.String())
	}
	if err := migrate.Apply(ctx, f.db); err != nil {
		t.Fatal(err)
	}
	items := readAdminSessions(t, f)
	if len(items) != 1 || !items[0].IsYou {
		t.Fatalf("existing login must survive the additive migration: %#v", items)
	}
	var count int
	if err := f.db.QueryRow(ctx, `SELECT count(*) FROM admin_sessions WHERE token_mac=$1`, secure.Digest(f.token)).Scan(&count); err != nil || count != 1 {
		t.Fatalf("migration changed token lookup: count=%d error=%v", count, err)
	}
}
