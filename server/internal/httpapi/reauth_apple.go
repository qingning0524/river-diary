package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type appleReauthCompleteRequest struct {
	AttemptID         string `json:"attempt_id"`
	IdentityToken     string `json:"identity_token"`
	AuthorizationCode string `json:"authorization_code"`
	Purpose           string `json:"purpose"`
}

func (a *API) reauthAppleStart(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req struct{}
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_start_begin")
		return
	}
	defer tx.Rollback(r.Context())
	count, err := a.hitRateLimit(r.Context(), tx, "reauth-apple-session:"+p.SessionID, 5, time.Hour)
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_start_rate")
		return
	}
	if count > 5 {
		if err := tx.Commit(r.Context()); err != nil {
			a.databaseFailure(w, r, "reauth_apple_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	attemptID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_random")
		return
	}
	nonce, err := secure.RandomToken(32)
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_random")
		return
	}
	mac := secure.MAC(a.authMAC, "apple-reauth-nonce-v1", attemptID, p.UserID, p.SessionID, hashAppleNonce(nonce))
	if _, err := tx.Exec(r.Context(), `INSERT INTO auth_challenges(id,purpose,user_id,session_id,secret_mac,created_at,expires_at)
		VALUES($1,'apple_reauth',$2,$3,$4,now(),now()+interval '5 minutes')`, attemptID, p.UserID, p.SessionID, mac); err != nil {
		a.databaseFailure(w, r, "reauth_apple_attempt")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		a.databaseFailure(w, r, "reauth_apple_start_commit")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"attempt_id": attemptID, "nonce": nonce, "client_ids": a.cfg.AppleClientIDs, "expires_in": 300})
}

func (a *API) reauthAppleComplete(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req appleReauthCompleteRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.AttemptID) || len(req.IdentityToken) < 40 || len(req.IdentityToken) > 16<<10 || len(req.AuthorizationCode) < 10 || len(req.AuthorizationCode) > 4<<10 ||
		(req.Purpose != "account_delete" && req.Purpose != "identity_change") {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "apple-reauth-complete-v1", req.AttemptID, hexDigest(req.IdentityToken), hexDigest(req.AuthorizationCode), req.Purpose, p.UserID, p.SessionID)
	scope := "reauth-apple:" + req.AttemptID
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_complete_begin")
		return
	}
	defer tx.Rollback(ctx)
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		var response struct {
			Token string `json:"reauth_token"`
		}
		if json.Unmarshal(cached, &response) != nil || response.Token == "" {
			writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
			return
		}
		var active bool
		if e := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose=$4 AND used_at IS NULL AND expires_at>now())`, bearerHash(response.Token), p.UserID, p.SessionID, req.Purpose).Scan(&active); e != nil || !active {
			writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "reauth_apple_cache_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}
	var storedMAC []byte
	var state string
	var leaseUntil *time.Time
	var attempts int
	var consumedAt *time.Time
	var challengeUser, challengeSession string
	err = tx.QueryRow(ctx, `SELECT secret_mac,state,lease_until,attempts,consumed_at,user_id::text,session_id::text FROM auth_challenges
		WHERE id=$1 AND purpose='apple_reauth' AND expires_at>now() FOR UPDATE`, req.AttemptID).Scan(&storedMAC, &state, &leaseUntil, &attempts, &consumedAt, &challengeUser, &challengeSession)
	if errors.Is(err, pgx.ErrNoRows) || consumedAt != nil || attempts >= 5 || challengeUser != p.UserID || challengeSession != p.SessionID {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_attempt")
		return
	}
	if state == "exchanging" && leaseUntil != nil && leaseUntil.After(time.Now()) {
		writeError(w, r, apiError{Status: 409, Code: "auth_attempt_in_progress"})
		return
	}
	leaseID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "reauth_apple_random")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='exchanging',exchange_lease_id=$2,lease_until=now()+interval '15 seconds' WHERE id=$1`, req.AttemptID, leaseID); err != nil {
		a.databaseFailure(w, r, "reauth_apple_lease")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "reauth_apple_lease_commit")
		return
	}
	claims, err := a.apple.verifyIdentity(ctx, req.IdentityToken)
	if err != nil {
		transient := transientAppleFailure(err)
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, !transient)
		if transient {
			writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		} else {
			writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		}
		return
	}
	if !secure.EqualMAC(storedMAC, secure.MAC(a.authMAC, "apple-reauth-nonce-v1", req.AttemptID, p.UserID, p.SessionID, claims.Nonce)) {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, true)
		writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		return
	}
	tokens, exchangeClaims, err := requestAppleCode(ctx, a.apple, claims.Audience[0], req.AuthorizationCode)
	if err != nil {
		transient := transientAppleFailure(err)
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, !transient)
		if transient {
			writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		} else {
			writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		}
		return
	}
	if claims.Subject != exchangeClaims.Subject || claims.Nonce != exchangeClaims.Nonce || claims.Audience[0] != exchangeClaims.Audience[0] {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, true)
		writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		return
	}
	_ = tokens
	if err := a.finishAppleReauth(w, r, p, req, key, scope, bodyMAC, leaseID, claims.Subject); err != nil {
		writeError(w, r, err)
	}
}

func (a *API) finishAppleReauth(w http.ResponseWriter, r *http.Request, p Principal, req appleReauthCompleteRequest, key, scope string, bodyMAC []byte, leaseID, subject string) error {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	defer tx.Rollback(ctx)
	var state string
	var storedLease string
	var used *time.Time
	if err := tx.QueryRow(ctx, `SELECT state,exchange_lease_id::text,consumed_at FROM auth_challenges WHERE id=$1 FOR UPDATE`, req.AttemptID).Scan(&state, &storedLease, &used); err != nil {
		return apiError{Status: 401, Code: "invalid_or_expired_challenge"}
	}
	if state != "exchanging" || storedLease != leaseID || used != nil {
		return apiError{Status: 409, Code: "auth_attempt_expired"}
	}
	var identityActive bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM identities WHERE user_id=$1 AND provider='apple' AND subject=$2 AND status='active')`, p.UserID, subject).Scan(&identityActive); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if !identityActive {
		return apiError{Status: 401, Code: "reauthentication_required"}
	}
	token, err := secure.RandomToken(32)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO reauth_proofs(token_mac,user_id,session_id,purpose,created_at,expires_at) VALUES($1,$2,$3,$4,now(),now()+interval '5 minutes')`, bearerHash(token), p.UserID, p.SessionID, req.Purpose); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='consumed',consumed_at=now(),lease_until=NULL,exchange_lease_id=NULL WHERE id=$1`, req.AttemptID); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	response := map[string]any{"reauth_token": token, "expires_in": 300}
	encoded, err := json.Marshal(response)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if err := a.saveResponse(ctx, tx, scope, key, bodyMAC, encoded); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(encoded)
	return nil
}
