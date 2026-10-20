package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type revokeIdentityRequest struct {
	ReauthToken string `json:"reauth_token"`
}

func (a *API) revokeIdentity(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	id := r.PathValue("id")
	if !validUUID(id) {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	requestKey, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	var req revokeIdentityRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	if req.ReauthToken == "" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if a.journal == nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "identity-revoke-v1", id, req.ReauthToken, p.UserID, p.SessionID)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "identity_revoke_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT id FROM users WHERE id=$1 AND status='active' FOR UPDATE`, p.UserID); err != nil {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	var existingEvent string
	var existingMAC []byte
	err = tx.QueryRow(ctx, `SELECT event_id::text,request_mac FROM security_event_outbox WHERE session_id=$1 AND request_id=$2`, p.SessionID, requestKey).Scan(&existingEvent, &existingMAC)
	if err == nil {
		if !secure.EqualMAC(existingMAC, bodyMAC) {
			writeError(w, r, apiError{Status: 409, Code: "idempotency_conflict"})
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "identity_revoke_retry_commit")
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]string{"event_id": existingEvent, "status": "pending"})
		return
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		a.databaseFailure(w, r, "identity_revoke_retry_lookup")
		return
	}
	var proof, belongs bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='identity_change' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&proof); err != nil {
		a.databaseFailure(w, r, "identity_revoke_proof")
		return
	}
	if !proof {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM identities WHERE id=$1 AND user_id=$2 AND status='active')`, id, p.UserID).Scan(&belongs); err != nil {
		a.databaseFailure(w, r, "identity_revoke_owner")
		return
	}
	if !belongs {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	var pending int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM security_event_outbox WHERE old_user_id=$1 AND event_type='identity_revoked' AND delivered_at IS NULL`, p.UserID).Scan(&pending); err != nil {
		a.databaseFailure(w, r, "identity_revoke_pending")
		return
	}
	if pending > 0 {
		writeError(w, r, apiError{Status: 409, Code: "identity_change_pending"})
		return
	}
	var active int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM identities WHERE user_id=$1 AND status='active'`, p.UserID).Scan(&active); err != nil {
		a.databaseFailure(w, r, "identity_revoke_count")
		return
	}
	if active <= 1 {
		writeError(w, r, apiError{Status: 409, Code: "last_identity_required"})
		return
	}
	eventID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "identity_revoke_random")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO security_event_outbox(event_id,old_user_id,identity_id,session_id,request_id,request_mac,event_type)
		VALUES($1,$2,$3,$4,$5,$6,'identity_revoked')`, eventID, p.UserID, id, p.SessionID, requestKey, bodyMAC); err != nil {
		a.databaseFailure(w, r, "identity_revoke_queue")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE reauth_proofs SET used_at=now() WHERE token_mac=$1`, bearerHash(req.ReauthToken)); err != nil {
		a.databaseFailure(w, r, "identity_revoke_consume_proof")
		return
	}
	if err := audit(ctx, tx, p.UserID, "identity_revoke_requested", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "identity_revoke_audit")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "identity_revoke_commit")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"event_id": eventID, "status": "pending"})
}

func (a *API) securityChangeStatus(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	id := r.PathValue("id")
	if !validUUID(id) {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	var eventType string
	var delivered *time.Time
	var errorCode *string
	err = a.db.QueryRow(r.Context(), `SELECT event_type,delivered_at,last_error_code FROM security_event_outbox WHERE event_id=$1 AND old_user_id=$2`, id, p.UserID).Scan(&eventType, &delivered, &errorCode)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "security_change_status")
		return
	}
	status := "pending"
	if delivered != nil {
		status = "completed"
	}
	result := map[string]string{"event_id": id, "kind": eventType, "status": status}
	if errorCode != nil && *errorCode != "" {
		result["error_code"] = *errorCode
	}
	writeJSON(w, http.StatusOK, result)
}
