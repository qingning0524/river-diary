package httpapi

import (
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type activationRedeemRequest struct {
	Code string `json:"code"`
}

type entitlementResponse struct {
	ProductCode string     `json:"product_code"`
	Active      bool       `json:"active"`
	StartsAt    time.Time  `json:"starts_at"`
	ExpiresAt   *time.Time `json:"expires_at"`
	Permanent   bool       `json:"permanent"`
}

var activationCodePattern = regexp.MustCompile(`^[A-Z0-9]{12,32}$`)

func normalizeActivationCode(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, "-", "")
	value = strings.ReplaceAll(value, " ", "")
	return value
}

func (a *API) entitlements(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	rows, err := a.db.Query(ctx, `SELECT product_code,starts_at,expires_at
		FROM user_entitlements WHERE user_id=$1 ORDER BY product_code`, p.UserID)
	if err != nil {
		a.databaseFailure(w, r, "entitlements_read")
		return
	}
	defer rows.Close()
	now := time.Now().UTC()
	items := make([]entitlementResponse, 0)
	for rows.Next() {
		var item entitlementResponse
		if err := rows.Scan(&item.ProductCode, &item.StartsAt, &item.ExpiresAt); err != nil {
			a.databaseFailure(w, r, "entitlements_scan")
			return
		}
		item.Permanent = item.ExpiresAt == nil
		item.Active = item.StartsAt.After(now) == false && (item.ExpiresAt == nil || item.ExpiresAt.After(now))
		items = append(items, item)
	}
	if err := rows.Err(); err != nil {
		a.databaseFailure(w, r, "entitlements_rows")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entitlements": items})
}

func (a *API) redeemActivationCode(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	var req activationRedeemRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	code := normalizeActivationCode(req.Code)
	if !activationCodePattern.MatchString(code) {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	key, err := requestID(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	codeMAC := secure.MAC(a.authMAC, "activation-code-v1", code)
	requestMAC := secure.MAC(a.authMAC, "activation-redemption-request-v1", code)
	scope := "activation-redemption:" + p.SessionID

	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "activation_redeem_begin")
		return
	}
	defer tx.Rollback(ctx)

	if cached, found, err := a.cachedResponse(ctx, tx, scope, key, requestMAC); err != nil {
		writeError(w, r, err)
		return
	} else if found {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "activation_redeem_replay_commit")
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(cached)
		return
	}

	limited, err := a.hitRateLimit(ctx, tx, "activation-redeem-user:"+p.UserID, 12, time.Hour)
	if err != nil {
		a.databaseFailure(w, r, "activation_redeem_rate_limit")
		return
	}
	if limited > 12 {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "activation_redeem_rate_commit")
			return
		}
		writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
		return
	}

	var batchID, productCode string
	var durationDays int
	var batchExpires, redeemedAt, revokedAt *time.Time
	lookupCode := func(mac []byte) error {
		return tx.QueryRow(ctx, `SELECT c.batch_id::text,b.product_code,b.duration_days,b.expires_at,
			c.redeemed_at,c.revoked_at
			FROM activation_codes c JOIN activation_batches b ON b.id=c.batch_id
			WHERE c.code_mac=$1 FOR UPDATE OF c,b`, mac).
			Scan(&batchID, &productCode, &durationDays, &batchExpires, &redeemedAt, &revokedAt)
	}
	err = lookupCode(codeMAC)
	// Before the generator included the visible RD prefix in its stored digest,
	// issued codes were displayed with that prefix but stored without it. Accept
	// that legacy 16-character payload only when the canonical 18-character
	// generated format does not match, so already-issued codes remain redeemable.
	if err == pgx.ErrNoRows && len(code) == 18 && strings.HasPrefix(code, "RD") {
		legacyMAC := secure.MAC(a.authMAC, "activation-code-v1", code[2:])
		if legacyErr := lookupCode(legacyMAC); legacyErr != nil {
			err = legacyErr
		} else {
			codeMAC = legacyMAC
			err = nil
		}
	}
	if err != nil {
		if err != pgx.ErrNoRows {
			a.databaseFailure(w, r, "activation_redeem_lookup")
			return
		}
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "activation_redeem_invalid_commit")
			return
		}
		writeError(w, r, apiError{Status: 422, Code: "activation_code_invalid"})
		return
	}
	// A code may be redeemed only once. Returning one generic error for unknown,
	// expired, revoked, and already-used codes avoids leaking their stored state.
	var batchRevokedAt *time.Time
	if err := tx.QueryRow(ctx, `SELECT revoked_at FROM activation_batches WHERE id=$1`, batchID).Scan(&batchRevokedAt); err != nil {
		a.databaseFailure(w, r, "activation_redeem_batch")
		return
	}
	if redeemedAt != nil || revokedAt != nil || batchRevokedAt != nil || (batchExpires != nil && !batchExpires.After(time.Now())) {
		if err := tx.Commit(ctx); err != nil {
			a.databaseFailure(w, r, "activation_redeem_unavailable_commit")
			return
		}
		writeError(w, r, apiError{Status: 422, Code: "activation_code_invalid"})
		return
	}
	if _, err := tx.Exec(ctx, `SELECT id FROM users WHERE id=$1 FOR UPDATE`, p.UserID); err != nil {
		a.databaseFailure(w, r, "activation_redeem_user_lock")
		return
	}

	now := time.Now().UTC()
	var previousStarts time.Time
	var previousExpires *time.Time
	err = tx.QueryRow(ctx, `SELECT starts_at,expires_at FROM user_entitlements WHERE user_id=$1 AND product_code=$2 FOR UPDATE`, p.UserID, productCode).Scan(&previousStarts, &previousExpires)
	if err != nil && err != pgx.ErrNoRows {
		a.databaseFailure(w, r, "activation_entitlement_lookup")
		return
	}
	startsAt := now
	var expiresAt *time.Time
	if durationDays == 0 {
		expiresAt = nil
	} else if err == nil && previousExpires == nil {
		// A lifetime grant cannot be shortened by a later timed code.
		startsAt = previousStarts
		expiresAt = nil
	} else {
		if err == nil && previousExpires != nil && previousExpires.After(now) {
			startsAt = *previousExpires
		}
		end := startsAt.AddDate(0, 0, durationDays)
		expiresAt = &end
	}
	if _, err := tx.Exec(ctx, `UPDATE activation_codes SET redeemed_at=$2,redeemed_user_id=$3 WHERE code_mac=$1 AND redeemed_at IS NULL AND revoked_at IS NULL`, codeMAC, now, p.UserID); err != nil {
		a.databaseFailure(w, r, "activation_code_redeem")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO user_entitlements(user_id,product_code,starts_at,expires_at,updated_at)
		VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,product_code) DO UPDATE SET
		starts_at=EXCLUDED.starts_at,expires_at=EXCLUDED.expires_at,updated_at=EXCLUDED.updated_at`,
		p.UserID, productCode, startsAt, expiresAt, now); err != nil {
		a.databaseFailure(w, r, "activation_entitlement_upsert")
		return
	}
	var codeID string
	if err := tx.QueryRow(ctx, `SELECT id::text FROM activation_codes WHERE code_mac=$1`, codeMAC).Scan(&codeID); err != nil {
		a.databaseFailure(w, r, "activation_code_id")
		return
	}
	if _, err := tx.Exec(ctx, `INSERT INTO activation_redemptions(activation_code_id,user_id,product_code,granted_at,starts_at,expires_at)
		VALUES($1,$2,$3,$4,$5,$6)`, codeID, p.UserID, productCode, now, startsAt, expiresAt); err != nil {
		a.databaseFailure(w, r, "activation_redemption_history")
		return
	}
	response := map[string]any{"status": "redeemed", "product_code": productCode, "starts_at": startsAt, "expires_at": expiresAt, "permanent": expiresAt == nil}
	encoded, err := json.Marshal(response)
	if err != nil {
		a.databaseFailure(w, r, "activation_redeem_response")
		return
	}
	if err := a.saveResponse(ctx, tx, scope, key, requestMAC, encoded); err != nil {
		a.databaseFailure(w, r, "activation_redeem_idempotency")
		return
	}
	if err := audit(ctx, tx, p.UserID, "activation_code_redeemed", requestIDFromContext(r.Context())); err != nil {
		a.databaseFailure(w, r, "activation_redeem_audit")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "activation_redeem_commit")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(encoded)
}
