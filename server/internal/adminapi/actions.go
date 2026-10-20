package adminapi

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

var idempotencyKeyPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{8,128}$`)

type revokeRequest struct {
	Reason string `json:"reason_code"`
}

func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request) {
	deviceID := strings.ToLower(r.PathValue("id"))
	if !isUUID(deviceID) {
		writeError(w, apiError{Status: 400, Code: "invalid_device_id"})
		return
	}
	var input revokeRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	switch input.Reason {
	case "lost_device", "user_request", "suspicious_activity", "other":
	default:
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	rawKey := r.Header.Get("Idempotency-Key")
	if !idempotencyKeyPattern.MatchString(rawKey) {
		writeError(w, apiError{Status: 400, Code: "idempotency_key_required"})
		return
	}
	s := currentSession(r)
	requestMAC := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-device-revoke", deviceID, input.Reason)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	keyMAC := secure.Digest(rawKey)
	inserted, err := tx.Exec(r.Context(), `INSERT INTO admin_action_requests(admin_id,key_mac,request_mac,expires_at)
		VALUES($1,$2,$3,now()+interval '24 hours') ON CONFLICT(admin_id,key_mac) DO NOTHING`, s.AdminID, keyMAC, requestMAC)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if inserted.RowsAffected() == 0 {
		var previousMAC []byte
		var previous json.RawMessage
		if err := tx.QueryRow(r.Context(), `SELECT request_mac,response_body FROM admin_action_requests WHERE admin_id=$1 AND key_mac=$2 AND expires_at>now()`, s.AdminID, keyMAC).Scan(&previousMAC, &previous); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if !secure.EqualMAC(previousMAC, requestMAC) {
			writeError(w, apiError{Status: 409, Code: "idempotency_key_reused"})
			return
		}
		if len(previous) == 0 {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Rollback(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(previous)
		return
	}
	var userID, userStatus string
	var alreadyRevoked bool
	err = tx.QueryRow(r.Context(), `SELECT d.user_id::text,u.status,d.revoked_at IS NOT NULL
		FROM devices d JOIN users u ON u.id=d.user_id WHERE d.id=$1 FOR UPDATE OF d,u`, deviceID).
		Scan(&userID, &userStatus, &alreadyRevoked)
	if err != nil {
		if err == pgx.ErrNoRows {
			writeError(w, apiError{Status: 404, Code: "device_not_found"})
		} else {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		}
		return
	}
	if userStatus != "active" {
		writeError(w, apiError{Status: 409, Code: "user_not_active"})
		return
	}
	var revokedSessions int64
	if !alreadyRevoked {
		if _, err := tx.Exec(r.Context(), `UPDATE devices SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1`, deviceID); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		tag, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE device_id=$1 AND status='active'`, deviceID)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		revokedSessions = tag.RowsAffected()
		if _, err := tx.Exec(r.Context(), `UPDATE access_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE session_id IN(SELECT id FROM sessions WHERE device_id=$1) AND revoked_at IS NULL`, deviceID); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	response := map[string]any{"status": "revoked", "device_id": deviceID, "revoked_sessions": revokedSessions}
	encoded, err := json.Marshal(response)
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_action_requests SET response_body=$3::jsonb WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC, string(encoded)); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.device.revoke", "device", deviceID, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, response)
}

type restoreDrillRequest struct {
	Result string `json:"result"`
}

func (a *API) recordRestoreDrill(w http.ResponseWriter, r *http.Request) {
	var input restoreDrillRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if input.Result != "success" && input.Result != "failure" {
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
	if _, err := tx.Exec(r.Context(), `INSERT INTO operations_status(kind,result,summary,admin_id) VALUES('restore_drill',$1,'manual_record',$2)`, input.Result, s.AdminID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.restore_drill.record", "operation", "restore_drill", input.Result, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"kind": "restore_drill", "recorded_at": time.Now().UTC(), "result": input.Result})
}
