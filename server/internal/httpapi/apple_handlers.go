package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type appleStartRequest struct{}
type appleStartResponse struct {
	AttemptID string   `json:"attempt_id"`
	Nonce     string   `json:"nonce"`
	ClientIDs []string `json:"client_ids"`
	ExpiresIn int      `json:"expires_in"`
}
type appleCompleteRequest struct {
	AttemptID         string `json:"attempt_id"`
	IdentityToken     string `json:"identity_token"`
	AuthorizationCode string `json:"authorization_code"`
	ClientInstanceID  string `json:"client_instance_id"`
	Platform          string `json:"platform"`
	DeviceName        string `json:"device_name"`
	AcceptTerms       bool   `json:"accept_terms"`
}

func (a *API) appleStart(w http.ResponseWriter, r *http.Request) {
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req appleStartRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "apple_start_begin")
		return
	}
	defer tx.Rollback(ctx)
	count, err := a.hitRateLimit(ctx, tx, "apple-start-ip-hour:"+a.clientIP(r), 50, time.Hour)
	if err != nil {
		a.databaseFailure(w, r, "apple_start_rate")
		return
	}
	if count > 50 {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "apple_start_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	attemptID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "apple_start_random")
		return
	}
	nonce, err := secure.RandomToken(32)
	if err != nil {
		a.databaseFailure(w, r, "apple_start_random")
		return
	}
	nonceClaim := hashAppleNonce(nonce)
	mac := secure.MAC(a.authMAC, "apple-nonce-v1", attemptID, nonceClaim)
	if _, err := tx.Exec(ctx, `INSERT INTO auth_challenges(id,purpose,secret_mac,created_at,expires_at)
		VALUES($1,'apple_login',$2,now(),now()+interval '5 minutes')`, attemptID, mac); err != nil {
		a.databaseFailure(w, r, "apple_start_attempt")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "apple_start_commit")
		return
	}
	writeJSON(w, http.StatusOK, appleStartResponse{AttemptID: attemptID, Nonce: nonce, ClientIDs: a.cfg.AppleClientIDs, ExpiresIn: 300})
}

func (a *API) appleComplete(w http.ResponseWriter, r *http.Request) {
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req appleCompleteRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	requestKey, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if !validUUID(req.AttemptID) || !validUUID(req.ClientInstanceID) || len(req.IdentityToken) < 40 || len(req.IdentityToken) > 16<<10 || len(req.AuthorizationCode) < 10 || len(req.AuthorizationCode) > 4<<10 {
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
	bodyMAC := secure.MAC(a.authMAC, "apple-complete-v1", req.AttemptID, hexDigest(req.IdentityToken), hexDigest(req.AuthorizationCode), req.ClientInstanceID, req.Platform, req.DeviceName, boolString(req.AcceptTerms))
	scope := "apple-complete:" + req.AttemptID
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "apple_complete_begin")
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
			a.databaseFailure(w, r, "apple_complete_cache_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}
	count, err := a.hitRateLimit(ctx, tx, "apple-complete-ip-hour:"+a.clientIP(r), 50, time.Hour)
	if err != nil {
		a.databaseFailure(w, r, "apple_complete_rate")
		return
	}
	if count > 50 {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "apple_complete_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}
	var nonceMAC []byte
	var state string
	var leaseUntil *time.Time
	var attempts int
	var consumedAt *time.Time
	err = tx.QueryRow(ctx, `SELECT secret_mac,state,lease_until,attempts,consumed_at FROM auth_challenges
		WHERE id=$1 AND purpose='apple_login' AND expires_at>now() FOR UPDATE`, req.AttemptID).Scan(&nonceMAC, &state, &leaseUntil, &attempts, &consumedAt)
	if errors.Is(err, pgx.ErrNoRows) || consumedAt != nil || attempts >= 5 {
		writeError(w, r, apiError{Status: 401, Code: "invalid_or_expired_challenge"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "apple_complete_attempt")
		return
	}
	if state == "exchanging" && leaseUntil != nil && leaseUntil.After(time.Now()) {
		writeError(w, r, apiError{Status: 409, Code: "auth_attempt_in_progress"})
		return
	}
	leaseID, err := uuid()
	if err != nil {
		a.databaseFailure(w, r, "apple_complete_random")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='exchanging',exchange_lease_id=$2,lease_until=now()+interval '15 seconds' WHERE id=$1`, req.AttemptID, leaseID); err != nil {
		a.databaseFailure(w, r, "apple_complete_lease")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "apple_complete_lease_commit")
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
	if !secure.EqualMAC(nonceMAC, secure.MAC(a.authMAC, "apple-nonce-v1", req.AttemptID, claims.Nonce)) {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, true)
		writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		return
	}
	var knownIdentity bool
	if err := a.db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM identities WHERE provider='apple' AND subject=$1)`, claims.Subject).Scan(&knownIdentity); err != nil {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, false)
		a.databaseFailure(w, r, "apple_complete_identity_check")
		return
	}
	if !knownIdentity && !req.AcceptTerms {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, false)
		writeError(w, r, apiError{Status: 400, Code: "terms_consent_required"})
		return
	}
	clientID := claims.Audience[0]
	tokens, exchangedClaims, err := requestAppleCode(ctx, a.apple, clientID, req.AuthorizationCode)
	if err != nil {
		if transientAppleFailure(err) {
			a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, false)
			writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
			return
		}
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, true)
		writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		return
	}
	if exchangedClaims.Subject != claims.Subject || exchangedClaims.Nonce != claims.Nonce || exchangedClaims.Audience[0] != clientID {
		a.releaseAppleAttempt(ctx, req.AttemptID, leaseID, true)
		writeError(w, r, apiError{Status: 401, Code: "invalid_apple_credential"})
		return
	}
	if err := a.finishAppleLogin(w, r, req, requestKey, scope, bodyMAC, leaseID, tokens, claims); err != nil {
		writeError(w, r, err)
	}
}

func (a *API) releaseAppleAttempt(ctx context.Context, id, lease string, failed bool) {
	if failed {
		_, _ = a.db.Exec(ctx, `UPDATE auth_challenges SET attempts=attempts+1,state=CASE WHEN attempts+1>=5 THEN 'consumed' ELSE 'pending' END,
		consumed_at=CASE WHEN attempts+1>=5 THEN now() ELSE consumed_at END,exchange_lease_id=NULL,lease_until=NULL
		WHERE id=$1 AND exchange_lease_id=$2`, id, lease)
		return
	}
	_, _ = a.db.Exec(ctx, `UPDATE auth_challenges SET state='pending',exchange_lease_id=NULL,lease_until=NULL WHERE id=$1 AND exchange_lease_id=$2`, id, lease)
}

func (a *API) finishAppleLogin(w http.ResponseWriter, r *http.Request, req appleCompleteRequest, requestKey, scope string, bodyMAC []byte, leaseID string, tokens appleTokenResponse, claims *appleClaims) error {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	defer tx.Rollback(ctx)
	var currentLease string
	var state string
	var consumedAt *time.Time
	if err := tx.QueryRow(ctx, `SELECT exchange_lease_id::text,state,consumed_at FROM auth_challenges WHERE id=$1 FOR UPDATE`, req.AttemptID).Scan(&currentLease, &state, &consumedAt); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if state != "exchanging" || currentLease != leaseID || consumedAt != nil {
		return apiError{Status: 409, Code: "auth_attempt_expired"}
	}
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,1721))`, claims.Subject); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	var userID, identityID, userStatus, identityStatus string
	var userDisabled bool
	err = tx.QueryRow(ctx, `SELECT i.user_id::text,i.id::text,u.status,i.status,u.disabled_at IS NOT NULL FROM identities i JOIN users u ON u.id=i.user_id
		WHERE i.provider='apple' AND i.subject=$1 FOR UPDATE OF i,u`, claims.Subject).Scan(&userID, &identityID, &userStatus, &identityStatus, &userDisabled)
	created := false
	if errors.Is(err, pgx.ErrNoRows) {
		if !req.AcceptTerms {
			return apiError{Status: 400, Code: "terms_consent_required"}
		}
		userID, err = insertUser(ctx, tx)
		if err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		identityID, err = uuid()
		if err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		refreshCipher, sealErr := a.appleBox.Seal([]byte(tokens.RefreshToken), []byte("flowriver-apple-refresh-v1|"+identityID))
		if sealErr != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		var verifiedEmail any
		if claims.Email != "" && bool(claims.EmailVerified) {
			verifiedEmail = claims.Email
		}
		if _, err := tx.Exec(ctx, `INSERT INTO identities(id,user_id,provider,provider_client_id,subject,email_display,email_forwarding_enabled,refresh_token_ciphertext,verified_at)
			VALUES($1,$2,'apple',$3,$4,$5,true,$6,now())`, identityID, userID, claims.Audience[0], claims.Subject, verifiedEmail, refreshCipher); err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		if _, err := tx.Exec(ctx, `INSERT INTO consents(user_id,terms_version,privacy_version,source) VALUES($1,$2,$3,'apple')`, userID, a.cfg.TermsVersion, a.cfg.PrivacyVersion); err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		created = true
	} else if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if identityStatus != "" && identityStatus != "active" {
		return apiError{Status: 409, Code: "identity_requires_reauthentication"}
	}
	if userStatus != "" && userStatus != "active" {
		return apiError{Status: 401, Code: "auth_required"}
	}
	if userDisabled {
		return apiError{Status: 403, Code: "account_disabled"}
	}
	if identityID != "" && tokens.RefreshToken != "" {
		sealed, sealErr := a.appleBox.Seal([]byte(tokens.RefreshToken), []byte("flowriver-apple-refresh-v1|"+identityID))
		if sealErr != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
		if _, err := tx.Exec(ctx, `UPDATE identities SET refresh_token_ciphertext=$2,provider_client_id=$3,updated_at=now() WHERE id=$1`, identityID, sealed, claims.Audience[0]); err != nil {
			return apiError{Status: 503, Code: "temporarily_unavailable"}
		}
	}
	deviceID, err := upsertDevice(ctx, tx, userID, req.ClientInstanceID, req.Platform, req.DeviceName)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	response, err := a.createSession(ctx, tx, userID, identityID, deviceID, req.ClientInstanceID, created)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if _, err := tx.Exec(ctx, `UPDATE auth_challenges SET state='consumed',consumed_at=now(),exchange_lease_id=NULL,lease_until=NULL WHERE id=$1`, req.AttemptID); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if err := a.saveResponse(ctx, tx, scope, requestKey, bodyMAC, encoded); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if err := audit(ctx, tx, userID, "apple_login", requestIDFromContext(r.Context())); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if err := tx.Commit(ctx); err != nil {
		return apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(encoded)
	return nil
}

func (a *API) appleNotification(w http.ResponseWriter, r *http.Request) {
	if a.apple == nil {
		writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
		return
	}
	var req struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := decodeJSON(w, r, &req); err != nil || req.SignedPayload == "" || len(req.SignedPayload) > 32<<10 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	claims, err := a.apple.verifyNotification(ctx, req.SignedPayload)
	if err != nil {
		if transientAppleFailure(err) {
			writeError(w, r, apiError{Status: 503, Code: "provider_unavailable"})
			return
		}
		writeError(w, r, apiError{Status: 401, Code: "invalid_provider_event"})
		return
	}
	eventType := claims.Events.Type
	if eventType != "email-enabled" && eventType != "email-disabled" && eventType != "consent-revoked" && eventType != "account-deleted" {
		writeError(w, r, apiError{Status: 400, Code: "unsupported_provider_event"})
		return
	}
	subject := claims.Events.Sub
	if subject == "" {
		subject = claims.Subject
	}
	eventID := claims.ID
	if eventID == "" || subject == "" {
		writeError(w, r, apiError{Status: 400, Code: "invalid_provider_event"})
		return
	}
	payloadMAC := secure.MAC(a.authMAC, "apple-event-v1", req.SignedPayload)
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "apple_event_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO provider_events(event_id,provider,event_type,payload_mac)
		VALUES($1,'apple',$2,$3) ON CONFLICT(event_id) DO NOTHING`, eventID, eventType, payloadMAC); err != nil {
		a.databaseFailure(w, r, "apple_event_store")
		return
	}
	var storedMAC []byte
	var processedAt *time.Time
	if err := tx.QueryRow(ctx, `SELECT payload_mac,processed_at FROM provider_events WHERE event_id=$1 FOR UPDATE`, eventID).Scan(&storedMAC, &processedAt); err != nil {
		a.databaseFailure(w, r, "apple_event_read")
		return
	}
	if !secure.EqualMAC(storedMAC, payloadMAC) {
		writeError(w, r, apiError{Status: 409, Code: "provider_event_conflict"})
		return
	}
	if processedAt != nil {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "apple_event_duplicate_commit")
			return
		}
		w.WriteHeader(http.StatusOK)
		return
	}
	var identityID, userID string
	err = tx.QueryRow(ctx, `SELECT id::text,user_id::text FROM identities WHERE provider='apple' AND subject=$1`, subject).Scan(&identityID, &userID)
	if errors.Is(err, pgx.ErrNoRows) {
		if _, err := tx.Exec(ctx, `UPDATE provider_events SET processed_at=now() WHERE event_id=$1`, eventID); err != nil {
			a.databaseFailure(w, r, "apple_event_mark")
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "apple_event_commit")
			return
		}
		w.WriteHeader(http.StatusOK)
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "apple_event_identity")
		return
	}
	if eventType == "email-disabled" || eventType == "email-enabled" {
		enabled := eventType == "email-enabled"
		if _, err := tx.Exec(ctx, `UPDATE identities SET email_forwarding_enabled=$2,updated_at=now() WHERE id=$1`, identityID, enabled); err != nil {
			a.databaseFailure(w, r, "apple_event_email")
			return
		}
		if _, err := tx.Exec(ctx, `UPDATE provider_events SET processed_at=now() WHERE event_id=$1`, eventID); err != nil {
			a.databaseFailure(w, r, "apple_event_mark")
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "apple_event_commit")
			return
		}
		w.WriteHeader(http.StatusOK)
		return
	}
	tx.Rollback(ctx)
	if a.journal == nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	occurred := time.Now().UTC()
	if claims.IssuedAt != nil {
		occurred = claims.IssuedAt.Time
	}
	if err := a.journal.Append(ctx, SecurityEvent{EventID: eventID, UserID: userID, IdentityID: identityID, Kind: "apple_" + eventType, OccurredAt: occurred}); err != nil {
		a.log.Error("security journal rejected Apple event", "request_id", requestIDFromContext(r.Context()), "event_id", eventID)
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	tx, err = a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "apple_event_apply_begin")
		return
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE identities SET status='revoked',refresh_token_ciphertext=NULL,updated_at=now() WHERE id=$1`, identityID); err != nil {
		a.databaseFailure(w, r, "apple_event_revoke_identity")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE identity_id=$1`, identityID); err != nil {
		a.databaseFailure(w, r, "apple_event_revoke_sessions")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET status='recovery_required' WHERE id=$1 AND NOT EXISTS(SELECT 1 FROM identities WHERE user_id=$1 AND status='active')`, userID); err != nil {
		a.databaseFailure(w, r, "apple_event_recovery")
		return
	}
	if _, err := tx.Exec(ctx, `UPDATE provider_events SET processed_at=now() WHERE event_id=$1`, eventID); err != nil {
		a.databaseFailure(w, r, "apple_event_mark")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "apple_event_apply_commit")
		return
	}
	w.WriteHeader(http.StatusOK)
}

func hexDigest(value string) string { return fmt.Sprintf("%x", appleFingerprint(value)) }
func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}
