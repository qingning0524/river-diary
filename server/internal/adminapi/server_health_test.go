package adminapi

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"strings"
	"testing"
)

func TestOperationsMarksOldBackupSuccessAsStale(t *testing.T) {
	f := testAdminAPI(t)
	if _, err := f.db.Exec(context.Background(), `INSERT INTO backup_status(singleton,state,updated_at) VALUES(true,'success',now()-interval '1 day')`); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodGet, "/operations", nil, "")
	var d struct {
		Backup struct {
			State  string `json:"state"`
			Health string `json:"health"`
			Age    *int64 `json:"age_seconds"`
		} `json:"backup"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &d) != nil || d.Backup.State != "success" || d.Backup.Health != "stale" || d.Backup.Age == nil {
		t.Fatalf("old success falsely displayed healthy: %s", w.Body.String())
	}
}
func TestConfigDescribesAuthenticatedAccessForUniversalNetworks(t *testing.T) {
	f := testAdminAPI(t)
	for _, value := range []string{"0.0.0.0/0", "::/0"} {
		_, network, _ := net.ParseCIDR(value)
		f.api.cfg.AdminAllowedNetworks = append(f.api.cfg.AdminAllowedNetworks, *network)
	}
	w := f.request(http.MethodGet, "/config-status", nil, "")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "unrestricted") {
		t.Fatalf("universal networks described as restrictive allowlist: %s", w.Body.String())
	}
}
func TestMailQueueDoesNotLabelSkippedOrUnconfirmedMessagesDelivered(t *testing.T) {
	f := testAdminAPI(t)
	for _, code := range []string{"job_expired", "challenge_inactive", "email_delivery_unconfirmed"} {
		if _, err := f.db.Exec(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,created_at,available_at,expires_at,completed_at,last_error_code) VALUES('email_otp',''::bytea,now(),now(),now()+interval '10 minutes',now(),$1)`, code); err != nil {
			t.Fatal(err)
		}
	}
	w := f.request(http.MethodGet, "/mail-jobs", nil, "")
	if w.Code != 200 || strings.Contains(w.Body.String(), "handed_to_smtp") {
		t.Fatal("skipped/unconfirmed message counted as delivered")
	}
	for _, state := range []string{"expired", "cancelled", "delivery_unconfirmed"} {
		if !strings.Contains(w.Body.String(), `"status":"`+state+`"`) {
			t.Fatalf("missing queue state %s: %s", state, w.Body.String())
		}
	}
}

func TestMailRetryPreservesTerminalHistoryAndOnlyRetriesValidPendingTasks(t *testing.T) {
	f := testAdminAPI(t)
	for _, scenario := range []struct {
		name      string
		completed bool
		expiry    string
		lease     string
		code      string
		want      int
	}{
		{"terminal failure", true, "10 minutes", "-1 second", "email_delivery_failed", 409},
		{"delivery uncertain", true, "10 minutes", "-1 second", "email_delivery_unconfirmed", 409},
		{"expired", false, "-1 second", "-1 second", "email_delivery_failed", 409},
		{"leased", false, "10 minutes", "10 seconds", "email_delivery_failed", 409},
		{"valid pending retry", false, "10 minutes", "-1 second", "email_delivery_failed", 200},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			var id string
			err := f.db.QueryRow(context.Background(), `INSERT INTO outbox_jobs(kind,payload_ciphertext,available_at,expires_at,lease_until,completed_at,last_error_code,attempts) VALUES('email_otp',$1,now()+interval '1 minute',now()+$2::interval,now()+$3::interval,CASE WHEN $4::boolean THEN now() ELSE NULL END,$5,2) RETURNING id::text`, []byte("fixture payload"), scenario.expiry, scenario.lease, scenario.completed, scenario.code).Scan(&id)
			if err != nil {
				t.Fatal(err)
			}
			w := f.request(http.MethodPost, "/mail-jobs/"+id+"/retry", strings.NewReader(`{}`), "application/json")
			if w.Code != scenario.want {
				t.Fatalf("retry status %d, expected %d: %s", w.Code, scenario.want, w.Body.String())
			}
			var attempts int
			var isTerminal bool
			if err := f.db.QueryRow(context.Background(), `SELECT attempts,completed_at IS NOT NULL FROM outbox_jobs WHERE id=$1`, id).Scan(&attempts, &isTerminal); err != nil {
				t.Fatal(err)
			}
			if scenario.want == 409 && (attempts != 2 || isTerminal != scenario.completed) {
				t.Fatal("invalid retry mutated job history")
			}
		})
	}
}
