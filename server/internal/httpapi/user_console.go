package httpapi

import (
	"encoding/json"
	"flowriver/server/internal/secure"
	"net/http"
	"strings"
	"time"
)

func (a *API) consoleSessions(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	rows, err := a.db.Query(ctx, `SELECT s.id::text,d.display_name,d.platform,s.created_at,s.last_seen_at,s.idle_expires_at,s.absolute_expires_at,
 (s.status='active' AND s.revoked_at IS NULL AND d.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now()),s.id::text=$2
 FROM sessions s JOIN devices d ON d.id=s.device_id WHERE s.user_id=$1 ORDER BY s.created_at DESC LIMIT 200`, p.UserID, p.SessionID)
	if err != nil {
		a.databaseFailure(w, r, "console_sessions")
		return
	}
	defer rows.Close()
	type item struct {
		ID       string    `json:"id"`
		Device   string    `json:"device_name"`
		Platform string    `json:"platform"`
		Created  time.Time `json:"created_at"`
		Seen     time.Time `json:"last_seen_at"`
		Idle     time.Time `json:"idle_expires_at"`
		Expiry   time.Time `json:"absolute_expires_at"`
		Active   bool      `json:"active"`
		Current  bool      `json:"current"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.ID, &v.Device, &v.Platform, &v.Created, &v.Seen, &v.Idle, &v.Expiry, &v.Active, &v.Current); err != nil {
			a.databaseFailure(w, r, "console_sessions_scan")
			return
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		a.databaseFailure(w, r, "console_sessions_rows")
		return
	}
	writeJSON(w, 200, map[string]any{"sessions": items, "limit": 200})
}
func (a *API) consoleRevokeSession(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	id := r.PathValue("id")
	if !validUUID(id) {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "console_revoke_begin")
		return
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2`, id, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "console_revoke")
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	if err = audit(ctx, tx, p.UserID, "session_revoked", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "console_revoke_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "console_revoke_commit")
		return
	}
	w.WriteHeader(204)
}
func (a *API) consoleActivity(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	rows, err := a.db.Query(ctx, `SELECT kind,created_at FROM audit_events WHERE user_id=$1 ORDER BY created_at DESC,id DESC LIMIT 100`, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "console_activity")
		return
	}
	defer rows.Close()
	type item struct {
		Kind string    `json:"kind"`
		At   time.Time `json:"created_at"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.Kind, &v.At); err != nil {
			a.databaseFailure(w, r, "console_activity_scan")
			return
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		a.databaseFailure(w, r, "console_activity_rows")
		return
	}
	writeJSON(w, 200, map[string]any{"events": items, "limit": 100})
}
func (a *API) consoleRedemptions(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	rows, err := a.db.Query(ctx, `SELECT r.product_code,r.granted_at,r.starts_at,r.expires_at,c.code_suffix FROM activation_redemptions r JOIN activation_codes c ON c.id=r.activation_code_id WHERE r.user_id=$1 ORDER BY r.granted_at DESC LIMIT 100`, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "console_redemptions")
		return
	}
	defer rows.Close()
	type item struct {
		Product string     `json:"product_code"`
		At      time.Time  `json:"granted_at"`
		Start   time.Time  `json:"starts_at"`
		Expiry  *time.Time `json:"expires_at"`
		Suffix  string     `json:"code_suffix"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.Product, &v.At, &v.Start, &v.Expiry, &v.Suffix); err != nil {
			a.databaseFailure(w, r, "console_redemptions_scan")
			return
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		a.databaseFailure(w, r, "console_redemptions_rows")
		return
	}
	writeJSON(w, 200, map[string]any{"redemptions": items, "limit": 100})
}
func (a *API) consoleFeedback(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	rows, err := a.db.Query(ctx, `SELECT id::text,subject,body,status,reply_body,replied_at,created_at FROM feedback_messages WHERE user_id=$1 ORDER BY created_at DESC LIMIT 100`, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "console_feedback")
		return
	}
	defer rows.Close()
	type item struct {
		ID      string     `json:"id"`
		Subject string     `json:"subject"`
		Body    string     `json:"body"`
		Status  string     `json:"status"`
		Reply   string     `json:"reply_body"`
		Replied *time.Time `json:"replied_at"`
		Created time.Time  `json:"created_at"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.ID, &v.Subject, &v.Body, &v.Status, &v.Reply, &v.Replied, &v.Created); err != nil {
			a.databaseFailure(w, r, "console_feedback_scan")
			return
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		a.databaseFailure(w, r, "console_feedback_rows")
		return
	}
	writeJSON(w, 200, map[string]any{"messages": items, "limit": 100})
}
func (a *API) consoleSubmitFeedback(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	var input struct {
		Subject string `json:"subject"`
		Body    string `json:"body"`
	}
	if err = decodeJSON(w, r, &input); err != nil {
		writeError(w, r, err)
		return
	}
	input.Subject = strings.TrimSpace(input.Subject)
	input.Body = strings.TrimSpace(input.Body)
	if len([]rune(input.Subject)) > 200 || len([]rune(input.Body)) < 5 || len([]rune(input.Body)) > 4000 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "console_feedback_begin")
		return
	}
	defer tx.Rollback(ctx)
	scope := "user-feedback:" + p.UserID
	mac := secure.MAC(a.authMAC, "user-feedback-v1", input.Subject, input.Body)
	if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,915310))`, scope); err != nil {
		a.databaseFailure(w, r, "console_feedback_lock")
		return
	}
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, mac); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		writeJSONBytes(w, 202, cached)
		return
	}
	for _, limit := range []struct {
		key    string
		max    int
		period time.Duration
	}{{"user-feedback-hour:" + p.UserID, 5, time.Hour}, {"feedback-global-day", 300, 24 * time.Hour}} {
		count, e := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if e != nil {
			a.databaseFailure(w, r, "console_feedback_rate")
			return
		}
		if count > limit.max {
			if e = tx.Commit(ctx); e != nil {
				a.databaseFailure(w, r, "console_feedback_limit_commit")
				return
			}
			writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
			return
		}
	}
	var id string
	err = tx.QueryRow(ctx, `INSERT INTO feedback_messages(user_id,contact_email,subject,body) VALUES($1,COALESCE((SELECT email_canonical FROM identities WHERE user_id=$1 AND provider='email' AND status='active' LIMIT 1),''),$2,$3) RETURNING id::text`, p.UserID, input.Subject, input.Body).Scan(&id)
	if err != nil {
		a.databaseFailure(w, r, "console_feedback_insert")
		return
	}
	body, _ := json.Marshal(map[string]string{"id": id, "message": "反馈已收到，可在此查看处理进度。"})
	if err = a.saveResponse(ctx, tx, scope, key, mac, body); err != nil {
		a.databaseFailure(w, r, "console_feedback_save")
		return
	}
	if err = audit(ctx, tx, p.UserID, "feedback_submitted", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "console_feedback_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "console_feedback_commit")
		return
	}
	writeJSONBytes(w, 202, body)
}
func writeJSONBytes(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}
