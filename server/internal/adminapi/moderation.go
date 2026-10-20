package adminapi

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type reasonRequest struct {
	Reason string `json:"reason_code"`
}

var userActionReasons = map[string]bool{"user_request": true, "suspicious_activity": true, "policy_violation": true, "other": true}

func validReason(reason string) bool { return userActionReasons[reason] }

func (a *API) setUserDisabled(disabled bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := strings.ToLower(r.PathValue("id"))
		if !isUUID(id) {
			writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
			return
		}
		var input reasonRequest
		if err := decodeJSON(w, r, &input); err != nil {
			writeError(w, err)
			return
		}
		if !validReason(input.Reason) {
			writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
			return
		}
		s := currentSession(r)
		tx, err := a.db.Begin(r.Context())
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		defer tx.Rollback(r.Context())
		var status string
		var already bool
		if err := tx.QueryRow(r.Context(), `SELECT status,(disabled_at IS NOT NULL) FROM users WHERE id=$1 FOR UPDATE`, id).Scan(&status, &already); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, apiError{Status: 404, Code: "user_not_found"})
			} else {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			}
			return
		}
		if status == "deleted" {
			writeError(w, apiError{Status: 409, Code: "user_not_active"})
			return
		}
		if disabled == already {
			writeError(w, apiError{Status: 409, Code: "user_state_unchanged"})
			return
		}
		if disabled {
			if _, err := tx.Exec(r.Context(), `UPDATE users SET disabled_at=now(),disabled_reason=$2 WHERE id=$1`, id, input.Reason); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
			if _, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1 AND status='active'`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
			if _, err := tx.Exec(r.Context(), `UPDATE access_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE session_id IN(SELECT id FROM sessions WHERE user_id=$1) AND revoked_at IS NULL`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
		} else {
			if _, err := tx.Exec(r.Context(), `UPDATE users SET disabled_at=NULL,disabled_reason=NULL WHERE id=$1`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
		}
		action := "admin.user.enable"
		if disabled {
			action = "admin.user.disable"
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, action, "user", id, input.Reason, "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "disabled": disabled})
	}
}

func (a *API) forceLogoutUser(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	var input reasonRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !validReason(input.Reason) {
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var exists bool
	if err := tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1)`, id).Scan(&exists); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !exists {
		writeError(w, apiError{Status: 404, Code: "user_not_found"})
		return
	}
	tag, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1 AND status='active'`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	revoked := tag.RowsAffected()
	if _, err := tx.Exec(r.Context(), `UPDATE access_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE session_id IN(SELECT id FROM sessions WHERE user_id=$1) AND revoked_at IS NULL`, id); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.user.force_logout", "user", id, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "revoked_sessions": revoked})
}

func (a *API) userSessions(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	rows, err := a.db.Query(r.Context(), `SELECT s.id::text,s.status,s.created_at,s.last_seen_at,s.idle_expires_at,s.absolute_expires_at,s.revoked_at,
		COALESCE(d.platform,''),COALESCE(d.display_name,''),d.revoked_at IS NOT NULL
		FROM sessions s LEFT JOIN devices d ON d.id=s.device_id
		WHERE s.user_id=$1 ORDER BY s.created_at DESC LIMIT 200`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID             string     `json:"id"`
		Status         string     `json:"status"`
		CreatedAt      time.Time  `json:"created_at"`
		LastSeenAt     time.Time  `json:"last_seen_at"`
		IdleExpiresAt  time.Time  `json:"idle_expires_at"`
		AbsExpiresAt   time.Time  `json:"absolute_expires_at"`
		RevokedAt      *time.Time `json:"revoked_at"`
		Platform       string     `json:"platform"`
		DeviceName     string     `json:"device_name"`
		DeviceRevoked  bool       `json:"device_revoked"`
		CurrentlyValid bool       `json:"currently_valid"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Status, &it.CreatedAt, &it.LastSeenAt, &it.IdleExpiresAt, &it.AbsExpiresAt, &it.RevokedAt, &it.Platform, &it.DeviceName, &it.DeviceRevoked); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		it.CurrentlyValid = it.Status == "active" && it.RevokedAt == nil && it.IdleExpiresAt.After(time.Now()) && it.AbsExpiresAt.After(time.Now()) && !it.DeviceRevoked
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": items})
}

func (a *API) revokeUserSession(w http.ResponseWriter, r *http.Request) {
	userID := strings.ToLower(r.PathValue("id"))
	sessionID := strings.ToLower(r.PathValue("sid"))
	if !isUUID(userID) || !isUUID(sessionID) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input reasonRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !validReason(input.Reason) {
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2`, sessionID, userID)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "session_not_found"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE access_tokens SET revoked_at=COALESCE(revoked_at,now()) WHERE session_id=$1 AND revoked_at IS NULL`, sessionID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.user.session.revoke", "session", sessionID, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": sessionID, "status": "revoked"})
}

type grantEntitlementRequest struct {
	ProductCode  string `json:"product_code"`
	DurationDays int    `json:"duration_days"`
	Reason       string `json:"reason_code"`
}

func (a *API) grantEntitlement(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	var input grantEntitlementRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !validReason(input.Reason) || input.DurationDays < 0 || input.DurationDays > 36500 || !activationProductPattern.MatchString(input.ProductCode) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if input.ProductCode == "" {
		input.ProductCode = "riverdiary_premium"
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var exists bool
	if err := tx.QueryRow(r.Context(), `SELECT EXISTS(SELECT 1 FROM users WHERE id=$1)`, id).Scan(&exists); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if !exists {
		writeError(w, apiError{Status: 404, Code: "user_not_found"})
		return
	}
	var expires *time.Time
	if input.DurationDays > 0 {
		if err := tx.QueryRow(r.Context(), `SELECT GREATEST(COALESCE(expires_at,now()),now())+make_interval(days=>$2)
			FROM user_entitlements WHERE user_id=$1 AND product_code=$3`, id, input.DurationDays, input.ProductCode).Scan(&expires); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	if _, err := tx.Exec(r.Context(), `INSERT INTO user_entitlements(user_id,product_code,starts_at,expires_at,grant_source)
		VALUES($1,$2,now(),$3,'admin_grant')
		ON CONFLICT(user_id,product_code) DO UPDATE SET starts_at=LEAST(user_entitlements.starts_at,now()),
		 expires_at=EXCLUDED.expires_at,grant_source='admin_grant',updated_at=now()`, id, input.ProductCode, expires); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.user.entitlement.grant", "user", id, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "product_code": input.ProductCode, "expires_at": expires, "grant_source": "admin_grant"})
}

func (a *API) revokeEntitlement(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	product := strings.ToLower(r.PathValue("product"))
	if !isUUID(id) || !activationProductPattern.MatchString(product) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input reasonRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !validReason(input.Reason) {
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE user_entitlements SET expires_at=now(),grant_source='admin_revoke',updated_at=now() WHERE user_id=$1 AND product_code=$2`, id, product)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "entitlement_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.user.entitlement.revoke", "user", id, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "product_code": product, "status": "revoked"})
}

// ---- 管理员账号管理 ----

type createAdminRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

func (a *API) listAdmins(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT a.id::text,a.username,a.disabled_at,a.created_at,a.last_login_at,
		(SELECT count(*)::int FROM admin_sessions s WHERE s.admin_id=a.id AND s.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now())
		FROM admin_accounts a ORDER BY a.created_at LIMIT 50`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID             string     `json:"id"`
		Username       string     `json:"username"`
		DisabledAt     *time.Time `json:"disabled_at"`
		CreatedAt      time.Time  `json:"created_at"`
		LastLoginAt    *time.Time `json:"last_login_at"`
		ActiveSessions int        `json:"active_sessions"`
		IsYou          bool       `json:"is_you"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Username, &it.DisabledAt, &it.CreatedAt, &it.LastLoginAt, &it.ActiveSessions); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		it.IsYou = it.ID == currentSession(r).AdminID
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"admins": items})
}

func (a *API) createAdmin(w http.ResponseWriter, r *http.Request) {
	var input createAdminRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	username, ok := normalizeUsername(input.Username)
	if !ok {
		writeError(w, apiError{Status: 400, Code: "invalid_username"})
		return
	}
	hash, err := createPasswordHash(input.Password)
	if err != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_password"})
		return
	}
	secret, encodedSecret, err := randomTOTPSecret()
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	id, err := randomUUID()
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	sealed, err := a.totpBox.Seal(secret, []byte("flowriver-admin-totp:"+id))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	if _, err := tx.Exec(r.Context(), `INSERT INTO admin_accounts(id,username,password_hash,totp_secret_ciphertext)
		VALUES($1,$2,$3,$4)`, id, username, hash, sealed); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			writeError(w, apiError{Status: 409, Code: "admin_username_exists"})
			return
		}
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.account.create", "admin_account", id, username, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "username": username, "totp_uri": totpProvisioningURI(username, encodedSecret)})
}

func mustSealTOTP(a *API, adminID string, secret []byte) []byte {
	sealed, err := a.totpBox.Seal(secret, []byte("flowriver-admin-totp:"+adminID))
	if err != nil {
		return nil
	}
	return sealed
}

func (a *API) setAdminDisabled(enabled bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := strings.ToLower(r.PathValue("id"))
		if !isUUID(id) {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		var input reasonRequest
		if err := decodeJSON(w, r, &input); err != nil {
			writeError(w, err)
			return
		}
		if !validReason(input.Reason) {
			writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
			return
		}
		s := currentSession(r)
		if !enabled && id == s.AdminID {
			writeError(w, apiError{Status: 409, Code: "admin_cannot_disable_self"})
			return
		}
		tx, err := a.db.Begin(r.Context())
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		defer tx.Rollback(r.Context())
		var username string
		var disabled bool
		if err := tx.QueryRow(r.Context(), `SELECT username,(disabled_at IS NOT NULL) FROM admin_accounts WHERE id=$1 FOR UPDATE`, id).Scan(&username, &disabled); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, apiError{Status: 404, Code: "admin_not_found"})
			} else {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			}
			return
		}
		if enabled == !disabled {
			writeError(w, apiError{Status: 409, Code: "admin_state_unchanged"})
			return
		}
		if !enabled {
			var activeCount int
			if err := tx.QueryRow(r.Context(), `SELECT count(*)::int FROM admin_accounts WHERE disabled_at IS NULL AND id<>$1`, id).Scan(&activeCount); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
			if activeCount == 0 {
				writeError(w, apiError{Status: 409, Code: "admin_last_active"})
				return
			}
		}
		if enabled {
			if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET disabled_at=NULL WHERE id=$1`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
		} else {
			if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET disabled_at=now() WHERE id=$1`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
			if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET revoked_at=now() WHERE admin_id=$1 AND revoked_at IS NULL`, id); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
		}
		action := "admin.account.enable"
		if !enabled {
			action = "admin.account.disable"
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, action, "admin_account", id, input.Reason, "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "disabled": !enabled})
	}
}

func (a *API) resetAdminTOTP(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	// Resetting this administrator revokes the very session needed to save the
	// one-time URI. Another administrator or the SSH recovery CLI must do it.
	if id == currentSession(r).AdminID {
		writeError(w, apiError{Status: http.StatusConflict, Code: "admin_cannot_reset_self"})
		return
	}
	var input reasonRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !validReason(input.Reason) {
		writeError(w, apiError{Status: 400, Code: "invalid_reason_code"})
		return
	}
	secret, encodedSecret, err := randomTOTPSecret()
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var username string
	err = tx.QueryRow(r.Context(), `SELECT username FROM admin_accounts WHERE id=$1 AND disabled_at IS NULL FOR UPDATE`, id).Scan(&username)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 404, Code: "admin_not_found"})
		} else {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		}
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_accounts SET totp_secret_ciphertext=$2,totp_last_step=-1 WHERE id=$1`, id, mustSealTOTP(a, id, secret)); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET revoked_at=now() WHERE admin_id=$1 AND revoked_at IS NULL`, id); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.account.totp_reset", "admin_account", id, input.Reason, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "totp_uri": totpProvisioningURI(username, encodedSecret)})
}

func (a *API) listAdminSessions(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT s.id::text,a.username,s.created_at,s.last_seen_at,s.idle_expires_at,s.absolute_expires_at,(s.token_mac=$1)
		FROM admin_sessions s JOIN admin_accounts a ON a.id=s.admin_id
		WHERE s.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now()
		ORDER BY s.last_seen_at DESC LIMIT 100`, currentSession(r).TokenMAC)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID          string    `json:"id"`
		Username    string    `json:"username"`
		CreatedAt   time.Time `json:"created_at"`
		LastSeenAt  time.Time `json:"last_seen_at"`
		IdleExpires time.Time `json:"idle_expires_at"`
		AbsExpires  time.Time `json:"absolute_expires_at"`
		IsYou       bool      `json:"is_you"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Username, &it.CreatedAt, &it.LastSeenAt, &it.IdleExpires, &it.AbsExpires, &it.IsYou); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": items})
}

func (a *API) revokeAdminSession(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE admin_sessions SET revoked_at=now() WHERE id=$1 AND revoked_at IS NULL`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "session_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.session.revoke", "admin_session", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "revoked"})
}
