package httpapi

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"golang.org/x/crypto/pbkdf2"
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

// TestMemoryMirrorTwoDevicesStoreOnlyCiphertext exercises the real HTTP
// boundary with two sessions for the same account (Mac + iPhone). Device A
// encrypts a mirror locally, the server stores only the envelope, and device B
// downloads the exact ciphertext, decrypts it, and rejects a wrong passphrase.
// It also inspects the database row to show there is no plaintext column.
func TestMemoryMirrorTwoDevicesStoreOnlyCiphertext(t *testing.T) {
	api, db, _ := testAPI(t)
	ctx := context.Background()
	srv := httptest.NewServer(api.Handler())
	defer srv.Close()

	tx, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var uid, iid string
	if err = tx.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&uid); err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `INSERT INTO identities(user_id,provider,subject,email_canonical,email_display,verified_at) VALUES($1,'email',$2,$2,$2,now()) RETURNING id::text`,
		uid, "two-devices@example.org").Scan(&iid); err != nil {
		t.Fatal(err)
	}
	deviceA, err := upsertDevice(ctx, tx, uid, "650e8400-e29b-41d4-a716-446655440611", "macos", "fixture Mac")
	if err != nil {
		t.Fatal(err)
	}
	deviceB, err := upsertDevice(ctx, tx, uid, "650e8400-e29b-41d4-a716-446655440612", "ios", "fixture iPhone")
	if err != nil {
		t.Fatal(err)
	}
	sessionA, err := api.createSession(ctx, tx, uid, iid, deviceA, "650e8400-e29b-41d4-a716-446655440611", false)
	if err != nil {
		t.Fatal(err)
	}
	sessionB, err := api.createSession(ctx, tx, uid, iid, deviceB, "650e8400-e29b-41d4-a716-446655440612", false)
	if err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}

	call := func(method, path, token, ifMatch, ifNone string, body any) (int, []byte) {
		t.Helper()
		var payload []byte
		if body != nil {
			payload, err = json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
		}
		req, err := http.NewRequest(method, srv.URL+"/v1"+path, bytes.NewReader(payload))
		if err != nil {
			t.Fatal(err)
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		req.Header.Set("Authorization", "Bearer "+token)
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
		out, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		return resp.StatusCode, out
	}

	passphrase := "correct horse battery staple"
	salt := bytes.Repeat([]byte{0x11}, 16)
	iv := bytes.Repeat([]byte{0x22}, 12)
	iterations := 100000
	plaintext := []byte(`{"format":"river.memory-mirror","version":2,"entries":[{"title":"只存在于本机的标题","body":"服务端不应看到这句话"}]}`)
	key := pbkdf2.Key([]byte(passphrase), salt, iterations, 32, sha256.New)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	ciphertext := gcm.Seal(nil, iv, plaintext, []byte("river.cloud-mirror:v1"))
	envelope := map[string]any{
		"format":  "river.cloud-mirror",
		"version": 1,
		"kdf": map[string]any{
			"name": "PBKDF2-SHA-256", "iterations": iterations,
			"salt": base64.StdEncoding.EncodeToString(salt),
		},
		"cipher": map[string]any{
			"name": "AES-GCM-256", "iv": base64.StdEncoding.EncodeToString(iv),
		},
		"ciphertext":        base64.StdEncoding.EncodeToString(ciphertext),
		"client_updated_at": "2026-10-22T00:00:00Z",
		"summary": map[string]any{
			"entries": 1, "days": 1, "places": 0, "collections": 0,
			"understandings": 0, "first": "2026-10-22", "last": "2026-10-22",
			"includes_health": true,
		},
	}

	status, body := call("PUT", "/me/memory-mirror", sessionA.AccessToken, "", "*", envelope)
	if status != 201 {
		t.Fatalf("device A upload %d %s", status, body)
	}
	status, body = call("GET", "/me/memory-mirror/meta", sessionA.AccessToken, "", "", nil)
	if status != 200 || !strings.Contains(string(body), `"includes_health":true`) {
		t.Fatalf("device A meta %d %s", status, body)
	}
	status, body = call("GET", "/me/memory-mirror", sessionB.AccessToken, "", "", nil)
	if status != 200 {
		t.Fatalf("device B download %d %s", status, body)
	}
	var downloaded memoryMirrorMeta
	if err := json.Unmarshal(body, &downloaded); err != nil {
		t.Fatal(err)
	}
	if downloaded.Ciphertext != envelope["ciphertext"] {
		t.Fatal("device B did not receive the exact ciphertext")
	}
	downloadedBytes, err := base64.StdEncoding.DecodeString(downloaded.Ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := gcm.Open(nil, iv, downloadedBytes, []byte("river.cloud-mirror:v1"))
	if err != nil || !bytes.Equal(opened, plaintext) {
		t.Fatalf("device B decryption failed: %v", err)
	}
	wrongKey := pbkdf2.Key([]byte("wrong passphrase"), salt, iterations, 32, sha256.New)
	wrongBlock, err := aes.NewCipher(wrongKey)
	if err != nil {
		t.Fatal(err)
	}
	wrongGCM, err := cipher.NewGCM(wrongBlock)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = wrongGCM.Open(nil, iv, downloadedBytes, []byte("river.cloud-mirror:v1")); err == nil {
		t.Fatal("wrong passphrase unexpectedly decrypted the mirror")
	}

	var stored []byte
	var summary string
	if err = db.QueryRow(ctx, `SELECT ciphertext, summary::text FROM user_memory_mirrors WHERE user_id=$1`, uid).Scan(&stored, &summary); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, ciphertext) {
		t.Fatal("database ciphertext differs from uploaded ciphertext")
	}
	if bytes.Contains(stored, []byte("只存在于本机")) || strings.Contains(summary, "只存在于本机") {
		t.Fatal("plaintext leaked into the database row")
	}
	var leaked int
	if err = db.QueryRow(ctx, `SELECT count(*) FROM user_memory_mirrors WHERE user_id=$1 AND (ciphertext::text LIKE '%只存在于本机%' OR summary::text LIKE '%只存在于本机%')`, uid).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	if leaked != 0 {
		t.Fatalf("SQL found %d rows containing plaintext", leaked)
	}
	t.Logf("SQL: SELECT count(*) ... WHERE ciphertext/summary LIKE plaintext = %d", leaked)
	t.Logf("DB row: ciphertext_bytes=%d sha256=%x summary=%s", len(stored), sha256.Sum256(stored), summary)
	t.Logf("Device B decrypted %d bytes with the passphrase; wrong passphrase rejected", len(opened))
}
