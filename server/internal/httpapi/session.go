package httpapi

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type refreshRequest struct {
	RefreshToken     string `json:"refresh_token"`
	RevokeToken      string `json:"revoke_token"`
	ClientInstanceID string `json:"client_instance_id"`
}
type logoutRequest struct {
	RevokeToken string `json:"revoke_token"`
}

type refreshState struct {
	SessionID, UserID, DeviceID, IdentityID, InstanceID string
	UserStatus, SessionStatus, Platform, DisplayName    string
	IdleExpiry, AbsoluteExpiry                          time.Time
	ConsumedAt                                          *time.Time
	PriorRequestID                                      *string
	PriorRequestMAC, ReplayCiphertext                   []byte
	RetryUntil                                          *time.Time
	RevokeTokenMAC                                      []byte
}

func (a *API) refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if req.RefreshToken == "" || len(req.RefreshToken) > 256 || req.RevokeToken == "" || len(req.RevokeToken) > 256 || !validUUID(req.ClientInstanceID) {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	requestMAC := secure.MAC(a.authMAC, "refresh-request-v1", req.RefreshToken, req.RevokeToken, req.ClientInstanceID)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "refresh_begin")
		return
	}
	defer tx.Rollback(ctx)
	var state refreshState
	err = tx.QueryRow(ctx, `SELECT f.id::text,f.user_id::text,f.device_id::text,COALESCE(f.identity_id::text,''),
		d.instance_id::text,u.status,f.status,d.platform,d.display_name,f.idle_expires_at,f.absolute_expires_at,f.revoke_token_mac,
		rt.consumed_at,rt.request_id,rt.request_mac,rt.retry_until,rt.response_ciphertext
		FROM refresh_tokens rt JOIN sessions f ON f.id=rt.session_id
		JOIN users u ON u.id=f.user_id JOIN devices d ON d.id=f.device_id AND d.user_id=f.user_id
		WHERE rt.token_mac=$1 AND u.disabled_at IS NULL FOR UPDATE OF rt,f,u`, bearerHash(req.RefreshToken)).
		Scan(&state.SessionID, &state.UserID, &state.DeviceID, &state.IdentityID, &state.InstanceID, &state.UserStatus,
			&state.SessionStatus, &state.Platform, &state.DisplayName, &state.IdleExpiry, &state.AbsoluteExpiry,
			&state.RevokeTokenMAC, &state.ConsumedAt, &state.PriorRequestID, &state.PriorRequestMAC, &state.RetryUntil, &state.ReplayCiphertext)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "refresh_lookup")
		return
	}
	if state.SessionStatus != "active" || state.UserStatus != "active" || state.InstanceID != req.ClientInstanceID ||
		!state.IdleExpiry.After(time.Now()) || !state.AbsoluteExpiry.After(time.Now()) {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	if !secure.EqualMAC(state.RevokeTokenMAC, bearerHash(req.RevokeToken)) {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	if state.ConsumedAt != nil {
		if state.PriorRequestID != nil && *state.PriorRequestID == key {
			if state.RetryUntil != nil && state.RetryUntil.After(time.Now()) && len(state.ReplayCiphertext) > 0 && secure.EqualMAC(state.PriorRequestMAC, requestMAC) {
				plain, openErr := a.resultBox.Open(state.ReplayCiphertext, refreshReplayAAD(req.RefreshToken, key))
				if openErr != nil {
					a.databaseFailure(w, r, "refresh_replay_decrypt")
					return
				}
				if !a.cachedSessionActive(ctx, tx, plain) {
					writeError(w, r, apiError{Status: 401, Code: "auth_required"})
					return
				}
				if err := tx.Commit(ctx); err != nil {
					a.databaseFailure(w, r, "refresh_replay_commit")
					return
				}
				w.Header().Set("Content-Type", "application/json; charset=utf-8")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(plain)
				return
			}
			writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
			return
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=now() WHERE id=$1`, state.SessionID); err != nil {
			a.databaseFailure(w, r, "refresh_replay_revoke")
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "refresh_replay_revoke_commit")
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "session_reuse_detected"})
		return
	}
	var used bool
	err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM refresh_tokens WHERE session_id=$1 AND request_id=$2)`, state.SessionID, key).Scan(&used)
	if err != nil {
		a.databaseFailure(w, r, "refresh_idempotency_lookup")
		return
	}
	if used {
		writeError(w, r, apiError{Status: 409, Code: "idempotency_conflict"})
		return
	}
	response, err := a.rotateSession(ctx, tx, state, req.ClientInstanceID, req.RevokeToken, requestMAC, key, req.RefreshToken)
	if err != nil {
		a.databaseFailure(w, r, "refresh_rotate")
		return
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		a.databaseFailure(w, r, "refresh_response")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "refresh_commit")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(encoded)
}

func refreshReplayAAD(refreshToken, request string) []byte {
	return []byte("flowriver-refresh-replay-v1|" + hex.EncodeToString(bearerHash(refreshToken)) + "|" + request)
}

func (a *API) rotateSession(ctx context.Context, tx pgx.Tx, s refreshState, instance, revokeToken string, requestMAC []byte, requestKey, oldRefresh string) (TokenResponse, error) {
	access, err := secure.RandomToken(32)
	if err != nil {
		return TokenResponse{}, err
	}
	refresh, err := secure.RandomToken(32)
	if err != nil {
		return TokenResponse{}, err
	}
	now := time.Now().UTC()
	accessExpires := now.Add(accessLifetime)
	idleExpires := now.Add(refreshIdle)
	if idleExpires.After(s.AbsoluteExpiry) {
		idleExpires = s.AbsoluteExpiry
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET consumed_at=$2,request_id=$3,request_mac=$4,retry_until=$5 WHERE token_mac=$1`, bearerHash(oldRefresh), now, requestKey, requestMAC, now.Add(refreshRetry)); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE access_tokens SET revoked_at=$2 WHERE session_id=$1 AND revoked_at IS NULL`, s.SessionID, now); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO access_tokens(token_mac,session_id,created_at,expires_at) VALUES($1,$2,$3,$4)`, bearerHash(access), s.SessionID, now, accessExpires); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens(token_mac,session_id,created_at) VALUES($1,$2,$3)`, bearerHash(refresh), s.SessionID, now); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE sessions SET last_seen_at=$2,idle_expires_at=$3 WHERE id=$1`, s.SessionID, now, idleExpires); err != nil {
		return TokenResponse{}, err
	}
	response := TokenResponse{TokenType: "Bearer", AccessToken: access, RefreshToken: refresh, RevokeToken: revokeToken, ExpiresIn: int64(accessLifetime.Seconds()),
		User: PublicUser{ID: s.UserID, Status: s.UserStatus}, Device: PublicDevice{ID: s.DeviceID, ClientInstanceID: instance, Platform: s.Platform, DisplayName: s.DisplayName}}
	encoded, err := json.Marshal(response)
	if err != nil {
		return TokenResponse{}, err
	}
	ciphertext, err := a.resultBox.Seal(encoded, refreshReplayAAD(oldRefresh, requestKey))
	if err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE refresh_tokens SET response_ciphertext=$2 WHERE token_mac=$1`, bearerHash(oldRefresh), ciphertext); err != nil {
		return TokenResponse{}, err
	}
	return response, nil
}

func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	if _, p, authErr := a.authenticate(r); authErr == nil {
		if _, err := a.db.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2`, p.SessionID, p.UserID); err != nil {
			a.databaseFailure(w, r, "logout_access")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.ContentLength == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var req logoutRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	if req.RevokeToken != "" && len(req.RevokeToken) <= 256 {
		if _, err := a.db.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE revoke_token_mac=$1`, bearerHash(req.RevokeToken)); err != nil {
			a.databaseFailure(w, r, "logout_revocation_token")
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) me(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	var status, termsVersion, privacyVersion string
	if err := a.db.QueryRow(r.Context(), `SELECT status,
		COALESCE((SELECT terms_version FROM consents WHERE user_id=users.id ORDER BY accepted_at DESC,id DESC LIMIT 1),''),
		COALESCE((SELECT privacy_version FROM consents WHERE user_id=users.id ORDER BY accepted_at DESC,id DESC LIMIT 1),'')
		FROM users WHERE id=$1`, p.UserID).Scan(&status, &termsVersion, &privacyVersion); err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	rows, err := a.db.Query(r.Context(), `SELECT provider,COALESCE(email_display,''),status FROM identities WHERE user_id=$1 ORDER BY created_at`, p.UserID)
	if err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	identities := make([]map[string]string, 0)
	for rows.Next() {
		var provider, email, state string
		if err := rows.Scan(&provider, &email, &state); err != nil {
			writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		identities = append(identities, map[string]string{"provider": provider, "email": email, "status": state})
	}
	if rows.Err() != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	changes := make([]map[string]string, 0)
	changeRows, err := a.db.Query(r.Context(), `SELECT event_id::text,event_type FROM security_event_outbox WHERE old_user_id=$1 AND delivered_at IS NULL ORDER BY occurred_at`, p.UserID)
	if err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for changeRows.Next() {
		var id, kind string
		if err := changeRows.Scan(&id, &kind); err != nil {
			changeRows.Close()
			writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		changes = append(changes, map[string]string{"event_id": id, "kind": kind, "status": "pending"})
	}
	if err := changeRows.Err(); err != nil {
		changeRows.Close()
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	changeRows.Close()
	writeJSON(w, http.StatusOK, map[string]any{"user": PublicUser{ID: p.UserID, Status: status, TermsVersion: termsVersion, PrivacyVersion: privacyVersion}, "identities": identities, "pending_security_changes": changes})
}

func (a *API) devices(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	rows, err := a.db.Query(r.Context(), `SELECT id::text,instance_id::text,platform,display_name,created_at,last_seen_at,(revoked_at IS NOT NULL)
		FROM devices WHERE user_id=$1 ORDER BY last_seen_at DESC LIMIT 100`, p.UserID)
	if err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, instance, platform, name string
		var created, last time.Time
		var revoked bool
		if err := rows.Scan(&id, &instance, &platform, &name, &created, &last, &revoked); err != nil {
			writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, map[string]any{"id": id, "client_instance_id": instance, "platform": platform, "display_name": name, "created_at": created, "last_seen_at": last, "revoked": revoked})
	}
	if rows.Err() != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"devices": items})
}

func (a *API) revokeDevice(w http.ResponseWriter, r *http.Request) {
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
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	command, err := tx.Exec(r.Context(), `UPDATE devices SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2`, id, p.UserID)
	if err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if command.RowsAffected() == 0 {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE device_id=$1 AND user_id=$2`, id, p.UserID); err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
