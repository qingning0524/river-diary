package adminapi

import (
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

// ---- 运营统计 ----

func (a *API) stats(w http.ResponseWriter, r *http.Request) {
	days := 30
	if raw := r.URL.Query().Get("days"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 7 || parsed > 90 {
			writeError(w, apiError{Status: 400, Code: "invalid_days"})
			return
		}
		days = parsed
	}
	type series struct {
		Date  string `json:"date"`
		Count int    `json:"count"`
	}
	type mailPoint struct {
		Date   string `json:"date"`
		Total  int    `json:"total"`
		Failed int    `json:"failed"`
	}
	var signups, redemptions []series
	var mail []mailPoint
	signupRows, err := a.db.Query(r.Context(), `SELECT to_char(d,'YYYY-MM-DD'),count(u.id)::int
		FROM generate_series(date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai')-make_interval(days=>$1-1), date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai'), '1 day') d
		LEFT JOIN users u ON u.created_at >= d AT TIME ZONE 'Asia/Shanghai' AND u.created_at < (d+interval '1 day') AT TIME ZONE 'Asia/Shanghai' GROUP BY d ORDER BY d`, days)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for signupRows.Next() {
		var point series
		if err := signupRows.Scan(&point.Date, &point.Count); err != nil {
			signupRows.Close()
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		signups = append(signups, point)
	}
	if err := signupRows.Err(); err != nil {
		signupRows.Close()
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	signupRows.Close()
	redeemRows, err := a.db.Query(r.Context(), `SELECT to_char(d,'YYYY-MM-DD'),count(x.id)::int
		FROM generate_series(date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai')-make_interval(days=>$1-1), date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai'), '1 day') d
		LEFT JOIN activation_redemptions x ON x.granted_at >= d AT TIME ZONE 'Asia/Shanghai' AND x.granted_at < (d+interval '1 day') AT TIME ZONE 'Asia/Shanghai' GROUP BY d ORDER BY d`, days)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for redeemRows.Next() {
		var point series
		if err := redeemRows.Scan(&point.Date, &point.Count); err != nil {
			redeemRows.Close()
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		redemptions = append(redemptions, point)
	}
	if err := redeemRows.Err(); err != nil {
		redeemRows.Close()
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	redeemRows.Close()
	mailRows, err := a.db.Query(r.Context(), `SELECT to_char(d,'YYYY-MM-DD'),count(j.id)::int,count(j.id) FILTER (WHERE j.last_error_code IS NOT NULL AND j.last_error_code NOT IN ('job_expired','challenge_inactive'))::int
		FROM generate_series(date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai')-make_interval(days=>$1-1), date_trunc('day',now() AT TIME ZONE 'Asia/Shanghai'), '1 day') d
		LEFT JOIN outbox_jobs j ON j.kind='email_otp' AND j.created_at >= d AT TIME ZONE 'Asia/Shanghai' AND j.created_at < (d+interval '1 day') AT TIME ZONE 'Asia/Shanghai' GROUP BY d ORDER BY d`, days)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for mailRows.Next() {
		var point mailPoint
		if err := mailRows.Scan(&point.Date, &point.Total, &point.Failed); err != nil {
			mailRows.Close()
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		mail = append(mail, point)
	}
	if err := mailRows.Err(); err != nil {
		mailRows.Close()
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	mailRows.Close()
	var activeSessions, devices, usersTotal int
	if err := a.db.QueryRow(r.Context(), `SELECT
		(SELECT count(*)::int FROM sessions s JOIN users u ON u.id=s.user_id JOIN devices d ON d.id=s.device_id
		 WHERE s.status='active' AND s.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now()
		   AND d.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL),
		(SELECT count(*)::int FROM devices),
		(SELECT count(*)::int FROM users)`).Scan(&activeSessions, &devices, &usersTotal); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"days":    days,
		"signups": signups, "redemptions": redemptions, "mail": mail,
		"active_sessions": activeSessions, "devices": devices, "users_total": usersTotal,
		"updated_at": time.Now().UTC(),
	})
}

// ---- 限流检查器 ----

func (a *API) rateLimitTop(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT encode(bucket_mac,'hex'),window_start,hits,expires_at
		FROM rate_limit_buckets WHERE expires_at>now() ORDER BY window_start DESC,hits DESC LIMIT 50`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		KeyHex      string    `json:"key_hex"`
		WindowStart time.Time `json:"window_start"`
		Hits        int       `json:"hits"`
		ExpiresAt   time.Time `json:"expires_at"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.KeyHex, &it.WindowStart, &it.Hits, &it.ExpiresAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		it.KeyHex = it.KeyHex[:16] + "…"
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"buckets": items, "updated_at": time.Now().UTC()})
}

type rateLimitLookupRequest struct {
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

func (a *API) rateLimitBucket(kind, value string) (string, []byte, time.Time, bool, error) {
	var bucket string
	var period time.Duration
	switch kind {
	case "email_hour":
		bucket, period = "email-hour:"+value, time.Hour
	case "email_day":
		bucket, period = "email-day:"+value, 24*time.Hour
	case "ip_hour":
		bucket, period = "ip-hour:"+value, time.Hour
	case "password_email_hour":
		bucket, period = "password-email-hour:"+value, time.Hour
	case "password_ip_quarter":
		bucket, period = "password-ip-quarter:"+value, 15*time.Minute
	case "feedback_ip_hour":
		bucket, period = "feedback-ip-hour:"+value, time.Hour
	default:
		return "", nil, time.Time{}, false, nil
	}
	start := time.Now().UTC().Truncate(period)
	window := strconv.FormatInt(start.Unix(), 10)
	mac := secure.MAC(a.cfg.AuthHMACKey, "rate-limit-v1", bucket, window)
	return bucket, mac, start, true, nil
}

func normalizeRateLimitValue(kind, value string) (string, bool) {
	value = strings.TrimSpace(value)
	switch kind {
	case "email_hour", "email_day", "password_email_hour":
		parsed, err := identity.ParseEmail(value)
		return parsed.Canonical, err == nil
	case "ip_hour", "password_ip_quarter", "feedback_ip_hour":
		ip := net.ParseIP(value)
		if ip != nil {
			return ip.String(), true
		}
	}
	return "", false
}

func (a *API) rateLimitLookup(w http.ResponseWriter, r *http.Request) {
	var input rateLimitLookupRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	value := strings.TrimSpace(input.Value)
	if len(value) < 3 || len(value) > 254 || strings.ContainsAny(value, "\x00\r\n") {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	value, valid := normalizeRateLimitValue(input.Kind, value)
	if !valid {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	_, mac, start, ok, err := a.rateLimitBucket(input.Kind, value)
	if err != nil || !ok {
		writeError(w, apiError{Status: 400, Code: "invalid_kind"})
		return
	}
	var hits int
	var expires time.Time
	err = a.db.QueryRow(r.Context(), `SELECT hits,expires_at FROM rate_limit_buckets WHERE bucket_mac=$1 AND expires_at>now()`, mac).Scan(&hits, &expires)
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"found": false, "hits": 0, "window_start": start, "updated_at": time.Now().UTC()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"found": true, "hits": hits, "window_start": start, "expires_at": expires, "updated_at": time.Now().UTC()})
}

func (a *API) rateLimitClear(w http.ResponseWriter, r *http.Request) {
	var input rateLimitLookupRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	value := strings.TrimSpace(input.Value)
	if len(value) < 3 || len(value) > 254 || strings.ContainsAny(value, "\x00\r\n") {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	value, valid := normalizeRateLimitValue(input.Kind, value)
	if !valid {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	_, mac, _, ok, err := a.rateLimitBucket(input.Kind, value)
	if err != nil || !ok {
		writeError(w, apiError{Status: 400, Code: "invalid_kind"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `DELETE FROM rate_limit_buckets WHERE bucket_mac=$1`, mac)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	targetMAC := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-ratelimit-target", input.Kind, value)
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.ratelimit.clear", "rate_limit_bucket", hex.EncodeToString(targetMAC), input.Kind, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cleared": tag.RowsAffected() > 0})
}

// ---- 备份历史 ----

func (a *API) backupRuns(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT id,state,code,summary,object_name,duration_ms,created_at
		FROM backup_runs ORDER BY created_at DESC LIMIT 100`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID         int64     `json:"id"`
		State      string    `json:"state"`
		Code       string    `json:"code"`
		Summary    string    `json:"summary"`
		ObjectName string    `json:"object_name"`
		DurationMs int64     `json:"duration_ms"`
		CreatedAt  time.Time `json:"created_at"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.State, &it.Code, &it.Summary, &it.ObjectName, &it.DurationMs, &it.CreatedAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"runs": items, "updated_at": time.Now().UTC()})
}

// ---- 邮件任务重试 ----

func (a *API) retryMailJob(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE outbox_jobs SET attempts=0,lease_until=NULL,available_at=now(),
		last_error_code=NULL
		WHERE id=$1 AND kind='email_otp' AND completed_at IS NULL AND expires_at>now()
          AND last_error_code='email_delivery_failed' AND octet_length(payload_ciphertext)>0
          AND (lease_until IS NULL OR lease_until<=now())`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err := tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM outbox_jobs WHERE id=$1 AND kind='email_otp')`, id).Scan(&exists); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if exists {
			writeError(w, apiError{Status: 409, Code: "mail_job_not_retryable"})
		} else {
			writeError(w, apiError{Status: 404, Code: "mail_job_not_found"})
		}
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.mail.retry", "outbox_job", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "requeued"})
}
