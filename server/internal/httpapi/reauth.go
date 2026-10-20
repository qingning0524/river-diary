package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type reauthEmailVerifyRequest struct {
	ChallengeID string `json:"challenge_id"`
	Code        string `json:"code"`
	Purpose     string `json:"purpose"`
}

func (a *API) reauthEmailStart(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "reauth_start_begin")
		return
	}
	defer tx.Rollback(ctx)
	var emailDisplay, emailCanonical string
	err = tx.QueryRow(ctx, `SELECT email_display,email_canonical FROM identities
		WHERE user_id=$1 AND provider='email' AND status='active'`, p.UserID).Scan(&emailDisplay, &emailCanonical)
	if err == pgx.ErrNoRows {
		writeError(w, r, apiError{Status: 409, Code: "reauthentication_unavailable"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "reauth_start_identity")
		return
	}
	for _, limit := range []struct {
		key    string
		max    int
		period time.Duration
	}{{"email-hour:" + emailCanonical, 5, time.Hour}, {"email-day:" + emailCanonical, 20, 24 * time.Hour}, {"ip-hour:" + a.clientIP(r), 20, time.Hour}, {"global-day", 200, 24 * time.Hour}} {
		count, e := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if e != nil {
			a.databaseFailure(w, r, "reauth_start_rate")
			return
		}
		if count > limit.max {
			if e := tx.Commit(ctx); e != nil {
				a.databaseFailure(w, r, "reauth_start_rate_commit")
				return
			}
			writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
			return
		}
	}
	challengeID, e := uuid()
	if e != nil {
		a.databaseFailure(w, r, "reauth_start_random")
		return
	}
	code, e := otpCode()
	if e != nil {
		a.databaseFailure(w, r, "reauth_start_random")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(5 * time.Minute)
	mac := secure.MAC(a.authMAC, "email-otp-v1", challengeID, code)
	if _, e = tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed'
		WHERE purpose='email_reauth' AND user_id=$1 AND session_id=$2 AND consumed_at IS NULL`, p.UserID, p.SessionID); e != nil {
		a.databaseFailure(w, r, "reauth_start_supersede")
		return
	}
	if _, e = tx.Exec(ctx, `INSERT INTO auth_challenges(id,purpose,user_id,session_id,email_display,email_canonical,secret_mac,created_at,expires_at,request_ip_mac)
		VALUES($1,'email_reauth',$2,$3,$4,$5,$6,$7,$8,$9)`, challengeID, p.UserID, p.SessionID, emailDisplay, emailCanonical, mac, now, expires, secure.MAC(a.authMAC, "request-ip-v1", a.clientIP(r))); e != nil {
		a.databaseFailure(w, r, "reauth_start_challenge")
		return
	}
	jobID, e := uuid()
	if e != nil {
		a.databaseFailure(w, r, "reauth_start_random")
		return
	}
	payload, e := json.Marshal(map[string]string{"to": emailDisplay, "code": code, "challenge_id": challengeID})
	if e != nil {
		a.databaseFailure(w, r, "reauth_start_payload")
		return
	}
	sealed, e := a.outboxBox.Seal(payload, []byte("flowriver-outbox-v1|"+jobID+"|email_otp"))
	if e != nil {
		a.databaseFailure(w, r, "reauth_start_encrypt")
		return
	}
	if _, e = tx.Exec(ctx, `INSERT INTO outbox_jobs(id,kind,payload_ciphertext,created_at,available_at,expires_at)
		VALUES($1,'email_otp',$2,$3,$3,$4)`, jobID, sealed, now, expires); e != nil {
		a.databaseFailure(w, r, "reauth_start_outbox")
		return
	}
	if e = tx.Commit(ctx); e != nil {
		a.databaseFailure(w, r, "reauth_start_commit")
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]string{"challenge_id": challengeID, "message": "A verification code will arrive shortly if email delivery is available."})
}

func (a *API) reauthEmailVerify(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	r = r.WithContext(ctx)
	var req reauthEmailVerifyRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	requestKey, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.ChallengeID) || len(req.Code) != 8 || !allDigits(req.Code) || (req.Purpose != "account_delete" && req.Purpose != "identity_change") {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "reauth-email-verify-v1", req.ChallengeID, req.Code, req.Purpose, p.UserID, p.SessionID)
	scope := "reauth-email:" + req.ChallengeID
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "reauth_verify_begin")
		return
	}
	defer tx.Rollback(ctx)
	if cached, found, e := a.cachedResponse(ctx, tx, scope, requestKey, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		var response struct {
			ReauthToken string `json:"reauth_token"`
			ExpiresIn   int    `json:"expires_in"`
		}
		if json.Unmarshal(cached, &response) != nil || response.ReauthToken == "" {
			writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
			return
		}
		var active bool
		if e := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM reauth_proofs WHERE token_mac=$1 AND user_id=$2 AND session_id=$3 AND purpose=$4 AND used_at IS NULL AND expires_at>now())`, bearerHash(response.ReauthToken), p.UserID, p.SessionID, req.Purpose).Scan(&active); e != nil || !active {
			writeError(w, r, apiError{Status: 401, Code: "reauthentication_required"})
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "reauth_cache_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}
	var storedMAC []byte
	var attempts int
	var userID, sessionID string
	var consumedAt *time.Time
	err = tx.QueryRow(ctx, `SELECT secret_mac,attempts,user_id::text,session_id::text,consumed_at FROM auth_challenges
		WHERE id=$1 AND purpose='email_reauth' AND expires_at>now() FOR UPDATE`, req.ChallengeID).Scan(&storedMAC, &attempts, &userID, &sessionID, &consumedAt)
	if err != nil || consumedAt != nil || attempts >= 5 || userID != p.UserID || sessionID != p.SessionID {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if !secure.EqualMAC(storedMAC, secure.MAC(a.authMAC, "email-otp-v1", req.ChallengeID, req.Code)) {
		if _, e := tx.Exec(ctx, `UPDATE auth_challenges SET attempts=attempts+1,consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END,state=CASE WHEN attempts+1>=5 THEN 'consumed' ELSE state END WHERE id=$1`, req.ChallengeID); e != nil {
			a.databaseFailure(w, r, "reauth_attempt")
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "reauth_attempt_commit")
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	token, e := secure.RandomToken(32)
	if e != nil {
		a.databaseFailure(w, r, "reauth_random")
		return
	}
	if _, e = tx.Exec(ctx, `INSERT INTO reauth_proofs(token_mac,user_id,session_id,purpose,created_at,expires_at) VALUES($1,$2,$3,$4,now(),now()+interval '5 minutes')`, bearerHash(token), p.UserID, p.SessionID, req.Purpose); e != nil {
		a.databaseFailure(w, r, "reauth_proof")
		return
	}
	if _, e = tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE id=$1`, req.ChallengeID); e != nil {
		a.databaseFailure(w, r, "reauth_consume")
		return
	}
	response := map[string]any{"reauth_token": token, "expires_in": 300}
	encoded, e := json.Marshal(response)
	if e != nil {
		a.databaseFailure(w, r, "reauth_response")
		return
	}
	if e = a.saveResponse(ctx, tx, scope, requestKey, bodyMAC, encoded); e != nil {
		writeError(w, r, e)
		return
	}
	if e = tx.Commit(ctx); e != nil {
		a.databaseFailure(w, r, "reauth_verify_commit")
		return
	}
	writeJSON(w, http.StatusOK, response)
}
