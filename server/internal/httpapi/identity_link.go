package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type linkEmailStartRequest struct {
	Email       string `json:"email"`
	ReauthToken string `json:"reauth_token"`
}
type linkEmailCompleteRequest struct {
	ChallengeID string `json:"challenge_id"`
	Code        string `json:"code"`
	ReauthToken string `json:"reauth_token"`
}

func (a *API) linkEmailStart(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	var req linkEmailStartRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	parsed, err := identity.ParseEmail(req.Email)
	if err != nil || req.ReauthToken == "" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "link_email_start_begin")
		return
	}
	defer tx.Rollback(ctx)
	var proof bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='identity_change' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&proof); err != nil {
		a.databaseFailure(w, r, "link_email_reauth")
		return
	}
	if !proof {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	for _, limit := range []struct {
		key    string
		max    int
		period time.Duration
	}{{"email-hour:" + parsed.Canonical, 5, time.Hour}, {"email-day:" + parsed.Canonical, 20, 24 * time.Hour}, {"ip-hour:" + a.clientIP(r), 20, time.Hour}, {"global-day", 200, 24 * time.Hour}} {
		count, e := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if e != nil {
			a.databaseFailure(w, r, "link_email_rate")
			return
		}
		if count > limit.max {
			if e := tx.Commit(ctx); e != nil {
				a.databaseFailure(w, r, "link_email_rate_commit")
				return
			}
			writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
			return
		}
	}
	challengeID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "link_email_random")
		return
	}
	code, err := otpCode()
	if err != nil {
		a.databaseFailure(w, r, "link_email_random")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(10 * time.Minute)
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE purpose='email_link' AND user_id=$1 AND session_id=$2 AND consumed_at IS NULL`, p.UserID, p.SessionID); err != nil {
		a.databaseFailure(w, r, "link_email_supersede")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO auth_challenges(id,purpose,user_id,session_id,email_display,email_canonical,secret_mac,created_at,expires_at,request_ip_mac)
		VALUES($1,'email_link',$2,$3,$4,$5,$6,$7,$8,$9)`, challengeID, p.UserID, p.SessionID, parsed.Display, parsed.Canonical, secure.MAC(a.authMAC, "email-otp-v1", challengeID, code), now, expires, secure.MAC(a.authMAC, "request-ip-v1", a.clientIP(r))); err != nil {
		a.databaseFailure(w, r, "link_email_challenge")
		return
	}
	jobID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "link_email_random")
		return
	}
	payload, _ := json.Marshal(map[string]string{"to": parsed.Display, "code": code, "challenge_id": challengeID})
	sealed, err := a.outboxBox.Seal(payload, []byte("flowriver-outbox-v1|"+jobID+"|email_otp"))
	if err != nil {
		a.databaseFailure(w, r, "link_email_encrypt")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO outbox_jobs(id,kind,payload_ciphertext,created_at,available_at,expires_at) VALUES($1,'email_otp',$2,$3,$3,$4)`, jobID, sealed, now, expires); err != nil {
		a.databaseFailure(w, r, "link_email_outbox")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "link_email_commit")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"challenge_id": challengeID, "message": "A verification code will arrive shortly if email delivery is available."})
}

func (a *API) linkEmailComplete(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	var req linkEmailCompleteRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.ChallengeID) || len(req.Code) != 8 || !allDigits(req.Code) || req.ReauthToken == "" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	requestMAC := secure.MAC(a.authMAC, "email-link-complete-v1", req.ChallengeID, req.Code, req.ReauthToken, p.UserID, p.SessionID)
	scope := "email-link:" + req.ChallengeID
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "link_email_complete_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, found, e := a.cachedResponse(ctx, tx, scope, key, requestMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "link_email_cache_commit")
			return
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var emailDisplay, emailCanonical string
	var expected []byte
	var attempts int
	var challengeUser, challengeSession string
	var consumed *time.Time
	err = tx.QueryRow(ctx, `SELECT email_display,email_canonical,secret_mac,attempts,user_id::text,session_id::text,consumed_at FROM auth_challenges
		WHERE id=$1 AND purpose='email_link' AND expires_at>now() FOR UPDATE`, req.ChallengeID).Scan(&emailDisplay, &emailCanonical, &expected, &attempts, &challengeUser, &challengeSession, &consumed)
	if err != nil || consumed != nil || attempts >= 5 || challengeUser != p.UserID || challengeSession != p.SessionID {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if !secure.EqualMAC(expected, secure.MAC(a.authMAC, "email-otp-v1", req.ChallengeID, req.Code)) {
		if _, e := tx.Exec(ctx, `UPDATE auth_challenges SET attempts=attempts+1,consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END,state=CASE WHEN attempts+1>=5 THEN 'consumed' ELSE state END WHERE id=$1`, req.ChallengeID); e != nil {
			a.databaseFailure(w, r, "link_email_attempt")
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "link_email_attempt_commit")
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	var proof bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose='identity_change' AND used_at IS NULL AND expires_at>now())`, bearerHash(req.ReauthToken), p.UserID, p.SessionID).Scan(&proof); err != nil {
		a.databaseFailure(w, r, "link_email_proof")
		return
	}
	if !proof {
		writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
		return
	}
	if _, err := tx.Exec(ctx, `SELECT id FROM users WHERE id=$1 AND status='active' FOR UPDATE`, p.UserID); err != nil {
		writeError(w, r, apiError{Status: 404, Code: "resource_not_found"})
		return
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,481922))`, emailCanonical); err != nil {
		a.databaseFailure(w, r, "link_email_lock")
		return
	}
	var identityID, owner, status string
	err = tx.QueryRow(ctx, `SELECT id::text,user_id::text,status FROM identities WHERE provider='email' AND email_canonical=$1 FOR UPDATE`, emailCanonical).Scan(&identityID, &owner, &status)
	if err == nil && owner != p.UserID {
		if _, e := tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE id=$1`, req.ChallengeID); e != nil {
			a.databaseFailure(w, r, "link_email_conflict_consume")
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "link_email_conflict_commit")
			return
		}
		writeError(w, r, apiError{Status: 409, Code: "identity_conflict"})
		return
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		a.databaseFailure(w, r, "link_email_identity_lookup")
		return
	}
	if errors.Is(err, pgx.ErrNoRows) {
		if _, err := tx.Exec(ctx, `INSERT INTO identities(user_id,provider,subject,email_display,email_canonical,verified_at) VALUES($1,'email',$2,$3,$2,now())`, p.UserID, emailCanonical, emailDisplay); err != nil {
			a.databaseFailure(w, r, "link_email_identity_insert")
			return
		}
	} else if status != "active" {
		if _, err := tx.Exec(ctx, `UPDATE identities SET status='active',email_display=$2,verified_at=now(),updated_at=now() WHERE id=$1 AND user_id=$3`, identityID, emailDisplay, p.UserID); err != nil {
			a.databaseFailure(w, r, "link_email_identity_restore")
			return
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE reauth_proofs SET used_at=now() WHERE token_mac=$1`, bearerHash(req.ReauthToken)); err != nil {
		a.databaseFailure(w, r, "link_email_proof_consume")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE id=$1`, req.ChallengeID); err != nil {
		a.databaseFailure(w, r, "link_email_challenge_consume")
		return
	}
	encoded := []byte(`{}`)
	if err := a.saveResponse(ctx, tx, scope, key, requestMAC, encoded); err != nil {
		writeError(w, r, err)
		return
	}
	if err := audit(ctx, tx, p.UserID, "email_identity_linked", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "link_email_audit")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "link_email_commit")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
