package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestMemoryMirrorIsScopedAndPreconditioned(t *testing.T) {
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
	a := create("mirror-a@example.org", "650e8400-e29b-41d4-a716-446655440601")
	b := create("mirror-b@example.org", "650e8400-e29b-41d4-a716-446655440602")
	call := func(method, path, token, ifMatch, ifNone string, body any) (int, []byte) {
		t.Helper()
		var reader *bytes.Reader
		if body == nil {
			reader = bytes.NewReader(nil)
		} else {
			encoded, err := json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
			reader = bytes.NewReader(encoded)
		}
		req, err := http.NewRequest(method, srv.URL+"/v1"+path, reader)
		if err != nil {
			t.Fatal(err)
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if ifMatch != "" {
			req.Header.Set("If-Match", ifMatch)
		}
		if ifNone != "" {
			req.Header.Set("If-None-Match", ifNone)
		}
		resp, err := srv.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var out bytes.Buffer
		if _, err = out.ReadFrom(resp.Body); err != nil {
			t.Fatal(err)
		}
		return resp.StatusCode, out.Bytes()
	}
	salt := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{1}, 16))
	iv := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{2}, 12))
	ciphertext := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{3}, 64))
	envelope := map[string]any{
		"format":            "river.cloud-mirror",
		"version":           1,
		"kdf":               map[string]any{"name": "PBKDF2-SHA-256", "iterations": 600000, "salt": salt},
		"cipher":            map[string]any{"name": "AES-GCM-256", "iv": iv},
		"ciphertext":        ciphertext,
		"client_updated_at": "2026-10-20T00:00:00Z",
		"summary":           map[string]any{"entries": 2, "days": 2},
	}
	if status, _ := call("GET", "/me/memory-mirror/meta", "", "", "", nil); status != 401 {
		t.Fatalf("unauthenticated meta %d", status)
	}
	if status, body := call("GET", "/me/memory-mirror/meta", a.AccessToken, "", "", nil); status != 200 || !strings.Contains(string(body), `"exists":false`) {
		t.Fatalf("empty meta %d %s", status, body)
	}
	if status, _ := call("PUT", "/me/memory-mirror", a.AccessToken, "", "", envelope); status != 428 {
		t.Fatalf("unconditional create %d", status)
	}
	status, body := call("PUT", "/me/memory-mirror", a.AccessToken, "", "*", envelope)
	if status != 201 {
		t.Fatalf("create %d %s", status, body)
	}
	var created memoryMirrorMeta
	if err := json.Unmarshal(body, &created); err != nil {
		t.Fatal(err)
	}
	if !created.Exists || created.Revision != 1 || created.SizeBytes != 64 || created.KDF == nil || created.KDF.Salt != salt {
		t.Fatalf("created metadata %+v", created)
	}
	status, body = call("GET", "/me/memory-mirror/meta", a.AccessToken, "", "", nil)
	if status != 200 || !strings.Contains(string(body), `"exists":true`) || strings.Contains(string(body), "ciphertext") {
		t.Fatalf("meta %d %s", status, body)
	}
	status, body = call("GET", "/me/memory-mirror", a.AccessToken, "", "", nil)
	if status != 200 {
		t.Fatalf("download %d %s", status, body)
	}
	var downloaded memoryMirrorMeta
	if err := json.Unmarshal(body, &downloaded); err != nil {
		t.Fatal(err)
	}
	if downloaded.Ciphertext != ciphertext || downloaded.Summary == nil {
		t.Fatalf("download body %s", body)
	}
	if status, body = call("GET", "/me/memory-mirror", b.AccessToken, "", "", nil); status != 404 {
		t.Fatalf("other account download %d %s", status, body)
	}
	if status, _ = call("PUT", "/me/memory-mirror", a.AccessToken, "", "", envelope); status != 428 {
		t.Fatalf("unconditional update %d", status)
	}
	if status, _ = call("PUT", "/me/memory-mirror", a.AccessToken, `"9"`, "", envelope); status != 412 {
		t.Fatalf("stale update %d", status)
	}
	if status, _ = call("PUT", "/me/memory-mirror", a.AccessToken, "", "*", envelope); status != 409 {
		t.Fatalf("create over existing %d", status)
	}
	status, body = call("PUT", "/me/memory-mirror", a.AccessToken, `"1"`, "", envelope)
	if status != 200 || !strings.Contains(string(body), `"revision":2`) {
		t.Fatalf("update %d %s", status, body)
	}
	if status, _ = call("DELETE", "/me/memory-mirror", a.AccessToken, "", "", nil); status != 428 {
		t.Fatalf("unconditional delete %d", status)
	}
	if status, _ = call("DELETE", "/me/memory-mirror", a.AccessToken, `"1"`, "", nil); status != 412 {
		t.Fatalf("stale delete %d", status)
	}
	if status, _ = call("DELETE", "/me/memory-mirror", b.AccessToken, `"2"`, "", nil); status != 404 {
		t.Fatalf("other delete %d", status)
	}
	if status, _ = call("DELETE", "/me/memory-mirror", a.AccessToken, `"2"`, "", nil); status != 204 {
		t.Fatalf("delete %d", status)
	}
	if status, body = call("GET", "/me/memory-mirror/meta", a.AccessToken, "", "", nil); status != 200 || !strings.Contains(string(body), `"exists":false`) {
		t.Fatalf("deleted meta %d %s", status, body)
	}
	var events []string
	rows, err := db.Query(ctx, `SELECT kind FROM audit_events WHERE user_id=$1 ORDER BY created_at`, a.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var kind string
		if err = rows.Scan(&kind); err != nil {
			t.Fatal(err)
		}
		events = append(events, kind)
	}
	joined := strings.Join(events, ",")
	for _, kind := range []string{"memory_mirror_uploaded", "memory_mirror_downloaded", "memory_mirror_deleted"} {
		if !strings.Contains(joined, kind) {
			t.Fatalf("missing audit %s in %s", kind, joined)
		}
	}
	var otherCount int
	if err = db.QueryRow(ctx, `SELECT count(*) FROM audit_events WHERE user_id=$1 AND kind LIKE 'memory_mirror_%'`, b.User.ID).Scan(&otherCount); err != nil {
		t.Fatal(err)
	}
	if otherCount != 0 {
		t.Fatalf("other account audit leaked %d", otherCount)
	}
	invalid := map[string]any{
		"format": "river.cloud-mirror", "version": 1,
		"kdf":        map[string]any{"name": "PBKDF2-SHA-256", "iterations": 10, "salt": salt},
		"cipher":     map[string]any{"name": "AES-GCM-256", "iv": iv},
		"ciphertext": ciphertext, "summary": map[string]any{},
	}
	if status, _ = call("PUT", "/me/memory-mirror", a.AccessToken, "", "*", invalid); status != 400 {
		t.Fatalf("invalid iterations %d", status)
	}
	invalidSummary := map[string]any{
		"format": "river.cloud-mirror", "version": 1,
		"kdf":        map[string]any{"name": "PBKDF2-SHA-256", "iterations": 600000, "salt": salt},
		"cipher":     map[string]any{"name": "AES-GCM-256", "iv": iv},
		"ciphertext": ciphertext, "summary": map[string]any{"entries": 1, "note": "plaintext must not enter metadata"},
	}
	if status, _ = call("PUT", "/me/memory-mirror", a.AccessToken, "", "*", invalidSummary); status != 400 {
		t.Fatalf("summary smuggling accepted %d", status)
	}
}
