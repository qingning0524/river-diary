package adminapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"flowriver/server/internal/secure"
)

func TestDeviceSearchCoversAllPagesAndDisabledAccounts(t *testing.T) {
	f := testAdminAPI(t)
	var owner, blocked string
	if err := f.db.QueryRow(context.Background(), `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	if err := f.db.QueryRow(context.Background(), `INSERT INTO users(disabled_at) VALUES(now()) RETURNING id::text`).Scan(&blocked); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(context.Background(), `INSERT INTO devices(user_id,instance_id,platform,display_name,last_seen_at)
 SELECT $1::uuid,gen_random_uuid(),'macos',CASE WHEN i=105 THEN 'Legacy Desk' ELSE 'Desk '||i END,now()-i*interval '1 minute' FROM generate_series(1,105) i`, owner); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(context.Background(), `INSERT INTO devices(user_id,instance_id,platform,display_name) VALUES($1,gen_random_uuid(),'ios','Blocked phone')`, blocked); err != nil {
		t.Fatal(err)
	}
	type row struct {
		ID       string `json:"id"`
		Disabled bool   `json:"user_disabled"`
	}
	read := func(path string) ([]row, string) {
		t.Helper()
		w := f.request(http.MethodGet, path, nil, "")
		var result struct {
			Devices []row  `json:"devices"`
			Cursor  string `json:"next_cursor"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &result) != nil {
			t.Fatalf("devices status=%d body=%s", w.Code, w.Body.String())
		}
		return result.Devices, result.Cursor
	}
	found, _ := read("/devices?q=" + url.QueryEscape("Legacy Desk"))
	if len(found) != 1 {
		t.Fatalf("older device search stopped at first page: %d", len(found))
	}
	page, cursor := read("/devices?limit=40&state=active")
	ids := map[string]bool{}
	for {
		for _, item := range page {
			if item.Disabled || ids[item.ID] {
				t.Fatal("disabled or repeated device in active pagination")
			}
			ids[item.ID] = true
		}
		if cursor == "" {
			break
		}
		page, cursor = read("/devices?limit=40&state=active&cursor=" + url.QueryEscape(cursor))
	}
	if len(ids) != 105 {
		t.Fatalf("pagination lost records: %d", len(ids))
	}
	found, _ = read("/devices?q=" + url.QueryEscape("Blocked phone"))
	if len(found) != 1 || !found[0].Disabled {
		t.Fatal("disabled owner state missing")
	}
}

func TestCurrentAdminCannotInvalidateOwnAuthenticator(t *testing.T) {
	f := testAdminAPI(t)
	var id string
	var before []byte
	if err := f.db.QueryRow(context.Background(), `SELECT id::text,totp_secret_ciphertext FROM admin_accounts WHERE username='regression-fixture'`).Scan(&id, &before); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodPost, "/admins/"+id+"/totp-reset", strings.NewReader(`{"reason_code":"other"}`), "application/json")
	if w.Code != http.StatusConflict {
		t.Fatalf("self-reset must be rejected before changing credentials: status=%d body=%s", w.Code, w.Body.String())
	}
	var after []byte
	if err := f.db.QueryRow(context.Background(), `SELECT totp_secret_ciphertext FROM admin_accounts WHERE id=$1`, id).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatal("self-reset changed authenticator")
	}
	if w = f.request(http.MethodGet, "/overview", nil, ""); w.Code != http.StatusOK {
		t.Fatal("self-reset invalidated current login")
	}
}

func TestRateLimitLookupPreservesEmailLocalCaseAndFailsClosed(t *testing.T) {
	t.Run("canonical address", func(t *testing.T) {
		f := testAdminAPI(t)
		start := time.Now().UTC().Truncate(time.Hour)
		mac := secure.MAC(f.api.cfg.AuthHMACKey, "rate-limit-v1", "email-hour:Owner@example.test", strconv.FormatInt(start.Unix(), 10))
		if _, err := f.db.Exec(context.Background(), `INSERT INTO rate_limit_buckets(bucket_mac,window_start,hits,expires_at) VALUES($1,$2,5,$3)`, mac, start, start.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		w := f.request(http.MethodPost, "/ratelimits/lookup", strings.NewReader(`{"kind":"email_hour","value":"Owner@EXAMPLE.TEST"}`), "application/json")
		var data struct {
			Found bool `json:"found"`
			Hits  int  `json:"hits"`
		}
		if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &data) != nil || !data.Found || data.Hits != 5 {
			t.Fatalf("lookup must use login canonicalization: %d %s", w.Code, w.Body.String())
		}
		w = f.request(http.MethodPost, "/ratelimits/clear", strings.NewReader(`{"kind":"email_hour","value":"Owner@EXAMPLE.TEST"}`), "application/json")
		if w.Code != 200 {
			t.Fatal(w.Body.String())
		}
		var count int
		if err := f.db.QueryRow(context.Background(), `SELECT count(*) FROM rate_limit_buckets WHERE bucket_mac=$1`, mac).Scan(&count); err != nil || count != 0 {
			t.Fatal("clear did not remove actual login bucket")
		}
	})
	t.Run("database failure", func(t *testing.T) {
		f := testAdminAPI(t)
		if _, err := f.db.Exec(context.Background(), `ALTER TABLE rate_limit_buckets RENAME TO unavailable_rate_buckets`); err != nil {
			t.Fatal(err)
		}
		w := f.request(http.MethodPost, "/ratelimits/lookup", strings.NewReader(`{"kind":"email_hour","value":"owner@example.test"}`), "application/json")
		if w.Code != http.StatusServiceUnavailable {
			t.Fatalf("database failure must not be reported as no limit: %d %s", w.Code, w.Body.String())
		}
	})
}

func TestInboundMutationsRollBackWithoutAudit(t *testing.T) {
	for _, action := range []string{"read", "delete"} {
		t.Run(action, func(t *testing.T) {
			f := testAdminAPI(t)
			var id string
			if err := f.db.QueryRow(context.Background(), `INSERT INTO inbound_mail(from_addr,subject,text_body) VALUES('qa@example.test','audit fixture','test message') RETURNING id::text`).Scan(&id); err != nil {
				t.Fatal(err)
			}
			if _, err := f.db.Exec(context.Background(), `ALTER TABLE admin_audit_events ADD CONSTRAINT force_audit_failure CHECK (action NOT LIKE 'admin.inbound.%')`); err != nil {
				t.Fatal(err)
			}
			method, path := http.MethodPost, "/mailbox/inbound/"+id+"/read"
			if action == "delete" {
				method, path = http.MethodDelete, "/mailbox/inbound/"+id
			}
			w := f.request(method, path, nil, "")
			if w.Code != http.StatusServiceUnavailable {
				t.Fatalf("failed audit must reject mutation: %d %s", w.Code, w.Body.String())
			}
			var status string
			if err := f.db.QueryRow(context.Background(), `SELECT status FROM inbound_mail WHERE id=$1`, id).Scan(&status); err != nil || status != "new" {
				t.Fatalf("mutation escaped rollback: %q %v", status, err)
			}
		})
	}
}

func TestDownloadCannotPublishMissingOrWrongFile(t *testing.T) {
	f := testAdminAPI(t)
	var id string
	if err := f.db.QueryRow(context.Background(), `INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256) VALUES('macos','qa','missing.zip',12,$1) RETURNING id::text`, strings.Repeat("a", 64)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodPost, "/downloads/"+id+"/activate", nil, "")
	if w.Code != http.StatusConflict {
		t.Fatalf("missing archive must not be published: %d %s", w.Code, w.Body.String())
	}
	var active bool
	if err := f.db.QueryRow(context.Background(), `SELECT is_active FROM download_artifacts WHERE id=$1`, id).Scan(&active); err != nil || active {
		t.Fatal("missing file was made available")
	}
}

func TestStatisticsUseShanghaiCalendarDays(t *testing.T) {
	f := testAdminAPI(t)
	loc, _ := time.LoadLocation("Asia/Shanghai")
	now := time.Now().In(loc)
	day := time.Date(now.Year(), now.Month(), now.Day()-1, 0, 30, 0, 0, loc)
	if _, err := f.db.Exec(context.Background(), `INSERT INTO users(created_at) VALUES($1)`, day); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodGet, "/stats?days=7", nil, "")
	var data struct {
		Signups []struct {
			Date  string `json:"date"`
			Count int    `json:"count"`
		} `json:"signups"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &data) != nil {
		t.Fatal(w.Body.String())
	}
	counts := map[string]int{}
	for _, point := range data.Signups {
		counts[point.Date] = point.Count
	}
	if counts[day.Format("2006-01-02")] != 1 || counts[day.AddDate(0, 0, -1).Format("2006-01-02")] != 0 {
		t.Fatal(fmt.Sprintf("00:30 Shanghai signup assigned to wrong day: %+v", data.Signups))
	}
}
