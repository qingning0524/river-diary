package adminapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func TestUserWorkspaceStatisticsAndCombinedFilters(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	ids := []string{"650e8400-e29b-41d4-a716-446655440401", "650e8400-e29b-41d4-a716-446655440402", "650e8400-e29b-41d4-a716-446655440403"}
	for i, id := range ids {
		if _, err := f.db.Exec(ctx, `INSERT INTO users(id,disabled_at) VALUES($1,CASE WHEN $2 THEN now() ELSE NULL END)`, id, i == 2); err != nil {
			t.Fatal(err)
		}
		email := []string{"owner@example.org", "old@example.org", "disabled@example.org"}[i]
		if _, err := f.db.Exec(ctx, `INSERT INTO identities(user_id,provider,subject,email_canonical,email_display,verified_at) VALUES($1,'email',$2,$2,$2,now())`, id, email); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.db.Exec(ctx, `INSERT INTO user_password_credentials(user_id,password_hash) VALUES($1,'fixture-only')`, ids[0]); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(ctx, `INSERT INTO user_entitlements(user_id,product_code,starts_at,expires_at) VALUES($1,'riverdiary_premium',now()-interval '1 day',now()+interval '1 day'),($2,'riverdiary_premium',now()-interval '30 days',now()-interval '1 day')`, ids[0], ids[1]); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(ctx, `INSERT INTO devices(user_id,instance_id,platform,last_seen_at) VALUES($1,gen_random_uuid(),'ios',now()),($2,gen_random_uuid(),'ios',now()-interval '30 days')`, ids[0], ids[1]); err != nil {
		t.Fatal(err)
	}
	stats := f.request(http.MethodGet, "/users/summary", nil, "")
	if stats.Code != 200 {
		t.Fatalf("summary %d %s", stats.Code, stats.Body)
	}
	var values map[string]any
	_ = json.Unmarshal(stats.Body.Bytes(), &values)
	for key, want := range map[string]float64{"total": 3, "active": 2, "disabled": 1, "password": 1, "recent": 1, "premium": 1} {
		if values[key] != want {
			t.Fatalf("%s=%v", key, values[key])
		}
	}
	for _, path := range []string{"/users?password=set&provider=email&premium=active&activity=recent&status=active", "/users?password=unset&premium=none&activity=inactive&status=active"} {
		w := f.request("GET", path, nil, "")
		if w.Code != 200 {
			t.Fatalf("filter %d %s", w.Code, w.Body)
		}
		var data struct {
			Users []userListRow `json:"users"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &data)
		if len(data.Users) != 1 {
			t.Fatalf("combined filter returned %d", len(data.Users))
		}
		if strings.Contains(w.Body.String(), "fixture-only") || strings.Contains(w.Body.String(), "owner@example.org") {
			t.Fatal("credential or complete email leaked")
		}
	}
	w := f.request("GET", "/users?password=invalid", nil, "")
	if w.Code != 400 {
		t.Fatal("invalid filter accepted")
	}
}
func TestUserActivityIsScopedToTheRequestedAccount(t *testing.T) {
	f := testAdminAPI(t)
	ctx := context.Background()
	var a, b string
	_ = f.db.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&a)
	_ = f.db.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&b)
	if _, err := f.db.Exec(ctx, `INSERT INTO audit_events(user_id,kind,request_id) VALUES($1,'password_login','test'),($2,'other_account_secret','test')`, a, b); err != nil {
		t.Fatal(err)
	}
	var deviceID, sessionID string
	if err := f.db.QueryRow(ctx, `INSERT INTO devices(user_id,instance_id,platform) VALUES($1,gen_random_uuid(),'other') RETURNING id::text`, a).Scan(&deviceID); err != nil {
		t.Fatal(err)
	}
	if err := f.db.QueryRow(ctx, `INSERT INTO sessions(user_id,device_id,revoke_token_mac,idle_expires_at,absolute_expires_at) VALUES($1,$2,decode('01','hex'),now()+interval '1 hour',now()+interval '1 day') RETURNING id::text`, a, deviceID).Scan(&sessionID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(ctx, `INSERT INTO admin_audit_events(action,target_type,target_id,result,request_id,ip_mac) VALUES('admin.user.session.revoke','session',$1,'success','test',decode('01','hex'))`, sessionID); err != nil {
		t.Fatal(err)
	}
	w := f.request("GET", "/users/"+a+"/activity", nil, "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "password_login") || !strings.Contains(w.Body.String(), "admin.user.session.revoke") || strings.Contains(w.Body.String(), "other_account_secret") {
		t.Fatalf("scoped activity %d %s", w.Code, w.Body)
	}
	other := f.request("GET", "/users/"+b+"/activity", nil, "")
	if strings.Contains(other.Body.String(), "admin.user.session.revoke") {
		t.Fatal("session activity leaked to another account")
	}
	w = f.request("GET", "/users/650e8400-e29b-41d4-a716-446655449999/activity", nil, "")
	if w.Code != 404 {
		t.Fatal("missing account did not return 404")
	}
}

func TestEmptyUserDetailUsesArraysInsteadOfNull(t *testing.T) {
	f := testAdminAPI(t)
	var id string
	if err := f.db.QueryRow(context.Background(), `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	w := f.request("GET", "/users/"+id, nil, "")
	if w.Code != 200 {
		t.Fatalf("detail %d %s", w.Code, w.Body)
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"identities", "entitlements", "consents"} {
		if value, ok := body[key].([]any); !ok || len(value) != 0 {
			t.Fatalf("%s must be an empty array, got %v", key, body[key])
		}
	}
}
