package httpapi

import (
	"context"
	"encoding/hex"
	"errors"
	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type passwordLoginRequest struct {
	Email            string `json:"email"`
	Password         string `json:"password"`
	ClientInstanceID string `json:"client_instance_id"`
	Platform         string `json:"platform"`
	DeviceName       string `json:"device_name"`
}
type passwordResetRequest struct {
	ChallengeID      string `json:"challenge_id"`
	Code             string `json:"code"`
	NewPassword      string `json:"new_password"`
	ClientInstanceID string `json:"client_instance_id"`
	Platform         string `json:"platform"`
	DeviceName       string `json:"device_name"`
}

func validPasswordDevice(instance, platform, name string) bool {
	return validUUID(instance) && (platform == "ios" || platform == "macos" || platform == "other") && len(name) <= 80
}
func (a *API) passwordResetStart(w http.ResponseWriter, r *http.Request) {
	a.emailChallengeStart(w, r, "password_reset")
}
func (a *API) passwordSlot() bool {
	select {
	case a.passwordSem <- struct{}{}:
		return true
	default:
		return false
	}
}
func writeTokenBytes(w http.ResponseWriter, body []byte) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
func (a *API) passwordLogin(w http.ResponseWriter, r *http.Request) {
	var req passwordLoginRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	email, err := identity.ParseEmail(req.Email)
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if err != nil || !validPasswordDevice(req.ClientInstanceID, req.Platform, req.DeviceName) || !utf8.ValidString(req.Password) || len(req.Password) > 512 || utf8.RuneCountInString(req.Password) > 128 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	scope := "password-login:" + hex.EncodeToString(secure.MAC(a.authMAC, "password-login-scope-v1", email.Canonical, req.ClientInstanceID))
	bodyMAC := secure.MAC(a.authMAC, "password-login-v1", email.Canonical, secure.NormalizeUserPassword(req.Password), req.ClientInstanceID, req.Platform, req.DeviceName)
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "password_login_begin")
		return
	}
	defer tx.Rollback(ctx)
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if !a.cachedSessionActive(ctx, tx, cached) {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "password_login_retry")
			return
		}
		writeTokenBytes(w, cached)
		return
	}
	allowed := true
	for _, limit := range []struct {
		key    string
		max    int
		period time.Duration
	}{{"password-email-hour:" + email.Canonical, 20, time.Hour}, {"password-ip-quarter:" + a.clientIP(r), 60, 15 * time.Minute}, {"password-global-minute", 120, time.Minute}} {
		n, e := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if e != nil {
			a.databaseFailure(w, r, "password_login_limit")
			return
		}
		if n > limit.max {
			allowed = false
		}
	}
	if e := tx.Commit(ctx); e != nil {
		a.databaseFailure(w, r, "password_login_rate_commit")
		return
	}
	if !allowed {
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	if !a.passwordSlot() {
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	defer func() { <-a.passwordSem }()
	var userID, identityID, hash string
	err = a.db.QueryRow(ctx, `SELECT u.id::text,i.id::text,p.password_hash FROM identities i JOIN users u ON u.id=i.user_id JOIN user_password_credentials p ON p.user_id=u.id WHERE i.provider='email' AND i.email_canonical=$1 AND i.status='active' AND u.status='active' AND u.disabled_at IS NULL`, email.Canonical).Scan(&userID, &identityID, &hash)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		a.databaseFailure(w, r, "password_login_lookup")
		return
	}
	exists := err == nil
	if !exists {
		// A disabled account must not blend into the generic failure path: the
		// operator expects the client to surface an explicit state.
		var disabled bool
		if lookErr := a.db.QueryRow(ctx, `SELECT u.disabled_at IS NOT NULL FROM identities i JOIN users u ON u.id=i.user_id WHERE i.provider='email' AND i.email_canonical=$1 AND i.status='active' AND u.status='active'`, email.Canonical).Scan(&disabled); lookErr == nil && disabled {
			writeError(w, r, apiError{Status: 403, Code: "account_disabled"})
			return
		}
		hash = secure.DummyUserPasswordHash()
	}
	valid := secure.VerifyUserPassword(hash, req.Password)
	if !exists || !valid {
		writeError(w, r, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	tx, err = a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "password_login_finish_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, e := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,915305))`, scope); e != nil {
		a.databaseFailure(w, r, "password_login_lock")
		return
	}
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if !a.cachedSessionActive(ctx, tx, cached) {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "password_login_cache_commit")
			return
		}
		writeTokenBytes(w, cached)
		return
	}
	var currentHash string
	err = tx.QueryRow(ctx, `SELECT p.password_hash FROM users u JOIN identities i ON i.user_id=u.id JOIN user_password_credentials p ON p.user_id=u.id WHERE u.id=$1 AND i.id=$2 AND i.email_canonical=$3 AND u.status='active' AND i.status='active' FOR UPDATE OF u,i,p`, userID, identityID, email.Canonical).Scan(&currentHash)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && currentHash != hash) {
		writeError(w, r, apiError{Status: 401, Code: "invalid_credentials"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "password_login_recheck")
		return
	}
	a.finishPasswordSession(w, r, ctx, tx, userID, identityID, req.ClientInstanceID, req.Platform, req.DeviceName, scope, key, bodyMAC, "password_login")
}
func (a *API) finishPasswordSession(w http.ResponseWriter, r *http.Request, ctx context.Context, tx pgx.Tx, userID, identityID, instance, platform, name, scope, key string, bodyMAC []byte, kind string) {
	deviceID, err := upsertDevice(ctx, tx, userID, instance, platform, name)
	if err != nil {
		a.databaseFailure(w, r, "password_device")
		return
	}
	response, err := a.createSession(ctx, tx, userID, identityID, deviceID, instance, false)
	if err != nil {
		a.databaseFailure(w, r, "password_session")
		return
	}
	body, err := tokenResponseBytes(response)
	if err != nil {
		a.databaseFailure(w, r, "password_response")
		return
	}
	if err = a.saveResponse(ctx, tx, scope, key, bodyMAC, body); err != nil {
		a.databaseFailure(w, r, "password_idempotency")
		return
	}
	if err = audit(ctx, tx, userID, kind, requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "password_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "password_commit")
		return
	}
	writeTokenBytes(w, body)
}
func (a *API) passwordResetComplete(w http.ResponseWriter, r *http.Request) {
	var req passwordResetRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if !validUUID(req.ChallengeID) || len(req.Code) != 8 || !allDigits(req.Code) || !validPasswordDevice(req.ClientInstanceID, req.Platform, req.DeviceName) {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if !secure.ValidNewUserPassword(req.NewPassword) {
		writeError(w, r, apiError{Status: 400, Code: "password_policy_failed"})
		return
	}
	scope := "password-reset:" + req.ChallengeID
	bodyMAC := secure.MAC(a.authMAC, "password-reset-v1", req.ChallengeID, req.Code, secure.NormalizeUserPassword(req.NewPassword), req.ClientInstanceID, req.Platform, req.DeviceName)
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "password_reset_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, e := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,915306))`, scope); e != nil {
		a.databaseFailure(w, r, "password_reset_lock")
		return
	}
	if cached, found, e := a.cachedResponse(ctx, tx, scope, key, bodyMAC); e != nil {
		writeError(w, r, e)
		return
	} else if found {
		if !a.cachedSessionActive(ctx, tx, cached) {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "password_reset_retry")
			return
		}
		writeTokenBytes(w, cached)
		return
	}
	var email, display string
	var boundUser *string
	var expectedVersion *int64
	var expected []byte
	var attempts int
	var consumed *time.Time
	err = tx.QueryRow(ctx, `SELECT email_canonical,email_display,user_id::text,password_version,secret_mac,attempts,consumed_at FROM auth_challenges WHERE id=$1 AND purpose='password_reset' AND expires_at>now() FOR UPDATE`, req.ChallengeID).Scan(&email, &display, &boundUser, &expectedVersion, &expected, &attempts, &consumed)
	if errors.Is(err, pgx.ErrNoRows) || consumed != nil || attempts >= 5 {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "password_reset_challenge")
		return
	}
	if !secure.EqualMAC(expected, secure.MAC(a.authMAC, "email-otp-v1", req.ChallengeID, req.Code)) {
		if _, e := tx.Exec(ctx, `UPDATE auth_challenges SET attempts=attempts+1,consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END,state=CASE WHEN attempts+1>=5 THEN 'consumed' ELSE state END WHERE id=$1`, req.ChallengeID); e != nil {
			a.databaseFailure(w, r, "password_reset_attempt")
			return
		}
		if e := tx.Commit(ctx); e != nil {
			a.databaseFailure(w, r, "password_reset_attempt_commit")
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if boundUser == nil || expectedVersion == nil {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	var userID, identityID string
	err = tx.QueryRow(ctx, `SELECT u.id::text,i.id::text FROM identities i JOIN users u ON u.id=i.user_id WHERE i.provider='email' AND i.email_canonical=$1 AND i.status='active' AND u.status='active' AND u.disabled_at IS NULL AND u.id=$2 FOR UPDATE OF u,i`, email, *boundUser).Scan(&userID, &identityID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "password_reset_identity")
		return
	}
	var currentVersion int64
	if e := tx.QueryRow(ctx, `SELECT COALESCE((SELECT version FROM user_password_credentials WHERE user_id=$1),0)`, userID).Scan(&currentVersion); e != nil {
		a.databaseFailure(w, r, "password_reset_version")
		return
	}
	if currentVersion != *expectedVersion {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if strings.EqualFold(secure.NormalizeUserPassword(req.NewPassword), email) {
		writeError(w, r, apiError{Status: 400, Code: "password_policy_failed"})
		return
	}
	if !a.passwordSlot() {
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	defer func() { <-a.passwordSem }()
	hash, err := secure.HashUserPassword(req.NewPassword)
	if err != nil {
		a.databaseFailure(w, r, "password_reset_hash")
		return
	}
	if _, err = tx.Exec(ctx, `INSERT INTO user_password_credentials(user_id,password_hash) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET password_hash=EXCLUDED.password_hash,version=user_password_credentials.version+1,updated_at=now()`, userID, hash); err != nil {
		a.databaseFailure(w, r, "password_reset_save")
		return
	}
	if _, err = tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE id=$1`, req.ChallengeID); err != nil {
		a.databaseFailure(w, r, "password_reset_consume")
		return
	}
	if _, err = tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1 AND status='active'`, userID); err != nil {
		a.databaseFailure(w, r, "password_reset_revoke")
		return
	}
	a.finishPasswordSession(w, r, ctx, tx, userID, identityID, req.ClientInstanceID, req.Platform, req.DeviceName, scope, key, bodyMAC, "password_reset")
}
func (a *API) passwordStatus(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	var enabled bool
	if err = a.db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM user_password_credentials WHERE user_id=$1)`, p.UserID).Scan(&enabled); err != nil {
		a.databaseFailure(w, r, "password_status")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"password_enabled": enabled})
}
