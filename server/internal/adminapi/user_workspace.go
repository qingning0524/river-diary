package adminapi

import (
	"net/http"
	"strings"
	"time"
)

func (a *API) userSummary(w http.ResponseWriter, r *http.Request) {
	var total, active, disabled, password, recent, premium int
	err := a.db.QueryRow(r.Context(), `SELECT count(*)::int,
 count(*) FILTER(WHERE u.status='active' AND u.disabled_at IS NULL)::int,
 count(*) FILTER(WHERE u.disabled_at IS NOT NULL)::int,
 count(*) FILTER(WHERE EXISTS(SELECT 1 FROM user_password_credentials p WHERE p.user_id=u.id))::int,
 count(*) FILTER(WHERE EXISTS(SELECT 1 FROM devices d WHERE d.user_id=u.id AND d.last_seen_at>=now()-interval '7 days'))::int,
 count(*) FILTER(WHERE EXISTS(SELECT 1 FROM user_entitlements e WHERE e.user_id=u.id AND e.product_code='riverdiary_premium' AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now())))::int FROM users u`).Scan(&total, &active, &disabled, &password, &recent, &premium)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, map[string]any{"total": total, "active": active, "disabled": disabled, "password": password, "recent": recent, "premium": premium, "updated_at": time.Now().UTC()})
}
func (a *API) userActivity(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	var exists bool
	if err := a.db.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1)`, id).Scan(&exists); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !exists {
		writeError(w, apiError{Status: 404, Code: "user_not_found"})
		return
	}
	rows, err := a.db.Query(r.Context(), `SELECT kind,created_at,'account' AS source,'' AS result,'' AS reason FROM audit_events WHERE user_id=$1::uuid
 UNION ALL SELECT action,created_at,'administrator',result,reason_code FROM admin_audit_events WHERE (target_type='user' AND target_id=$1::text) OR (target_type='device' AND target_id IN(SELECT id::text FROM devices WHERE user_id=$1::uuid)) OR (target_type='session' AND target_id IN(SELECT id::text FROM sessions WHERE user_id=$1::uuid)) ORDER BY created_at DESC LIMIT 100`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type event struct {
		Kind   string    `json:"kind"`
		At     time.Time `json:"created_at"`
		Source string    `json:"source"`
		Result string    `json:"result"`
		Reason string    `json:"reason_code"`
	}
	events := make([]event, 0)
	for rows.Next() {
		var e event
		if err = rows.Scan(&e.Kind, &e.At, &e.Source, &e.Result, &e.Reason); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		events = append(events, e)
	}
	if rows.Err() != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, map[string]any{"events": events, "limit": 100})
}
