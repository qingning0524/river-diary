package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"mime"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestPublicDownloadPublicationHeadRangeAndSuspension(t *testing.T) {
	api, db, _ := testAPI(t)
	api.cfg.DownloadDir = t.TempDir()
	name := "FlowRiver-1.0.zip"
	archive := []byte("PK\x03\x04private-mode archive fixture")
	if err := os.WriteFile(filepath.Join(api.cfg.DownloadDir, name), archive, 0o600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(archive)
	sha := hex.EncodeToString(digest[:])
	var id string
	if err := db.QueryRow(context.Background(), "INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256,is_active,activated_at) VALUES('macos','1.0',$1,$2,$3,true,now()) RETURNING id::text", name, len(archive), sha).Scan(&id); err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, headers map[string]string) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "https://flowriver.test"+path, nil)
		for k, v := range headers {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		return w
	}
	w := call(http.MethodGet, "/downloads/"+name, nil)
	if w.Code != http.StatusOK || !bytes.Equal(w.Body.Bytes(), archive) {
		t.Fatalf("active download status=%d body=%s", w.Code, w.Body.String())
	}
	if w.Header().Get("Content-Type") != "application/zip" || w.Header().Get("Content-Length") != strconv.Itoa(len(archive)) || w.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("unexpected archive response headers: %v", w.Header())
	}
	media, params, err := mime.ParseMediaType(w.Header().Get("Content-Disposition"))
	if err != nil || media != "attachment" || params["filename"] != name {
		t.Fatal("download response does not name the attachment safely")
	}
	etag := w.Header().Get("ETag")
	if etag != "\""+sha+"\"" {
		t.Fatalf("download ETag=%q", etag)
	}
	w = call(http.MethodHead, "/downloads/"+name, nil)
	if w.Code != http.StatusOK || w.Body.Len() != 0 || w.Header().Get("Content-Length") != strconv.Itoa(len(archive)) {
		t.Fatalf("HEAD status=%d length=%s body bytes=%d", w.Code, w.Header().Get("Content-Length"), w.Body.Len())
	}
	w = call(http.MethodGet, "/downloads/"+name, map[string]string{"Range": "bytes=4-10"})
	if w.Code != http.StatusPartialContent || !bytes.Equal(w.Body.Bytes(), archive[4:11]) || w.Header().Get("Content-Range") != "bytes 4-10/"+strconv.Itoa(len(archive)) {
		t.Fatalf("range status=%d headers=%v body=%q", w.Code, w.Header(), w.Body.String())
	}
	if w = call(http.MethodGet, "/downloads/"+name, map[string]string{"If-None-Match": etag}); w.Code != http.StatusNotModified {
		t.Fatalf("conditional active download status=%d", w.Code)
	}
	if _, err := db.Exec(context.Background(), "UPDATE download_artifacts SET is_active=false,activated_at=NULL WHERE id=$1", id); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{http.MethodGet, http.MethodHead} {
		w = call(method, "/downloads/"+name, map[string]string{"If-None-Match": etag})
		if w.Code != http.StatusNotFound || bytes.Contains(w.Body.Bytes(), archive) {
			t.Errorf("suspended %s download status=%d body=%s", method, w.Code, w.Body.String())
		}
	}
	w = call(http.MethodGet, "/v1/site-status", nil)
	var status struct {
		Downloads map[string]publicDownload `json:"downloads"`
	}
	if w.Code != http.StatusOK || json.Unmarshal(w.Body.Bytes(), &status) != nil || status.Downloads["macos"].Available {
		t.Error("suspended download remains publicly available in site status")
	}
}

func TestPublicDownloadRejectsUnpublishedPathsAndEscapingSymlinks(t *testing.T) {
	api, db, _ := testAPI(t)
	api.cfg.DownloadDir = t.TempDir()
	secret := []byte("outside download directory secret")
	outside := filepath.Join(t.TempDir(), "secret.zip")
	if err := os.WriteFile(outside, secret, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(api.cfg.DownloadDir, "unpublished.zip"), secret, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(api.cfg.DownloadDir, "escape.zip")); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(context.Background(), "INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256,is_active) VALUES('macos','1.0','escape.zip',$1,$2,true)", len(secret), strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/downloads/unknown.zip", "/downloads/unpublished.zip", "/downloads/escape.zip", "/downloads/%2e%2e", "/downloads/%2e%2e%2fsecret.zip", "/downloads/.upload-private.zip", "/downloads/subdir%2fsecret.zip", "/downloads/bad%5csecret.zip"} {
		r := httptest.NewRequest(http.MethodGet, "https://flowriver.test"+path, nil)
		w := httptest.NewRecorder()
		api.Handler().ServeHTTP(w, r)
		if w.Code != http.StatusNotFound || bytes.Contains(w.Body.Bytes(), secret) {
			t.Errorf("unsafe or unpublished %s status=%d body=%s", path, w.Code, w.Body.String())
		}
	}
}

func TestPublicDownloadFailsClosedOnDatabaseFailure(t *testing.T) {
	api, db, _ := testAPI(t)
	db.Close()
	r := httptest.NewRequest(http.MethodGet, "https://flowriver.test/downloads/FlowRiver.zip", nil)
	w := httptest.NewRecorder()
	api.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "temporarily_unavailable") {
		t.Fatalf("database unavailable status=%d body=%s", w.Code, w.Body.String())
	}
}

func TestPublicDownloadOutlivesOrdinaryWriteTimeout(t *testing.T) {
	api, db, _ := testAPI(t)
	api.cfg.DownloadDir = t.TempDir()
	name := "slow-transfer.zip"
	archive := bytes.Repeat([]byte("PK\x03\x04data"), 1<<20)
	if err := os.WriteFile(filepath.Join(api.cfg.DownloadDir, name), archive, 0o600); err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(archive)
	if _, err := db.Exec(context.Background(), "INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256,is_active) VALUES('macos','1.0',$1,$2,$3,true)", name, len(archive), hex.EncodeToString(digest[:])); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewUnstartedServer(api.Handler())
	server.Config.ReadTimeout = 200 * time.Millisecond
	server.Config.WriteTimeout = 200 * time.Millisecond
	server.Start()
	defer server.Close()
	client := server.Client()
	client.Timeout = 3 * time.Second
	resp, err := client.Get(server.URL + "/downloads/" + name)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	// Stop consuming long enough for the small ordinary write deadline to
	// expire while the archive is larger than the loopback socket buffers.
	time.Sleep(400 * time.Millisecond)
	got, err := io.ReadAll(resp.Body)
	if err != nil || resp.StatusCode != http.StatusOK || !bytes.Equal(got, archive) {
		t.Fatalf("slow download status=%d bytes=%d want=%d error=%v", resp.StatusCode, len(got), len(archive), err)
	}
}

func TestOrdinaryResponseRetainsShortWriteTimeout(t *testing.T) {
	api := &API{log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	server := httptest.NewUnstartedServer(api.requestBoundary(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(150 * time.Millisecond)
		_, _ = w.Write([]byte("ordinary response"))
	})))
	server.Config.WriteTimeout = 50 * time.Millisecond
	server.Start()
	defer server.Close()
	client := server.Client()
	client.Timeout = time.Second
	resp, err := client.Get(server.URL + "/ordinary")
	if resp != nil {
		defer resp.Body.Close()
	}
	if err == nil {
		t.Fatal("ordinary API unexpectedly outlived its short write timeout")
	}
}
