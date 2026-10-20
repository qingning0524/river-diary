package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestPersonalConsoleOwnershipAndFeedbackReplay(t *testing.T) {
	api, db, _ := testAPI(t)
	ctx := context.Background()
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()
	create := func(email, instance string) TokenResponse {
		t.Helper()
		tx, err := db.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		var uid, iid string
		if err = tx.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&uid); err != nil {
			t.Fatal(err)
		}
		if err = tx.QueryRow(ctx, `INSERT INTO identities(user_id,provider,subject,email_canonical,email_display,verified_at) VALUES($1,'email',$2,$2,$2,now()) RETURNING id::text`, uid, email).Scan(&iid); err != nil {
			t.Fatal(err)
		}
		did, err := upsertDevice(ctx, tx, uid, instance, "other", "fixture browser")
		if err != nil {
			t.Fatal(err)
		}
		out, err := api.createSession(ctx, tx, uid, iid, did, instance, false)
		if err != nil {
			t.Fatal(err)
		}
		if err = tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		return out
	}
	a := create("console-a@example.org", "650e8400-e29b-41d4-a716-446655440501")
	b := create("console-b@example.org", "650e8400-e29b-41d4-a716-446655440502")
	get := func(path, token string) (int, []byte) {
		return doJSON(t, srv.Client(), http.MethodGet, srv.URL+"/v1"+path, "", token, nil)
	}
	post := func(path, key, token string, body any) (int, []byte) {
		return doJSON(t, srv.Client(), http.MethodPost, srv.URL+"/v1"+path, key, token, body)
	}
	for _, path := range []string{"/me/sessions", "/me/activity", "/me/feedback", "/me/redemptions"} {
		s, _ := get(path, "")
		if s != 401 {
			t.Fatalf("unauthenticated %s %d", path, s)
		}
	}
	body := map[string]string{"subject": "界面建议", "body": "希望界面更加舒适。"}
	s, first := post("/me/feedback", "console-feedback-1", a.AccessToken, body)
	if s != 202 {
		t.Fatalf("feedback %d %s", s, first)
	}
	s, retry := post("/me/feedback", "console-feedback-1", a.AccessToken, body)
	if s != 202 || string(first) != string(retry) {
		t.Fatal("feedback replay changed")
	}
	body["body"] = "这是另一个不同的建议。"
	s, _ = post("/me/feedback", "console-feedback-1", a.AccessToken, body)
	if s != 409 {
		t.Fatal("different feedback reused key")
	}
	// A public submitter's contact email cannot turn an anonymous message into A's private record.
	if _, err := db.Exec(ctx, `INSERT INTO feedback_messages(contact_email,body) VALUES('console-a@example.org','anonymous-private-content'),('console-b@example.org','other-private-content')`); err != nil {
		t.Fatal(err)
	}
	s, own := get("/me/feedback", a.AccessToken)
	if s != 200 || !strings.Contains(string(own), "界面建议") || strings.Contains(string(own), "anonymous-private-content") {
		t.Fatalf("feedback ownership %d %s", s, own)
	}
	s, other := get("/me/feedback", b.AccessToken)
	if s != 200 || strings.Contains(string(other), "界面建议") {
		t.Fatal("feedback leaked to another account")
	}
	s, events := get("/me/activity", a.AccessToken)
	if s != 200 || !strings.Contains(string(events), "feedback_submitted") {
		t.Fatal("activity missing")
	}
	s, events = get("/me/activity", b.AccessToken)
	if s != 200 || strings.Contains(string(events), "feedback_submitted") {
		t.Fatal("activity leaked")
	}
	s, sessions := get("/me/sessions", a.AccessToken)
	if s != 200 {
		t.Fatalf("sessions %d %s", s, sessions)
	}
	var data struct {
		Sessions []struct {
			ID      string `json:"id"`
			Current bool   `json:"current"`
		} `json:"sessions"`
	}
	_ = json.Unmarshal(sessions, &data)
	if len(data.Sessions) != 1 || !data.Sessions[0].Current {
		t.Fatal("current session incorrect")
	}
	s, _ = post("/me/sessions/"+data.Sessions[0].ID+"/revoke", "", b.AccessToken, nil)
	if s != 404 {
		t.Fatal("another account revoked the session")
	}
	s, _ = get("/me", a.AccessToken)
	if s != 200 {
		t.Fatal("A session was changed by B")
	}
	s, _ = post("/me/sessions/"+data.Sessions[0].ID+"/revoke", "", a.AccessToken, nil)
	if s != 204 {
		t.Fatal("own revoke failed")
	}
	s, _ = get("/me", a.AccessToken)
	if s != 401 {
		t.Fatal("revoked session still valid")
	}
	s, _ = get("/me/redemptions", b.AccessToken)
	if s != 200 {
		t.Fatal("redemption history unavailable")
	}
	var count int
	if err := db.QueryRow(ctx, `SELECT count(*) FROM feedback_messages WHERE user_id=$1`, a.User.ID).Scan(&count); err != nil || count != 1 {
		t.Fatal("feedback retry duplicated a record")
	}
}
