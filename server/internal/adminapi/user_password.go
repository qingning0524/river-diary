package adminapi

import (
	"encoding/json"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"net/http"
	"strings"
)

func (a *API) resetUserPassword(w http.ResponseWriter, r *http.Request) {
	userID := strings.ToLower(r.PathValue("id"))
	if !isUUID(userID) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	var input struct {
		Reason      string `json:"reason_code"`
		NewPassword string `json:"new_password"`
	}
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	switch input.Reason {
	case "user_request", "suspicious_activity", "other":
	default:
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	if !secure.ValidNewUserPassword(input.NewPassword) {
		writeError(w, apiError{Status: 400, Code: "password_policy_failed"})
		return
	}
	rawKey := r.Header.Get("Idempotency-Key")
	if !idempotencyKeyPattern.MatchString(rawKey) {
		writeError(w, apiError{Status: 400, Code: "idempotency_key_required"})
		return
	}
	s := currentSession(r)
	requestMAC := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-user-password-reset", userID, input.Reason, secure.NormalizeUserPassword(input.NewPassword))
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
	var userStatus string
	var emailEligible bool
	err = tx.QueryRow(r.Context(), `SELECT u.status,EXISTS(SELECT 1 FROM identities i WHERE i.user_id=u.id AND i.provider='email' AND i.status='active') FROM users u WHERE u.id=$1 FOR UPDATE`, userID).Scan(&userStatus, &emailEligible)
	if err == pgx.ErrNoRows {
		writeError(w, apiError{Status: 404, Code: "user_not_found"})
		return
	}
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if userStatus != "active" || !emailEligible {
		writeError(w, apiError{Status: 409, Code: "verified_email_required"})
		return
	}
	var matchesEmail bool
	if err = tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM identities WHERE user_id=$1 AND provider='email' AND lower(email_canonical)=lower($2))`, userID, secure.NormalizeUserPassword(input.NewPassword)).Scan(&matchesEmail); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if matchesEmail {
		writeError(w, apiError{Status: 400, Code: "password_policy_failed"})
		return
	}
	if err := a.acquirePasswordSlot(r.Context()); err != nil {
		writeError(w, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	defer a.releasePasswordSlot()
	hash, err := secure.HashUserPassword(input.NewPassword)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if _, err = tx.Exec(r.Context(), `INSERT INTO user_password_credentials(user_id,password_hash) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET password_hash=EXCLUDED.password_hash,version=user_password_credentials.version+1,updated_at=now()`, userID, hash); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	tag, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1 AND status='active'`, userID)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	response := map[string]any{"status": "password_reset", "user_id": userID, "revoked_sessions": tag.RowsAffected()}
	encoded, err := json.Marshal(response)
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_action_requests SET response_body=$3::jsonb WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC, string(encoded)); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.user.password.reset", "user", userID, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, response)
}
