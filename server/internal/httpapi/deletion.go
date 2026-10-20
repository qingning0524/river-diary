package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type deleteRequest struct {
	ReauthToken string `json:"reauth_token"`
}
type deleteResponse struct {
	JobID           string    `json:"job_id"`
	StatusToken     string    `json:"status_token"`
	Status          string    `json:"status"`
	StatusExpiresAt time.Time `json:"status_expires_at"`
}

func (a *API) deleteAccount(w http.ResponseWriter, r *http.Request) {
	var req deleteRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if req.ReauthToken == "" || len(req.ReauthToken) > 256 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	_, p, authErr := a.authenticate(r)
	if authErr != nil {
		parts := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		var jobID, sessionID string
		var previousMAC []byte
		var statusExpires time.Time
		e := a.db.QueryRow(ctx, `SELECT id::text,session_id::text,request_mac,status_expires_at FROM deletion_jobs
			WHERE request_access_mac=$1 AND request_id=$2`, bearerHash(parts[1]), key).Scan(&jobID, &sessionID, &previousMAC, &statusExpires)
		if errors.Is(e, pgx.ErrNoRows) {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		if e != nil {
			a.databaseFailure(w, r, "delete_retry_lookup")
			return
		}
		bodyMAC := secure.MAC(a.authMAC, "delete-request-v1", req.ReauthToken, sessionID)
		if !secure.EqualMAC(previousMAC, bodyMAC) {
			writeError(w, r, apiError{Status: 409, Code: "idempotency_conflict"})
			return
		}
		response := a.deleteResponse(jobID, key, statusExpires)
		encoded, _ := json.Marshal(response)
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write(encoded)
		return
	}
	parts := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
	if len(parts) != 2 {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "delete-request-v1", req.ReauthToken, p.SessionID)
	scope := "account-delete:" + p.SessionID
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "delete_begin")
		return
	}
	defer tx.Rollback(ctx)
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "delete_cache_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write(cached)
		return
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='account_delete' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&exists); err != nil {
		a.databaseFailure(w, r, "delete_reauth_lookup")
		return
	}
	if !exists {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	if a.journal == nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	var userStatus string
	if err := tx.QueryRow(ctx, `SELECT status FROM users WHERE id=$1 FOR UPDATE`, p.UserID).Scan(&userStatus); err != nil {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	if userStatus != "active" {
		writeError(w, r, apiError{Status: 409, Code: "deletion_already_started"})
		return
	}
	jobID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "delete_random")
		return
	}
	statusExpires := time.Now().UTC().Add(48 * time.Hour).Truncate(time.Microsecond)
	if _, err := tx.Exec(ctx, `INSERT INTO deletion_jobs(id,old_user_id,session_id,request_id,request_mac,request_access_mac,status_token_mac,status_expires_at)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8)`, jobID, p.UserID, p.SessionID, key, bodyMAC, bearerHash(parts[1]), bearerHash(a.deleteStatusToken(jobID, key)), statusExpires); err != nil {
		a.databaseFailure(w, r, "delete_job")
		return
	}
	response := a.deleteResponse(jobID, key, statusExpires)
	if _, err := tx.Exec(ctx, `UPDATE users SET status='deleting' WHERE id=$1`, p.UserID); err != nil {
		a.databaseFailure(w, r, "delete_user_state")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1`, p.UserID); err != nil {
		a.databaseFailure(w, r, "delete_revoke_sessions")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE reauth_proofs SET used_at=now() WHERE token_mac=$1`, bearerHash(req.ReauthToken)); err != nil {
		a.databaseFailure(w, r, "delete_consume_reauth")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO security_event_outbox(event_id,old_user_id,event_type) VALUES($1,$2,'account_deleted')`, jobID, p.UserID); err != nil {
		a.databaseFailure(w, r, "delete_security_event")
		return
	}
	appleRows, err := tx.Query(ctx, `SELECT id::text,provider_client_id,refresh_token_ciphertext FROM identities WHERE user_id=$1 AND provider='apple'`, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "delete_apple_lookup")
		return
	}
	appleCount, appleInvalid := 0, false
	for appleRows.Next() {
		var identityID, clientID string
		var encrypted []byte
		if err := appleRows.Scan(&identityID, &clientID, &encrypted); err != nil {
			appleRows.Close()
			a.databaseFailure(w, r, "delete_apple_scan")
			return
		}
		if len(encrypted) == 0 {
			appleInvalid = true
			continue
		}
		refresh, err := a.appleBox.Open(encrypted, []byte("flowriver-apple-refresh-v1|"+identityID))
		if err != nil {
			appleInvalid = true
			continue
		}
		outboxID, err := uuid()
		if err != nil {
			appleRows.Close()
			a.databaseFailure(w, r, "delete_apple_random")
			return
		}
		payload, _ := json.Marshal(map[string]string{"client_id": clientID, "refresh_token": string(refresh), "deletion_job_id": jobID})
		sealed, err := a.outboxBox.Seal(payload, []byte("flowriver-outbox-v1|"+outboxID+"|apple_revoke"))
		if err != nil {
			appleRows.Close()
			a.databaseFailure(w, r, "delete_apple_encrypt")
			return
		}
		if _, err := tx.Exec(ctx, `INSERT INTO outbox_jobs(id,kind,deletion_job_id,payload_ciphertext,created_at,available_at,expires_at) VALUES($1,'apple_revoke',$2,$3,now(),now(),now()+interval '24 hours')`, outboxID, jobID, sealed); err != nil {
			appleRows.Close()
			a.databaseFailure(w, r, "delete_apple_outbox")
			return
		}
		appleCount++
	}
	rowsErr := appleRows.Err()
	appleRows.Close()
	if rowsErr != nil {
		a.databaseFailure(w, r, "delete_apple_rows")
		return
	}
	appleStatus := "not_required"
	if appleCount > 0 {
		appleStatus = "pending"
	}
	if appleInvalid {
		appleStatus = "manual_action_required"
	}
	manualCode := any(nil)
	if appleInvalid {
		manualCode = "apple_revoke_manual_action"
	}
	if _, err := tx.Exec(ctx, `UPDATE deletion_jobs SET apple_revocation_status=$2,last_error_code=$3 WHERE id=$1`, jobID, appleStatus, manualCode); err != nil {
		a.databaseFailure(w, r, "delete_apple_status")
		return
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		a.databaseFailure(w, r, "delete_response")
		return
	}
	if err := a.saveResponse(ctx, tx, scope, key, bodyMAC, encoded); err != nil {
		writeError(w, r, err)
		return
	}
	if err := audit(ctx, tx, p.UserID, "account_delete_requested", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "delete_audit")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "delete_commit")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusAccepted)
	_, _ = w.Write(encoded)
}

func (a *API) deleteStatusToken(jobID, requestKey string) string {
	token := secure.MAC(a.authMAC, "delete-status-v1", jobID, requestKey)
	return base64.RawURLEncoding.EncodeToString(token)
}

func (a *API) deleteResponse(jobID, requestKey string, expires time.Time) deleteResponse {
	return deleteResponse{JobID: jobID, StatusToken: a.deleteStatusToken(jobID, requestKey), Status: "pending", StatusExpiresAt: expires}
}

func (a *API) deletionStatus(w http.ResponseWriter, r *http.Request) {
	token := r.Header.Get("X-Deletion-Status-Token")
	if token == "" || len(token) > 256 {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	var status, appleStatus string
	var completed *time.Time
	var expires time.Time
	err := a.db.QueryRow(r.Context(), `SELECT CASE WHEN completed_at IS NULL THEN 'pending' ELSE 'completed' END,
		apple_revocation_status,completed_at,status_expires_at FROM deletion_jobs WHERE status_token_mac=$1`, bearerHash(token)).Scan(&status, &appleStatus, &completed, &expires)
	if err != nil || !expires.After(time.Now()) {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": status, "server_data_deleted": completed != nil, "apple_revocation": appleStatus})
}
