package adminapi

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

func (a *API) operations(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	pingStart := time.Now()
	if err := a.db.Ping(ctx); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	databaseLatency := time.Since(pingStart).Milliseconds()
	resources := readSystemResources()
	var backup struct {
		State                   string     `json:"state"`
		Code                    string     `json:"code,omitempty"`
		UpdatedAt               *time.Time `json:"updated_at"`
		ObjectName              string     `json:"object_name,omitempty"`
		Health                  string     `json:"health"`
		AgeSeconds              *int64     `json:"age_seconds"`
		ExpectedIntervalSeconds int64      `json:"expected_interval_seconds"`
	}
	err := a.db.QueryRow(ctx, `SELECT state,code,updated_at,object_name FROM backup_status WHERE singleton=true`).Scan(&backup.State, &backup.Code, &backup.UpdatedAt, &backup.ObjectName)
	if errors.Is(err, pgx.ErrNoRows) {
		backup.State = "unknown"
	} else if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	backup.ExpectedIntervalSeconds = 3600
	backup.Health = "unknown"
	if backup.UpdatedAt != nil {
		age := int64(time.Since(*backup.UpdatedAt).Seconds())
		if age < 0 {
			age = 0
		}
		backup.AgeSeconds = &age
		switch {
		case backup.State == "failure":
			backup.Health = "failure"
		case age > 7200:
			backup.Health = "stale"
		case backup.State == "running":
			backup.Health = "running"
		case backup.State == "success":
			backup.Health = "fresh"
		}
	}
	var drill struct {
		Result  string     `json:"result"`
		Summary string     `json:"summary"`
		At      *time.Time `json:"recorded_at"`
	}
	err = a.db.QueryRow(ctx, `SELECT result,summary,created_at FROM operations_status WHERE kind='restore_drill' ORDER BY created_at DESC,id DESC LIMIT 1`).Scan(&drill.Result, &drill.Summary, &drill.At)
	if errors.Is(err, pgx.ErrNoRows) {
		drill.Result = "not_recorded"
	} else if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, map[string]any{
		"api":           map[string]any{"state": "ready", "checked_at": time.Now().UTC()},
		"database":      map[string]any{"state": "ready", "ping_ms": databaseLatency, "checked_at": time.Now().UTC()},
		"process":       map[string]any{"started_at": a.startedAt, "uptime_seconds": int64(time.Since(a.startedAt).Seconds()), "resources": resources},
		"backup":        backup,
		"restore_drill": drill,
		"updated_at":    time.Now().UTC(),
	})
}

func (a *API) configStatus(w http.ResponseWriter, r *http.Request) {
	type item struct {
		Name   string `json:"name"`
		State  string `json:"state"`
		Detail string `json:"detail"`
	}
	emailState, emailDetail := "needs_verification", "SMTP settings are present; delivery receipt is not available from SMTP alone"
	if a.cfg.EmailMode != "smtp" || a.cfg.SMTPAddr == "" || a.cfg.SMTPFrom == "" {
		emailState = "not_configured"
		emailDetail = "SMTP mode and sender are required"
	}
	appleState, appleDetail := "needs_verification", "Apple credentials loaded; perform a real Sign in with Apple check"
	if !a.cfg.AppleEnabled || a.cfg.AppleTeamID == "" || a.cfg.AppleKeyID == "" {
		appleState = "not_configured"
		appleDetail = "Apple sign-in is disabled or credentials are incomplete"
	}
	journalState, journalDetail := "needs_verification", "Sending configuration exists; verify the independent receiver and a signed receipt"
	if a.cfg.SecurityJournalMode == "login_only" {
		journalState = "not_configured"
		journalDetail = "Login-only mode: account registration and login work; account deletion, identity revocation, and Apple revocation notifications remain unavailable without an off-host journal"
	} else if a.cfg.SecurityJournalEndpoint == "" || a.cfg.SecurityJournalToken == "" || len(a.cfg.SecurityJournalKey) != 32 {
		journalState = "not_configured"
		journalDetail = "Independent security journal credentials are incomplete"
	}
	adminNetworkState, adminNetworkDetail := allowlistState(len(a.cfg.AdminAllowedNetworks)), allowlistDetail(len(a.cfg.AdminAllowedNetworks))
	v4, v6 := false, false
	for _, network := range a.cfg.AdminAllowedNetworks {
		ones, bits := network.Mask.Size()
		if ones == 0 {
			if bits == 32 && network.Contains(net.ParseIP("203.0.113.1")) {
				v4 = true
			}
			if bits == 128 {
				v6 = true
			}
		}
	}
	if v4 && v6 {
		adminNetworkDetail = "Source networks unrestricted by owner choice; password, TOTP and sensitive-action reauthentication remain required"
	}
	writeJSON(w, 200, map[string]any{"items": []item{
		{Name: "Email OTP", State: emailState, Detail: emailDetail},
		{Name: "Sign in with Apple", State: appleState, Detail: appleDetail},
		{Name: "Off-host security journal", State: journalState, Detail: journalDetail},
		{Name: "Administrator MFA", State: "configured", Detail: "Administrator requires password and TOTP"},
		{Name: "Administrator source-IP allowlist", State: adminNetworkState, Detail: adminNetworkDetail},
	}, "updated_at": time.Now().UTC()})
}

func allowlistState(count int) string {
	if count > 0 {
		return "configured"
	}
	return "not_configured"
}

func allowlistDetail(count int) string {
	if count > 0 {
		return fmt.Sprintf("Management requests are restricted to %d configured network(s)", count)
	}
	return "No source-IP restrictions are configured"
}

func (a *API) RunMaintenance(ctx context.Context) {
	ticker := time.NewTicker(6 * time.Hour)
	defer ticker.Stop()
	for {
		if _, err := a.db.Exec(ctx, `DELETE FROM admin_auth_buckets WHERE expires_at<now()`); err != nil && ctx.Err() == nil {
			a.log.Warn("administrator auth-limit cleanup failed")
		}
		if _, err := a.db.Exec(ctx, `DELETE FROM admin_login_challenges WHERE expires_at<now()`); err != nil && ctx.Err() == nil {
			a.log.Warn("administrator login-challenge cleanup failed")
		}
		if _, err := a.db.Exec(ctx, `DELETE FROM admin_sessions WHERE absolute_expires_at<now() OR revoked_at<now()-interval '30 days'`); err != nil && ctx.Err() == nil {
			a.log.Warn("administrator session cleanup failed")
		}
		if _, err := a.db.Exec(ctx, `DELETE FROM admin_audit_events WHERE created_at<now()-interval '90 days'`); err != nil && ctx.Err() == nil {
			a.log.Warn("administrator audit retention cleanup failed")
		}
		if _, err := a.db.Exec(ctx, `DELETE FROM admin_action_requests WHERE expires_at<now()`); err != nil && ctx.Err() == nil {
			a.log.Warn("administrator request-id cleanup failed")
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}
