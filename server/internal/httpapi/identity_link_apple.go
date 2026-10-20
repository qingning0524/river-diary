package httpapi

import (
	"context"
	"errors"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type linkAppleStartRequest struct {
	ReauthToken string `json:"reauth_token"`
}
type linkAppleCompleteRequest struct {
	AttemptID         string `json:"attempt_id"`
	IdentityToken     string `json:"identity_token"`
	AuthorizationCode string `json:"authorization_code"`
	ReauthToken       string `json:"reauth_token"`
}

func (a *API) linkAppleStart(w http.ResponseWriter, r *http.Request) {
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
	var req linkAppleStartRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		a.databaseFailure(w, r, "link_apple_start_begin")
		return
	}
	defer tx.Rollback(r.Context())
	count, err := a.hitRateLimit(r.Context(), tx, "apple-link-session:"+p.SessionID, 5, time.Hour)
	if err != nil {
		a.databaseFailure(w, r, "link_apple_start_rate")
		return
	}
	if count > 5 {
		if err := tx.Commit(r.Context()); err != nil {
			a.databaseFailure(w, r, "link_apple_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	var proof bool
	if err := tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='identity_change' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&proof); err != nil {
		a.databaseFailure(w, r, "link_apple_reauth")
		return
	}
	if !proof {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	attemptID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "link_apple_random")
		return
	}
	nonce, err := secure.RandomToken(32)
	if err != nil {
		a.databaseFailure(w, r, "link_apple_random")
		return
	}
	mac := secure.MAC(a.authMAC, "apple-link-nonce-v1", attemptID, p.UserID, p.SessionID, hashAppleNonce(nonce))
	if _, err := tx.Exec(r.Context(), `UPDATE auth_challenges SET consumed_at=now(),state='consumed'
		WHERE purpose='apple_link' AND user_id=$1 AND session_id=$2 AND consumed_at IS NULL`, p.UserID, p.SessionID); err != nil {
		a.databaseFailure(w, r, "link_apple_supersede")
		return
	}
	if _, err := tx.Exec(r.Context(), `INSERT INTO auth_challenges(id,purpose,user_id,session_id,secret_mac,reauth_proof_mac,created_at,expires_at)
		VALUES($1,'apple_link',$2,$3,$4,$5,now(),now()+interval '5 minutes')`, attemptID, p.UserID, p.SessionID, mac, bearerHash(req.ReauthToken)); err != nil {
		a.databaseFailure(w, r, "link_apple_challenge")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		a.databaseFailure(w, r, "link_apple_start_commit")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"attempt_id": attemptID, "nonce": nonce, "client_ids": a.cfg.AppleClientIDs, "expires_in": 300})
}

func (a *API) linkAppleComplete(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req linkAppleCompleteRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.AttemptID) || len(req.IdentityToken) < 40 || len(req.IdentityToken) > 16<<10 || len(req.AuthorizationCode) < 10 || len(req.AuthorizationCode) > 4<<10 || req.ReauthToken == "" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "apple-link-complete-v1", req.AttemptID, hexDigest(req.IdentityToken), hexDigest(req.AuthorizationCode), req.ReauthToken, p.UserID, p.SessionID)
	scope := "apple-link:" + req.AttemptID
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "link_apple_complete_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "link_apple_cache_commit")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var nonceMAC, proofMAC []byte
	var state string
	var leaseUntil *time.Time
	var attempts int
	var consumed *time.Time
	var challengeUser, challengeSession string
	err = tx.QueryRow(ctx, `SELECT secret_mac,reauth_proof_mac,state,lease_until,attempts,consumed_at,user_id::text,session_id::text
		FROM auth_challenges WHERE id=$1 AND purpose='apple_link' AND expires_at>now() FOR UPDATE`, req.AttemptID).Scan(&nonceMAC, &proofMAC, &state, &leaseUntil, &attempts, &consumed, &challengeUser, &challengeSession)
	if errors.Is(err, pgx.ErrNoRows) || consumed != nil || attempts >= 5 || challengeUser != p.UserID || challengeSession != p.SessionID || !secure.EqualMAC(proofMAC, bearerHash(req.ReauthToken)) {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "link_apple_attempt")
		return
	}
	if state == "exchanging" && leaseUntil != nil && leaseUntil.After(time.Now()) {
		writeError(w, r, apiError{Status: 409, Code: "auth_attempt_in_progress"})
		return
	}
	var proofActive bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='identity_change' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&proofActive); err != nil {
		a.databaseFailure(w, r, "link_apple_proof")
		return
	}
	if !proofActive {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	leaseID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "link_apple_lease_random")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='exchanging',exchange_lease_id=$2,lease_until=now()+interval '15 seconds' WHERE id=$1`, req.AttemptID, leaseID); err != nil {
		a.databaseFailure(w, r, "link_apple_lease")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "link_apple_lease_commit")
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
	if !secure.EqualMAC(nonceMAC, secure.MAC(a.authMAC, "apple-link-nonce-v1", req.AttemptID, p.UserID, p.SessionID, claims.Nonce)) {
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
	if err := a.finishAppleLink(w, r, p, req, key, scope, bodyMAC, leaseID, claims, tokens); err != nil {
		writeError(w, r, err)
	}
}

func (a *API) finishAppleLink(w http.ResponseWriter, r *http.Request, p Principal, req linkAppleCompleteRequest, key, scope string, bodyMAC []byte, leaseID string, claims *appleClaims, tokens appleTokenResponse) error {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	defer tx.Rollback(ctx)
	var lease string
	var state string
	var consumed *time.Time
	if err := tx.QueryRow(ctx, `SELECT exchange_lease_id::text,state,consumed_at FROM auth_challenges WHERE id=$1 FOR UPDATE`, req.AttemptID).Scan(&lease, &state, &consumed); err != nil {
		return apiError{Status: 401, Code: "invalid_or_expired_challenge"}
	}
	if state != "exchanging" || lease != leaseID || consumed != nil {
		return apiError{Status: 409, Code: "auth_attempt_expired"}
	}
	if _, err := tx.Exec(ctx, `SELECT id FROM users WHERE id=$1 AND status='active' FOR UPDATE`, p.UserID); err != nil {
		return apiError{Status: 404, Code: "resource_not_found"}
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,1721))`, claims.Subject); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	var identityID, owner, status string
	err = tx.QueryRow(ctx, `SELECT id::text,user_id::text,status FROM identities WHERE provider='apple' AND subject=$1 FOR UPDATE`, claims.Subject).Scan(&identityID, &owner, &status)
	if err == nil && owner != p.UserID {
		if _, e := tx.Exec(ctx, `UPDATE auth_challenges SET state='consumed',consumed_at=now(),lease_until=NULL,exchange_lease_id=NULL WHERE id=$1`, req.AttemptID); e != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		if e := tx.Commit(ctx); e != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		return apiError{Status: 409, Code: "identity_conflict"}
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if errors.Is(err, pgx.ErrNoRows) {
		identityID, err = uuid()
		if err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		sealed, sealErr := a.appleBox.Seal([]byte(tokens.RefreshToken), []byte("flowriver-apple-refresh-v1|"+identityID))
		if sealErr != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		var email any
		if claims.Email != "" && bool(claims.EmailVerified) {
			email = claims.Email
		}
		if _, err := tx.Exec(ctx, `INSERT INTO identities(id,user_id,provider,provider_client_id,subject,email_display,refresh_token_ciphertext,verified_at)
			VALUES($1,$2,'apple',$3,$4,$5,$6,now())`, identityID, p.UserID, claims.Audience[0], claims.Subject, email, sealed); err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
	} else {
		sealed, sealErr := a.appleBox.Seal([]byte(tokens.RefreshToken), []byte("flowriver-apple-refresh-v1|"+identityID))
		if sealErr != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		if _, err := tx.Exec(ctx, `UPDATE identities SET status='active',provider_client_id=$2,refresh_token_ciphertext=$3,updated_at=now() WHERE id=$1`, identityID, claims.Audience[0], sealed); err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE reauth_proofs SET used_at=now() WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND used_at IS NULL`, bearerHash(req.ReauthToken), p.UserID, p.SessionID); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='consumed',consumed_at=now(),lease_until=NULL,exchange_lease_id=NULL WHERE id=$1`, req.AttemptID); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	encoded := []byte(`{"linked":true}`)
	if err := a.saveResponse(ctx, tx, scope, key, bodyMAC, encoded); err != nil {
		return err
	}
	if err := audit(ctx, tx, p.UserID, "apple_identity_linked", requestIDFromContext(r.Context())); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if err := tx.Commit(ctx); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}
