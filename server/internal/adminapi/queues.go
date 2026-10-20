package adminapi

import (
	"encoding/base64"
	"flowriver/server/internal/secure"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func (a *API) devices(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	state := r.URL.Query().Get("state")
	if len(query) > 320 || strings.ContainsAny(query, "\x00\r\n") || (state != "" && state != "active" && state != "revoked") {
		writeError(w, apiError{Status: 400, Code: "invalid_query"})
		return
	}
	userID := strings.ToLower(r.URL.Query().Get("user_id"))
	if userID != "" && !isUUID(userID) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	var after time.Time
	var afterID string
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		decoded, ok := decodeDeviceCursor(raw)
		if !ok {
			writeError(w, apiError{Status: 400, Code: "invalid_cursor"})
			return
		}
		after, afterID = decoded.Timestamp, decoded.ID
	}
	rows, err := a.db.Query(r.Context(), `
		SELECT d.id::text,d.instance_id::text,d.platform,d.display_name,d.created_at,d.last_seen_at,d.revoked_at,
		 u.id::text,u.status,(u.disabled_at IS NOT NULL),COALESCE(min(i.email_display) FILTER(WHERE i.provider='email'),''),
		 (SELECT count(*)::int FROM sessions s WHERE s.device_id=d.id AND s.status='active' AND s.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now() AND d.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL)
		FROM devices d JOIN users u ON u.id=d.user_id LEFT JOIN identities i ON i.user_id=u.id
		WHERE ($1::uuid IS NULL OR d.user_id=$1::uuid)
		  AND ($2::timestamptz IS NULL OR (d.last_seen_at,d.id)<($2::timestamptz,$3::uuid))
		  AND ($5='' OR lower(d.display_name) LIKE '%'||$5||'%' OR d.platform LIKE '%'||$5||'%' OR d.id::text LIKE '%'||$5||'%' OR u.id::text LIKE '%'||$5||'%'
		    OR EXISTS(SELECT 1 FROM identities ei WHERE ei.user_id=u.id AND lower(ei.email_display) LIKE '%'||$5||'%'))
		  AND ($6='' OR ($6='revoked' AND d.revoked_at IS NOT NULL) OR ($6='active' AND d.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL))
		GROUP BY d.id,u.id ORDER BY d.last_seen_at DESC,d.id DESC LIMIT $4`, nullIfEmpty(userID), nullableTimestamp(after), nullIfEmpty(afterID), limit+1, strings.ToLower(escapeLike(query)), state)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type row struct {
		ID             string     `json:"id"`
		InstanceID     string     `json:"instance_id"`
		Platform       string     `json:"platform"`
		DisplayName    string     `json:"display_name"`
		CreatedAt      time.Time  `json:"created_at"`
		LastSeenAt     time.Time  `json:"last_seen_at"`
		RevokedAt      *time.Time `json:"revoked_at"`
		UserID         string     `json:"user_id"`
		UserStatus     string     `json:"user_status"`
		UserDisabled   bool       `json:"user_disabled"`
		UserEmail      string     `json:"user_email"`
		ActiveSessions int        `json:"active_sessions"`
	}
	items := make([]row, 0, limit+1)
	for rows.Next() {
		var item row
		if err := rows.Scan(&item.ID, &item.InstanceID, &item.Platform, &item.DisplayName, &item.CreatedAt, &item.LastSeenAt, &item.RevokedAt, &item.UserID, &item.UserStatus, &item.UserDisabled, &item.UserEmail, &item.ActiveSessions); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		item.UserEmail = maskEmail(item.UserEmail)
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	next := ""
	if len(items) > limit {
		last := items[limit-1]
		next = encodeDeviceCursor(last.LastSeenAt, last.ID)
		items = items[:limit]
	}
	if query != "" {
		s := currentSession(r)
		target := fmt.Sprintf("%x", secure.MAC(a.cfg.AdminAuditHMACKey, "admin-device-search", query))
		if err := a.audit(r.Context(), s.AdminID, "admin.device.search", "device_query", target, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	writeJSON(w, 200, map[string]any{"devices": items, "next_cursor": next, "updated_at": time.Now().UTC()})
}

func (a *API) mailJobs(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	statusFilter := r.URL.Query().Get("status")
	if statusFilter != "" && statusFilter != "queued" && statusFilter != "waiting_retry" && statusFilter != "expired" && statusFilter != "failed" && statusFilter != "handed_to_smtp" && statusFilter != "cancelled" && statusFilter != "delivery_unconfirmed" {
		writeError(w, apiError{Status: 400, Code: "invalid_status_filter"})
		return
	}
	rows, err := a.db.Query(r.Context(), `SELECT id::text,created_at,available_at,expires_at,attempts,completed_at,last_error_code,
		CASE WHEN last_error_code='job_expired' OR (completed_at IS NULL AND expires_at<=now()) THEN 'expired'
 WHEN last_error_code='challenge_inactive' THEN 'cancelled'
 WHEN last_error_code='email_delivery_unconfirmed' THEN 'delivery_unconfirmed'
		     WHEN completed_at IS NULL AND available_at>now() THEN 'waiting_retry'
		     WHEN completed_at IS NULL THEN 'queued'
		     WHEN last_error_code IS NOT NULL THEN 'failed'
		     ELSE 'handed_to_smtp' END
		FROM outbox_jobs WHERE kind='email_otp'
		  AND ($1='' OR (CASE WHEN last_error_code='job_expired' OR (completed_at IS NULL AND expires_at<=now()) THEN 'expired'
 WHEN last_error_code='challenge_inactive' THEN 'cancelled'
 WHEN last_error_code='email_delivery_unconfirmed' THEN 'delivery_unconfirmed'
		       WHEN completed_at IS NULL AND available_at>now() THEN 'waiting_retry'
		       WHEN completed_at IS NULL THEN 'queued'
		       WHEN last_error_code IS NOT NULL THEN 'failed'
		       ELSE 'handed_to_smtp' END)=$1)
		ORDER BY created_at DESC,id DESC LIMIT $2`, statusFilter, limit)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID          string     `json:"id"`
		CreatedAt   time.Time  `json:"created_at"`
		AvailableAt time.Time  `json:"available_at"`
		ExpiresAt   time.Time  `json:"expires_at"`
		Attempts    int        `json:"attempts"`
		CompletedAt *time.Time `json:"completed_at"`
		ErrorCode   *string    `json:"error_code"`
		Status      string     `json:"status"`
	}
	items := make([]item, 0, limit)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.CreatedAt, &it.AvailableAt, &it.ExpiresAt, &it.Attempts, &it.CompletedAt, &it.ErrorCode, &it.Status); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, map[string]any{"jobs": items, "updated_at": time.Now().UTC(), "provider_delivery_receipts": false})
}

func (a *API) securityEvents(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	rows, err := a.db.Query(r.Context(), `SELECT e.event_id::text,e.old_user_id::text,COALESCE(e.identity_id::text,''),e.event_type,e.occurred_at,e.available_at,e.attempts,e.delivered_at,e.last_error_code,
		COALESCE((SELECT CASE WHEN d.completed_at IS NOT NULL THEN 'complete' WHEN d.apple_revocation_status='manual_action_required' THEN 'manual_action_required' ELSE 'pending' END FROM deletion_jobs d WHERE d.session_id=e.session_id ORDER BY d.requested_at DESC LIMIT 1),'')
		FROM security_event_outbox e ORDER BY e.occurred_at DESC,e.event_id DESC LIMIT $1`, limit)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID             string     `json:"event_id"`
		UserID         string     `json:"user_id"`
		IdentityID     string     `json:"identity_id,omitempty"`
		Kind           string     `json:"kind"`
		OccurredAt     time.Time  `json:"occurred_at"`
		AvailableAt    time.Time  `json:"available_at"`
		Attempts       int        `json:"attempts"`
		DeliveredAt    *time.Time `json:"delivered_at"`
		ErrorCode      *string    `json:"error_code"`
		DeletionStatus string     `json:"deletion_status,omitempty"`
	}
	items := make([]item, 0, limit)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.UserID, &it.IdentityID, &it.Kind, &it.OccurredAt, &it.AvailableAt, &it.Attempts, &it.DeliveredAt, &it.ErrorCode, &it.DeletionStatus); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, map[string]any{"events": items, "updated_at": time.Now().UTC()})
}

func (a *API) auditEvents(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	before, err := parseAuditCursor(r.URL.Query().Get("before"))
	if err != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_cursor"})
		return
	}
	query := r.URL.Query()
	action := strings.TrimSpace(query.Get("action"))
	result := strings.TrimSpace(query.Get("result"))
	if result != "" && result != "success" && result != "denied" && result != "failure" {
		writeError(w, apiError{Status: 400, Code: "invalid_result_filter"})
		return
	}
	adminID := strings.ToLower(strings.TrimSpace(query.Get("admin_id")))
	if adminID != "" && !isUUID(adminID) {
		writeError(w, apiError{Status: 400, Code: "invalid_admin_id"})
		return
	}
	days := 0
	if raw := query.Get("days"); raw != "" {
		parsed, parseErr := strconv.Atoi(raw)
		if parseErr != nil || parsed < 1 || parsed > 90 {
			writeError(w, apiError{Status: 400, Code: "invalid_days"})
			return
		}
		days = parsed
	}
	rows, err := a.db.Query(r.Context(), `SELECT id,COALESCE(admin_id::text,''),action,target_type,target_id,reason_code,result,request_id,created_at
		FROM admin_audit_events
		WHERE ($1::bigint IS NULL OR id<$1)
		  AND ($2='' OR action=$2)
		  AND ($3='' OR result=$3)
		  AND ($4::uuid IS NULL OR admin_id=$4::uuid)
		  AND ($5::int=0 OR created_at>now()-make_interval(days=>$5::int))
		ORDER BY id DESC LIMIT $6`, before, action, result, nullIfEmpty(adminID), days, limit)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID         int64     `json:"id"`
		AdminID    string    `json:"admin_id"`
		Action     string    `json:"action"`
		TargetType string    `json:"target_type"`
		TargetID   string    `json:"target_id"`
		Reason     string    `json:"reason_code"`
		Result     string    `json:"result"`
		RequestID  string    `json:"request_id"`
		CreatedAt  time.Time `json:"created_at"`
	}
	items := make([]item, 0, limit)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.AdminID, &it.Action, &it.TargetType, &it.TargetID, &it.Reason, &it.Result, &it.RequestID, &it.CreatedAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	var next *int64
	if len(items) == limit {
		id := items[len(items)-1].ID
		next = &id
	}
	writeJSON(w, 200, map[string]any{"events": items, "next_before": next, "retention_days": 90})
}

func nullableTimestamp(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value
}

type deviceCursor struct {
	Timestamp time.Time
	ID        string
}

func encodeDeviceCursor(at time.Time, id string) string {
	return base64.RawURLEncoding.EncodeToString([]byte(at.UTC().Format(time.RFC3339Nano) + "|" + id))
}
func decodeDeviceCursor(value string) (deviceCursor, bool) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return deviceCursor{}, false
	}
	parts := strings.SplitN(string(decoded), "|", 2)
	if len(parts) != 2 || !isUUID(parts[1]) {
		return deviceCursor{}, false
	}
	at, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return deviceCursor{}, false
	}
	return deviceCursor{Timestamp: at, ID: parts[1]}, true
}
func parseAuditCursor(value string) (any, error) {
	if value == "" {
		return nil, nil
	}
	id, err := strconv.ParseInt(value, 10, 64)
	if err != nil || id < 1 {
		return nil, err
	}
	return id, nil
}
