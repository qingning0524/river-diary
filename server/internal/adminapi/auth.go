package adminapi

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type mfaRequest struct {
	Challenge string `json:"challenge"`
	Code      string `json:"code"`
}

func (a *API) checkOrigin(r *http.Request) error {
	if r.Header.Get("Origin") != a.cfg.AdminOrigin {
		return apiError{Status: 403, Code: "origin_rejected"}
	}
	return nil
}

func (a *API) consumeAuthLimit(ctx context.Context, r *http.Request, purpose, identity string, windowSeconds, maximum int) (bool, error) {
	if purpose == "login" {
		ipAllowed, err := a.consumeBucket(ctx, purpose+"-source", a.requestIP(r), windowSeconds, maximum)
		if err != nil || !ipAllowed {
			return ipAllowed, err
		}
	}
	return a.consumeBucket(ctx, purpose, identity, windowSeconds, maximum)
}

func (a *API) consumeBucket(ctx context.Context, purpose, identity string, windowSeconds, maximum int) (bool, error) {
	bucket := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-auth-limit", purpose, identity)
	var count int
	err := a.db.QueryRow(ctx, `
		INSERT INTO admin_auth_buckets(bucket_mac,window_start,hits,expires_at)
		VALUES($1,now(),1,now()+make_interval(secs=>$2))
		ON CONFLICT(bucket_mac) DO UPDATE SET
		  window_start=CASE WHEN admin_auth_buckets.window_start<=now()-make_interval(secs=>$2) THEN now() ELSE admin_auth_buckets.window_start END,
		  hits=CASE WHEN admin_auth_buckets.window_start<=now()-make_interval(secs=>$2) THEN 1 ELSE LEAST(admin_auth_buckets.hits+1,100000) END,
		  expires_at=now()+make_interval(secs=>$2)
		RETURNING hits`, bucket, windowSeconds).Scan(&count)
	if err != nil {
		return false, err
	}
	return count <= maximum, nil
}

func (a *API) acquirePasswordSlot(ctx context.Context) error {
	timer := time.NewTimer(8 * time.Second)
	defer timer.Stop()
	select {
	case a.passwordSem <- struct{}{}:
		return nil
	case <-timer.C:
		return apiError{Status: 429, Code: "temporarily_throttled"}
	case <-ctx.Done():
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
}

func (a *API) releasePasswordSlot() { <-a.passwordSem }

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	if err := a.checkOrigin(r); err != nil {
		writeError(w, err)
		return
	}
	var input loginRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	username, validUsername := normalizeUsername(input.Username)
	if !validUsername {
		username = "invalid"
	}
	allowed, err := a.consumeAuthLimit(r.Context(), r, "login", username, 900, 10)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !allowed {
		writeError(w, apiError{Status: 429, Code: "temporarily_throttled"})
		return
	}
	if len(input.Password) == 0 || len(input.Password) > 128 {
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	if err := a.acquirePasswordSlot(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	var adminID, encodedHash string
	var disabled bool
	lookupErr := a.db.QueryRow(r.Context(), `SELECT id::text,password_hash,disabled_at IS NOT NULL FROM admin_accounts WHERE username=$1`, username).
		Scan(&adminID, &encodedHash, &disabled)
	found := lookupErr == nil && validUsername
	if !found {
		encodedHash = a.fakeHash
	}
	passwordValid := verifyPassword(encodedHash, input.Password)
	a.releasePasswordSlot()
	if !found || !passwordValid || disabled {
		if lookupErr != nil && !errors.Is(lookupErr, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := a.audit(r.Context(), adminID, "admin.login.password", "", "", "", "denied", a.ipMAC(r)); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	challenge, err := secure.RandomToken(32)
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	_, err = a.db.Exec(r.Context(), `INSERT INTO admin_login_challenges(challenge_mac,admin_id,ip_mac,expires_at)
		VALUES($1,$2,$3,now()+interval '5 minutes')`, secure.Digest(challenge), adminID, a.ipMAC(r))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.audit(r.Context(), adminID, "admin.login.password", "", "", "", "success", a.ipMAC(r)); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"challenge": challenge, "next": "totp"})
}

func (a *API) completeMFA(w http.ResponseWriter, r *http.Request) {
	if err := a.checkOrigin(r); err != nil {
		writeError(w, err)
		return
	}
	var input mfaRequest
	if err := decodeJSON(w, r, &input); err != nil || len(input.Challenge) < 32 || len(input.Challenge) > 128 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	allowed, err := a.consumeAuthLimit(r.Context(), r, "mfa", a.requestIP(r), 600, 8)
	if err != nil {
		a.mfaUnavailable(w, r, "rate_limit_database", err)
		return
	}
	if !allowed {
		writeError(w, apiError{Status: 429, Code: "temporarily_throttled"})
		return
	}
	if err := a.acquirePasswordSlot(r.Context()); err != nil {
		if apiErr, ok := err.(apiError); ok && apiErr.Status == 503 {
			a.mfaUnavailable(w, r, "password_slot_context", err)
			return
		}
		writeError(w, err)
		return
	}
	defer a.releasePasswordSlot()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		a.mfaUnavailable(w, r, "transaction_begin", err)
		return
	}
	defer tx.Rollback(r.Context())
	var adminID, username string
	var challengeIP, sealed []byte
	var lastStep int64
	var expires time.Time
	err = tx.QueryRow(r.Context(), `
		SELECT c.admin_id::text,a.username,c.ip_mac,c.expires_at,c.attempts,a.totp_secret_ciphertext,a.totp_last_step
		FROM admin_login_challenges c JOIN admin_accounts a ON a.id=c.admin_id
		WHERE c.challenge_mac=$1 AND c.expires_at>now() AND c.attempts<8 AND a.disabled_at IS NULL
		FOR UPDATE OF c,a`, secure.Digest(input.Challenge)).
		Scan(&adminID, &username, &challengeIP, &expires, new(int), &sealed, &lastStep)
	if err != nil {
		writeError(w, apiError{Status: 401, Code: "invalid_challenge"})
		return
	}
	if !secure.EqualMAC(challengeIP, a.ipMAC(r)) {
		writeError(w, apiError{Status: 401, Code: "invalid_challenge"})
		return
	}
	secret, err := a.totpBox.Open(sealed, []byte("flowriver-admin-totp:"+adminID))
	if err != nil {
		a.mfaUnavailable(w, r, "totp_secret_unseal", err)
		return
	}
	now := time.Now().UTC()
	step, valid := acceptTOTP(secret, input.Code, now, lastStep)
	if !valid {
		if _, err := tx.Exec(r.Context(), `UPDATE admin_login_challenges SET attempts=attempts+1 WHERE challenge_mac=$1`, secure.Digest(input.Challenge)); err != nil {
			a.mfaUnavailable(w, r, "invalid_code_attempt_update", err)
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			a.mfaUnavailable(w, r, "invalid_code_attempt_commit", err)
			return
		}
		if err := a.audit(r.Context(), adminID, "admin.login.mfa", "", "", "", "denied", challengeIP); err != nil {
			a.mfaUnavailable(w, r, "invalid_code_audit", err)
			return
		}
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	rawToken, err := secure.RandomToken(32)
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	rawCSRF, err := secure.RandomToken(32)
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET totp_last_step=$2,last_login_at=$3 WHERE id=$1`, adminID, step, now); err != nil {
		a.mfaUnavailable(w, r, "totp_step_update", err)
		return
	}
	if _, err := tx.Exec(r.Context(), `INSERT INTO admin_sessions(token_mac,admin_id,csrf_mac,created_at,last_seen_at,idle_expires_at,absolute_expires_at,reauthenticated_until,ip_mac)
		VALUES($1,$2,$3,$4::timestamptz,$4::timestamptz,$4::timestamptz+interval '15 minutes',$4::timestamptz+interval '8 hours',$4::timestamptz,$5)`, secure.Digest(rawToken), adminID, secure.Digest(rawCSRF), now, challengeIP); err != nil {
		a.mfaUnavailable(w, r, "session_insert", err)
		return
	}
	if _, err := tx.Exec(r.Context(), `DELETE FROM admin_login_challenges WHERE challenge_mac=$1`, secure.Digest(input.Challenge)); err != nil {
		a.mfaUnavailable(w, r, "challenge_delete", err)
		return
	}
	if err := a.auditTx(r.Context(), tx, adminID, "admin.login.mfa", "", "", "", "success", challengeIP); err != nil {
		a.mfaUnavailable(w, r, "success_audit", err)
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		a.mfaUnavailable(w, r, "transaction_commit", err)
		return
	}
	a.setCookies(w, rawToken, rawCSRF)
	writeJSON(w, http.StatusOK, map[string]any{"authenticated": true, "username": username, "reauthentication_required": false})
}

func (a *API) mfaUnavailable(w http.ResponseWriter, r *http.Request, stage string, cause error) {
	requestID, _ := r.Context().Value(requestIDKey{}).(string)
	var pgErr *pgconn.PgError
	if errors.As(cause, &pgErr) {
		a.log.Error("administrator MFA temporarily unavailable", "stage", stage, "request_id", requestID, "sqlstate", pgErr.Code, "constraint", pgErr.ConstraintName)
	} else {
		a.log.Error("administrator MFA temporarily unavailable", "stage", stage, "request_id", requestID, "cause_type", fmt.Sprintf("%T", cause))
	}
	writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
}

func (a *API) logout(w http.ResponseWriter, r *http.Request) {
	s, err := a.readSession(r, false)
	if err != nil {
		clearCookies(w)
		writeError(w, apiError{Status: 401, Code: "admin_auth_required"})
		return
	}
	if err := a.verifyCSRFAndOrigin(r, s); err != nil {
		writeError(w, err)
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET revoked_at=now() WHERE token_mac=$1 AND revoked_at IS NULL`, s.TokenMAC); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.logout", "", "", "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	clearCookies(w)
	writeJSON(w, http.StatusOK, map[string]string{"status": "signed_out"})
}

type reauthRequest struct {
	Password string `json:"password"`
	Code     string `json:"code"`
}

type changePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

func (a *API) changePassword(w http.ResponseWriter, r *http.Request) {
	s := currentSession(r)
	var input changePasswordRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if len(input.CurrentPassword) == 0 || len(input.CurrentPassword) > 128 || len(input.NewPassword) < 12 || len(input.NewPassword) > 128 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if err := a.acquirePasswordSlot(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	hash, err := createPasswordHash(input.NewPassword)
	if err != nil {
		a.releasePasswordSlot()
		writeError(w, apiError{Status: 400, Code: "invalid_new_password"})
		return
	}
	var currentHash string
	err = a.db.QueryRow(r.Context(), `SELECT password_hash FROM admin_accounts WHERE id=$1 AND disabled_at IS NULL`, s.AdminID).Scan(&currentHash)
	valid := err == nil && verifyPassword(currentHash, input.CurrentPassword)
	a.releasePasswordSlot()
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !valid {
		if auditErr := a.audit(r.Context(), s.AdminID, "admin.password.change", "", "", "", "denied", s.IPMac); auditErr != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET password_hash=$2 WHERE id=$1`, s.AdminID, hash); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET revoked_at=now(),reauthenticated_until=NULL WHERE admin_id=$1 AND token_mac<>$2 AND revoked_at IS NULL`, s.AdminID, s.TokenMAC); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET reauthenticated_until=NULL WHERE token_mac=$1`, s.TokenMAC); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.password.change", "admin", s.AdminID, "owner_change", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "password_changed", "reauthentication_required": true})
}

func (a *API) reauthenticate(w http.ResponseWriter, r *http.Request) {
	s, err := a.readSession(r, false)
	if err != nil {
		writeError(w, apiError{Status: 401, Code: "admin_auth_required"})
		return
	}
	if err := a.verifyCSRFAndOrigin(r, s); err != nil {
		writeError(w, err)
		return
	}
	var input reauthRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	allowed, err := a.consumeAuthLimit(r.Context(), r, "reauth", s.AdminID, 600, 8)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !allowed {
		writeError(w, apiError{Status: 429, Code: "temporarily_throttled"})
		return
	}
	if err := a.acquirePasswordSlot(r.Context()); err != nil {
		writeError(w, err)
		return
	}
	var passwordHash string
	err = a.db.QueryRow(r.Context(), `SELECT password_hash FROM admin_accounts WHERE id=$1 AND disabled_at IS NULL`, s.AdminID).
		Scan(&passwordHash)
	if err != nil {
		a.releasePasswordSlot()
		writeError(w, apiError{Status: 401, Code: "admin_auth_required"})
		return
	}
	if !verifyPassword(passwordHash, input.Password) {
		a.releasePasswordSlot()
		_ = a.audit(r.Context(), s.AdminID, "admin.step_up", "", "", "", "denied", s.IPMac)
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	a.releasePasswordSlot()
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var sealed []byte
	var lastStep int64
	if err := tx.QueryRow(r.Context(), `SELECT totp_secret_ciphertext,totp_last_step FROM admin_accounts WHERE id=$1 AND disabled_at IS NULL FOR UPDATE`, s.AdminID).
		Scan(&sealed, &lastStep); err != nil {
		writeError(w, apiError{Status: 401, Code: "admin_auth_required"})
		return
	}
	secret, err := a.totpBox.Open(sealed, []byte("flowriver-admin-totp:"+s.AdminID))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	now := time.Now().UTC()
	step, valid := acceptTOTP(secret, input.Code, now, lastStep)
	if !valid {
		_ = tx.Rollback(r.Context())
		if err := a.audit(r.Context(), s.AdminID, "admin.step_up", "", "", "", "denied", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeError(w, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET totp_last_step=$2 WHERE id=$1`, s.AdminID, step); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET reauthenticated_until=$2 WHERE token_mac=$1 AND revoked_at IS NULL`, s.TokenMAC, now.Add(5*time.Minute)); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.step_up", "", "", "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"reauthenticated_until": now.Add(5 * time.Minute)})
}

func (a *API) requireRecentMFA(_ http.ResponseWriter, r *http.Request, s session) error {
	if s.ReauthenticatedUntil == nil || time.Now().After(*s.ReauthenticatedUntil) {
		return apiError{Status: 403, Code: "recent_mfa_required"}
	}
	return nil
}
