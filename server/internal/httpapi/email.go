package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type emailStartRequest struct {
	Email string `json:"email"`
}
type emailVerifyRequest struct {
	ChallengeID      string `json:"challenge_id"`
	Code             string `json:"code"`
	ClientInstanceID string `json:"client_instance_id"`
	Platform         string `json:"platform"`
	DeviceName       string `json:"device_name"`
	AcceptTerms      bool   `json:"accept_terms"`
}

type TokenResponse struct {
	TokenType    string       `json:"token_type"`
	AccessToken  string       `json:"access_token"`
	RefreshToken string       `json:"refresh_token"`
	RevokeToken  string       `json:"revoke_token"`
	ExpiresIn    int64        `json:"expires_in"`
	User         PublicUser   `json:"user"`
	Device       PublicDevice `json:"device"`
	Created      bool         `json:"created"`
}

type PublicUser struct {
	ID             string `json:"id"`
	Status         string `json:"status"`
	TermsVersion   string `json:"terms_version,omitempty"`
	PrivacyVersion string `json:"privacy_version,omitempty"`
}

type PublicDevice struct {
	ID               string `json:"id"`
	ClientInstanceID string `json:"client_instance_id"`
	Platform         string `json:"platform"`
	DisplayName      string `json:"display_name"`
}

func (a *API) emailStart(w http.ResponseWriter, r *http.Request) {
	a.emailChallengeStart(w, r, "email_login")
}

func (a *API) emailChallengeStart(w http.ResponseWriter, r *http.Request, purpose string) {
	var req emailStartRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	email, err := identity.ParseEmail(req.Email)
	if err != nil {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "email_start_begin")
		return
	}
	defer tx.Rollback(ctx)

	ip := a.clientIP(r)
	limits := []struct {
		key    string
		max    int
		period time.Duration
	}{
		{"email-hour:" + email.Canonical, 5, time.Hour},
		{"email-day:" + email.Canonical, 20, 24 * time.Hour},
		{"ip-hour:" + ip, 20, time.Hour},
		{"global-day", 200, 24 * time.Hour},
	}
	allowed := true
	for _, limit := range limits {
		count, err := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if err != nil {
			a.databaseFailure(w, r, "email_start_rate")
			return
		}
		if count > limit.max {
			allowed = false
		}
	}
	if !allowed {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "email_start_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}

	challengeID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "email_start_random")
		return
	}
	code, err := otpCode()
	if err != nil {
		a.databaseFailure(w, r, "email_start_random")
		return
	}
	now := time.Now().UTC()
	expires := now.Add(10 * time.Minute)
	ipMAC := secure.MAC(a.authMAC, "request-ip-v1", ip)
	codeMAC := secure.MAC(a.authMAC, "email-otp-v1", challengeID, code)

	if _, err := tx.Exec(ctx, `UPDATE auth_challenges
		SET consumed_at=now(),state='consumed'
		WHERE purpose=$2 AND email_canonical=$1 AND consumed_at IS NULL`, email.Canonical, purpose); err != nil {
		a.databaseFailure(w, r, "email_start_supersede")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO auth_challenges
		(id,purpose,email_display,email_canonical,secret_mac,created_at,expires_at,request_ip_mac,user_id,password_version)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8, CASE WHEN $2='password_reset' THEN (SELECT i.user_id FROM identities i JOIN users u ON u.id=i.user_id WHERE i.provider='email' AND i.email_canonical=$4 AND i.status='active' AND u.status='active') ELSE NULL END, CASE WHEN $2='password_reset' THEN (SELECT COALESCE(p.version,0) FROM identities i JOIN users u ON u.id=i.user_id LEFT JOIN user_password_credentials p ON p.user_id=u.id WHERE i.provider='email' AND i.email_canonical=$4 AND i.status='active' AND u.status='active') ELSE NULL END)`, challengeID, purpose, email.Display, email.Canonical, codeMAC, now, expires, ipMAC); err != nil {
		a.databaseFailure(w, r, "email_start_challenge")
		return
	}
	jobID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "email_start_random")
		return
	}
	payload, err := json.Marshal(map[string]string{"to": email.Display, "code": code, "challenge_id": challengeID})
	if err != nil {
		a.databaseFailure(w, r, "email_start_payload")
		return
	}
	sealed, err := a.outboxBox.Seal(payload, []byte("flowriver-outbox-v1|"+jobID+"|email_otp"))
	if err != nil {
		a.databaseFailure(w, r, "email_start_encrypt")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO outbox_jobs(id,kind,payload_ciphertext,created_at,available_at,expires_at)
		VALUES($1,'email_otp',$2,$3,$3,$4)`, jobID, sealed, now, expires); err != nil {
		a.databaseFailure(w, r, "email_start_outbox")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "email_start_commit")
		return
	}
	// Every syntactically valid address receives a challenge identifier, including
	// addresses that are not yet registered. The generic message keeps the start
	// endpoint from becoming an account-enumeration oracle.
	writeJSON(w, http.StatusAccepted, map[string]string{
		"message":      "If the address can receive mail, a verification code will arrive shortly.",
		"challenge_id": challengeID,
	})
}

func (a *API) hitRateLimit(ctx context.Context, tx pgx.Tx, bucket string, limit int, period time.Duration) (int, error) {
	start := time.Now().UTC().Truncate(period)
	window := fmt.Sprintf("%d", start.Unix())
	mac := secure.MAC(a.authMAC, "rate-limit-v1", bucket, window)
	expires := start.Add(period + 48*time.Hour)
	var hits int
	err := tx.QueryRow(ctx, `INSERT INTO rate_limit_buckets(bucket_mac,window_start,hits,expires_at)
		VALUES($1,$2,1,$3)
		ON CONFLICT(bucket_mac) DO UPDATE SET hits=rate_limit_buckets.hits+1,expires_at=EXCLUDED.expires_at
		RETURNING hits`, mac, start, expires).Scan(&hits)
	return hits, err
}

func otpCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(100_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%08d", n.Int64()), nil
}

func (a *API) emailVerify(w http.ResponseWriter, r *http.Request) {
	var req emailVerifyRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	requestKey, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.ChallengeID) || !validUUID(req.ClientInstanceID) || len(req.Code) != 8 || !allDigits(req.Code) {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if req.Platform != "ios" && req.Platform != "macos" && req.Platform != "other" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	req.DeviceName = strings.TrimSpace(req.DeviceName)
	if len(req.DeviceName) > 80 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	bodyMAC := secure.MAC(a.authMAC, "email-verify-v1", req.ChallengeID, req.Code,
		req.ClientInstanceID, req.Platform, req.DeviceName, fmt.Sprint(req.AcceptTerms))
	scope := "email-verify:" + req.ChallengeID

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "email_verify_begin")
		return
	}
	defer tx.Rollback(ctx)
	if cached, found, err := a.cachedResponse(ctx, tx, scope, requestKey, bodyMAC); err != nil {
		writeError(w, r, err)
		return
	} else if found {
		if !a.cachedSessionActive(ctx, tx, cached) {
			writeError(w, r, apiError{Status: 401, Code: "auth_required"})
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "email_verify_idempotency_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}

	var emailCanonical, emailDisplay string
	var expected []byte
	var attempts int
	var consumedAt *time.Time
	err = tx.QueryRow(ctx, `SELECT email_canonical,email_display,secret_mac,attempts,consumed_at
		FROM auth_challenges WHERE id=$1 AND purpose='email_login' AND expires_at>now() FOR UPDATE`, req.ChallengeID).
		Scan(&emailCanonical, &emailDisplay, &expected, &attempts, &consumedAt)
	if err != nil || consumedAt != nil || attempts >= 5 {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if !secure.EqualMAC(expected, secure.MAC(a.authMAC, "email-otp-v1", req.ChallengeID, req.Code)) {
		_, updateErr := tx.Exec(ctx, `UPDATE auth_challenges SET attempts=attempts+1,
			consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END,
			state=CASE WHEN attempts+1>=5 THEN 'consumed' ELSE state END WHERE id=$1`, req.ChallengeID)
		if updateErr != nil {
			a.databaseFailure(w, r, "email_verify_attempt")
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "email_verify_attempt_commit")
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 915304))`, emailCanonical); err != nil {
		a.databaseFailure(w, r, "email_verify_identity_lock")
		return
	}
	var userID, identityID, userStatus, identityStatus string
	var userDisabled bool
	var created bool
	err = tx.QueryRow(ctx, `SELECT i.user_id::text,i.id::text,u.status,i.status,u.disabled_at IS NOT NULL
		FROM identities i JOIN users u ON u.id=i.user_id
		WHERE i.provider='email' AND i.email_canonical=$1 FOR UPDATE OF i,u`, emailCanonical).
		Scan(&userID, &identityID, &userStatus, &identityStatus, &userDisabled)
	if err != nil && err != pgx.ErrNoRows {
		a.databaseFailure(w, r, "email_verify_lookup")
		return
	}
	if err == nil {
		if identityStatus != "active" {
			writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
			return
		}
	}
	if err == pgx.ErrNoRows {
		if !req.AcceptTerms {
			writeError(w, r, apiError{Status: 400, Code: "terms_consent_required"})
			return
		}
		userID, err = insertUser(ctx, tx)
		if err != nil {
			a.databaseFailure(w, r, "email_verify_user")
			return
		}
		if err := tx.QueryRow(ctx, `INSERT INTO identities(user_id,provider,subject,email_display,email_canonical,verified_at)
			VALUES($1,'email',$2,$3,$2,now()) RETURNING id::text`, userID, emailCanonical, emailDisplay).Scan(&identityID); err != nil {
			a.databaseFailure(w, r, "email_verify_identity")
			return
		}
		if _, err := tx.Exec(ctx, `INSERT INTO consents(user_id,terms_version,privacy_version,source)
			VALUES($1,$2,$3,'email')`, userID, a.cfg.TermsVersion, a.cfg.PrivacyVersion); err != nil {
			a.databaseFailure(w, r, "email_verify_consent")
			return
		}
		created = true
	}
	if userStatus != "" && userStatus != "active" {
		writeError(w, r, apiError{Status: 401, Code: "auth_required"})
		return
	}
	if userDisabled {
		writeError(w, r, apiError{Status: 403, Code: "account_disabled"})
		return
	}
	deviceID, err := upsertDevice(ctx, tx, userID, req.ClientInstanceID, req.Platform, req.DeviceName)
	if err != nil {
		a.databaseFailure(w, r, "email_verify_device")
		return
	}
	response, err := a.createSession(ctx, tx, userID, identityID, deviceID, req.ClientInstanceID, created)
	if err != nil {
		a.databaseFailure(w, r, "email_verify_session")
		return
	}
	encoded, err := tokenResponseBytes(response)
	if err != nil {
		a.databaseFailure(w, r, "email_verify_response")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET consumed_at=now(),state='consumed' WHERE id=$1`, req.ChallengeID); err != nil {
		a.databaseFailure(w, r, "email_verify_consume")
		return
	}
	if err := a.saveResponse(ctx, tx, scope, requestKey, bodyMAC, encoded); err != nil {
		a.databaseFailure(w, r, "email_verify_idempotency")
		return
	}
	if err := audit(ctx, tx, userID, "email_login", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "email_verify_audit")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "email_verify_commit")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(encoded)
}

func allDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func insertUser(ctx context.Context, tx pgx.Tx) (string, error) {
	var id string
	err := tx.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id::text`).Scan(&id)
	return id, err
}

func upsertDevice(ctx context.Context, tx pgx.Tx, userID, instanceID, platform, name string) (string, error) {
	var id string
	err := tx.QueryRow(ctx, `INSERT INTO devices(user_id,instance_id,platform,display_name)
		VALUES($1,$2,$3,$4)
		ON CONFLICT(user_id,instance_id) DO UPDATE SET platform=EXCLUDED.platform,
		 display_name=EXCLUDED.display_name,last_seen_at=now(),revoked_at=NULL
		RETURNING id::text`, userID, instanceID, platform, name).Scan(&id)
	return id, err
}

func (a *API) createSession(ctx context.Context, tx pgx.Tx, userID, identityID, deviceID, clientInstanceID string, created bool) (TokenResponse, error) {
	sessionID, err := uuid()
	if err != nil {
		return TokenResponse{}, err
	}
	access, err := secure.RandomToken(32)
	if err != nil {
		return TokenResponse{}, err
	}
	refresh, err := secure.RandomToken(32)
	if err != nil {
		return TokenResponse{}, err
	}
	revoke, err := secure.RandomToken(32)
	if err != nil {
		return TokenResponse{}, err
	}
	now := time.Now().UTC()
	accessExpiry := now.Add(accessLifetime)
	idleExpiry := now.Add(refreshIdle)
	absoluteExpiry := now.Add(refreshAbsolute)
	if _, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now())
		WHERE user_id=$1 AND device_id=$2 AND status='active'`, userID, deviceID); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO sessions(id,user_id,device_id,identity_id,revoke_token_mac,created_at,last_seen_at,idle_expires_at,absolute_expires_at)
		VALUES($1,$2,$3,$4,$5,$6,$6,$7,$8)`, sessionID, userID, deviceID, identityID, bearerHash(revoke), now, idleExpiry, absoluteExpiry); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO access_tokens(token_mac,session_id,created_at,expires_at) VALUES($1,$2,$3,$4)`, bearerHash(access), sessionID, now, accessExpiry); err != nil {
		return TokenResponse{}, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO refresh_tokens(token_mac,session_id,created_at) VALUES($1,$2,$3)`, bearerHash(refresh), sessionID, now); err != nil {
		return TokenResponse{}, err
	}
	var status, acceptedTerms, acceptedPrivacy string
	if err := tx.QueryRow(ctx, `SELECT status,
		COALESCE((SELECT terms_version FROM consents WHERE user_id=users.id ORDER BY accepted_at DESC,id DESC LIMIT 1),''),
		COALESCE((SELECT privacy_version FROM consents WHERE user_id=users.id ORDER BY accepted_at DESC,id DESC LIMIT 1),'')
		FROM users WHERE id=$1`, userID).Scan(&status, &acceptedTerms, &acceptedPrivacy); err != nil {
		return TokenResponse{}, err
	}
	var device PublicDevice
	device.ID, device.ClientInstanceID, device.Platform, device.DisplayName = deviceID, clientInstanceID, "", ""
	if err := tx.QueryRow(ctx, `SELECT platform,display_name FROM devices WHERE id=$1`, deviceID).Scan(&device.Platform, &device.DisplayName); err != nil {
		return TokenResponse{}, err
	}
	return TokenResponse{
		TokenType: "Bearer", AccessToken: access, RefreshToken: refresh, RevokeToken: revoke,
		ExpiresIn: int64(accessLifetime.Seconds()), User: PublicUser{ID: userID, Status: status, TermsVersion: acceptedTerms, PrivacyVersion: acceptedPrivacy},
		Device: device, Created: created,
	}, nil
}

func (a *API) cachedSessionActive(ctx context.Context, tx pgx.Tx, body []byte) bool {
	var response TokenResponse
	if json.Unmarshal(body, &response) != nil || response.AccessToken == "" {
		return false
	}
	var active bool
	err := tx.QueryRow(ctx, `SELECT EXISTS(
		SELECT 1 FROM access_tokens a JOIN sessions s ON s.id=a.session_id JOIN users u ON u.id=s.user_id
		JOIN devices d ON d.id=s.device_id AND d.user_id=s.user_id
		WHERE a.token_mac=$1 AND a.revoked_at IS NULL AND a.expires_at>now()
		AND s.status='active' AND s.revoked_at IS NULL AND s.idle_expires_at>now()
		AND s.absolute_expires_at>now() AND u.status='active' AND u.disabled_at IS NULL AND d.revoked_at IS NULL)`, bearerHash(response.AccessToken)).Scan(&active)
	return err == nil && active
}

func requestIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(requestIDContextKey{}).(string)
	return id
}

func (a *API) databaseFailure(w http.ResponseWriter, r *http.Request, code string) {
	a.log.Error("database operation failed", "request_id", requestIDFromContext(r.Context()), "operation", code)
	writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
}
