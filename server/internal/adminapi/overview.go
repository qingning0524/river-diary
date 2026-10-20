package adminapi

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

func (a *API) overview(w http.ResponseWriter, r *http.Request) {
	var response struct {
		ActiveAccounts  int        `json:"active_accounts"`
		AllAccounts     int        `json:"all_accounts"`
		ActiveSessions  int        `json:"active_sessions"`
		Devices         int        `json:"devices"`
		PendingMail     int        `json:"pending_mail"`
		FailedMail      int        `json:"failed_mail"`
		PendingSecurity int        `json:"pending_security"`
		OldestSecurity  *time.Time `json:"oldest_security_at"`
		DataUpdatedAt   time.Time  `json:"data_updated_at"`
	}
	err := a.db.QueryRow(r.Context(), `
		SELECT
		 (SELECT count(*)::int FROM users WHERE status='active' AND disabled_at IS NULL),
		 (SELECT count(*)::int FROM users),
		 (SELECT count(*)::int FROM sessions s JOIN users u ON u.id=s.user_id JOIN devices d ON d.id=s.device_id
		  WHERE s.status='active' AND s.revoked_at IS NULL AND s.idle_expires_at>now() AND s.absolute_expires_at>now()
		    AND d.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL),
		 (SELECT count(*)::int FROM devices),
		 (SELECT count(*)::int FROM outbox_jobs WHERE kind='email_otp' AND completed_at IS NULL AND expires_at>now()),
		 (SELECT count(*)::int FROM outbox_jobs WHERE kind='email_otp' AND completed_at IS NOT NULL AND last_error_code IS NOT NULL AND last_error_code NOT IN ('job_expired','challenge_inactive') AND created_at>now()-interval '24 hours'),
		 (SELECT count(*)::int FROM security_event_outbox WHERE delivered_at IS NULL),
		 (SELECT min(occurred_at) FROM security_event_outbox WHERE delivered_at IS NULL),
		now()`).Scan(&response.ActiveAccounts, &response.AllAccounts, &response.ActiveSessions, &response.Devices,
		&response.PendingMail, &response.FailedMail, &response.PendingSecurity, &response.OldestSecurity, &response.DataUpdatedAt)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, 200, response)
}

type userListRow struct {
	PasswordEnabled bool       `json:"password_enabled"`
	Premium         bool       `json:"premium"`
	ID              string     `json:"id"`
	Email           string     `json:"email"`
	Providers       []string   `json:"providers"`
	Status          string     `json:"status"`
	Disabled        bool       `json:"disabled"`
	DeviceCount     int        `json:"device_count"`
	SessionCount    int        `json:"session_count"`
	CreatedAt       time.Time  `json:"created_at"`
	LastActivityAt  *time.Time `json:"last_activity_at"`
}

type userCursor struct {
	CreatedAt time.Time
	ID        string
}

var emailPrefixPattern = regexp.MustCompile(`^[A-Za-z0-9._%+-]{2,64}(@[A-Za-z0-9.-]{0,250})?$`)

func escapeLike(value string) string {
	replacer := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return replacer.Replace(value)
}

func (a *API) users(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	requestedStatus := r.URL.Query().Get("status")
	if requestedStatus != "" && requestedStatus != "active" && requestedStatus != "deleting" && requestedStatus != "recovery_required" && requestedStatus != "disabled" {
		writeError(w, apiError{Status: 400, Code: "invalid_status_filter"})
		return
	}
	password, provider, premium, activity := r.URL.Query().Get("password"), r.URL.Query().Get("provider"), r.URL.Query().Get("premium"), r.URL.Query().Get("activity")
	if (password != "" && password != "set" && password != "unset") || (provider != "" && provider != "email" && provider != "apple") || (premium != "" && premium != "active" && premium != "none") || (activity != "" && activity != "recent" && activity != "inactive") {
		writeError(w, apiError{Status: 400, Code: "invalid_user_filter"})
		return
	}
	var exactEmail string
	var exactID string
	var prefix string
	if query != "" {
		switch {
		case isUUID(query):
			exactID = strings.ToLower(query)
		case strings.Contains(query, "@"):
			email, parseErr := identity.ParseEmail(query)
			if parseErr == nil {
				exactEmail = email.Canonical
			} else if emailPrefixPattern.MatchString(query) {
				prefix = strings.ToLower(escapeLike(query))
			} else {
				writeError(w, apiError{Status: 400, Code: "invalid_query"})
				return
			}
		case emailPrefixPattern.MatchString(query):
			prefix = strings.ToLower(escapeLike(query))
		default:
			writeError(w, apiError{Status: 400, Code: "invalid_query"})
			return
		}
	}
	var cursor *userCursor
	if encoded := r.URL.Query().Get("cursor"); encoded != "" {
		parsed, ok := decodeUserCursor(encoded)
		if !ok {
			writeError(w, apiError{Status: 400, Code: "invalid_cursor"})
			return
		}
		cursor = &parsed
	}
	rows, err := a.db.Query(r.Context(), `
		SELECT u.id::text,u.status,(u.disabled_at IS NOT NULL),u.created_at,
		  COALESCE(min(i.email_display) FILTER(WHERE i.provider='email'),''),
		  COALESCE(array_agg(DISTINCT i.provider ORDER BY i.provider) FILTER(WHERE i.provider IS NOT NULL),'{}'),
		  (SELECT count(*)::int FROM devices d WHERE d.user_id=u.id),
		  (SELECT count(*)::int FROM sessions s JOIN devices sd ON sd.id=s.device_id
		   WHERE s.user_id=u.id AND s.status='active' AND s.revoked_at IS NULL AND s.idle_expires_at>now()
		     AND s.absolute_expires_at>now() AND sd.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL),
		  (SELECT max(d.last_seen_at) FROM devices d WHERE d.user_id=u.id),
          EXISTS(SELECT 1 FROM user_password_credentials p WHERE p.user_id=u.id),
          EXISTS(SELECT 1 FROM user_entitlements e WHERE e.user_id=u.id AND e.product_code='riverdiary_premium' AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now()))
        FROM users u LEFT JOIN identities i ON i.user_id=u.id
		WHERE (($1='' AND $2='' AND $7='')
		      OR ($2<>'' AND u.id=NULLIF($2,'')::uuid)
		      OR ($1<>'' AND EXISTS(SELECT 1 FROM identities ei WHERE ei.user_id=u.id AND ei.provider='email' AND ei.email_canonical=$1))
		      OR ($7<>'' AND EXISTS(SELECT 1 FROM identities ei WHERE ei.user_id=u.id AND ei.provider='email' AND ei.email_canonical LIKE $7||'%')))
		  AND ($3='' OR (u.status=$3 AND ($3<>'active' OR u.disabled_at IS NULL)) OR ($3='disabled' AND u.disabled_at IS NOT NULL))
		  AND ($8='' OR EXISTS(SELECT 1 FROM user_password_credentials p WHERE p.user_id=u.id)=($8='set'))
          AND ($9='' OR EXISTS(SELECT 1 FROM identities pi WHERE pi.user_id=u.id AND pi.provider=$9 AND pi.status='active'))
          AND ($10='' OR EXISTS(SELECT 1 FROM user_entitlements e WHERE e.user_id=u.id AND e.product_code='riverdiary_premium' AND e.starts_at<=now() AND (e.expires_at IS NULL OR e.expires_at>now()))=($10='active'))
          AND ($11='' OR EXISTS(SELECT 1 FROM devices ad WHERE ad.user_id=u.id AND ad.last_seen_at>=now()-interval '7 days')=($11='recent'))
          AND ($4::timestamptz IS NULL OR (u.created_at,u.id)<($4::timestamptz,$5::uuid))
		GROUP BY u.id
		ORDER BY u.created_at DESC,u.id DESC
		LIMIT $6`, exactEmail, exactID, requestedStatus, cursorTimestamp(cursor), cursorID(cursor), limit+1, prefix, password, provider, premium, activity)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	result := make([]userListRow, 0, limit+1)
	for rows.Next() {
		var item userListRow
		var emailDisplay string
		if err := rows.Scan(&item.ID, &item.Status, &item.Disabled, &item.CreatedAt, &emailDisplay, &item.Providers,
			&item.DeviceCount, &item.SessionCount, &item.LastActivityAt, &item.PasswordEnabled, &item.Premium); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		item.Email = maskEmail(emailDisplay)
		result = append(result, item)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if exactEmail != "" || exactID != "" || prefix != "" {
		s := currentSession(r)
		searchKind, target := "user_id_search", exactID
		if exactEmail != "" {
			searchKind = "email_search"
			target = hex.EncodeToString(secure.MAC(a.cfg.AdminAuditHMACKey, "admin-email-search", exactEmail))
		} else if prefix != "" {
			searchKind = "email_prefix_search"
			target = hex.EncodeToString(secure.MAC(a.cfg.AdminAuditHMACKey, "admin-email-prefix-search", prefix))
		}
		if err := a.audit(r.Context(), s.AdminID, "admin.user.search", searchKind, target, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	var next string
	if len(result) > limit {
		last := result[limit-1]
		next = encodeUserCursor(userCursor{CreatedAt: last.CreatedAt, ID: last.ID})
		result = result[:limit]
	}
	writeJSON(w, 200, map[string]any{"users": result, "next_cursor": next, "updated_at": time.Now().UTC()})
}

func (a *API) userDetail(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_user_id"})
		return
	}
	s := currentSession(r)
	var detail struct {
		PasswordEnabled   bool       `json:"password_enabled"`
		PasswordUpdatedAt *time.Time `json:"password_updated_at"`
		ID                string     `json:"id"`
		Status            string     `json:"status"`
		Disabled          bool       `json:"disabled"`
		DisabledReason    string     `json:"disabled_reason,omitempty"`
		DisabledAt        *time.Time `json:"disabled_at"`
		CreatedAt         time.Time  `json:"created_at"`
		Identities        []struct {
			ID         string    `json:"id"`
			Provider   string    `json:"provider"`
			Status     string    `json:"status"`
			Email      string    `json:"email,omitempty"`
			VerifiedAt time.Time `json:"verified_at"`
			Forwarding *bool     `json:"forwarding_enabled,omitempty"`
		} `json:"identities"`
		Entitlements []struct {
			ProductCode string     `json:"product_code"`
			StartsAt    time.Time  `json:"starts_at"`
			ExpiresAt   *time.Time `json:"expires_at"`
			GrantSource string     `json:"grant_source"`
			UpdatedAt   time.Time  `json:"updated_at"`
		} `json:"entitlements"`
		Consents []struct {
			TermsVersion   string    `json:"terms_version"`
			PrivacyVersion string    `json:"privacy_version"`
			Source         string    `json:"source"`
			AcceptedAt     time.Time `json:"accepted_at"`
		} `json:"consents"`
	}
	err := a.db.QueryRow(r.Context(), `SELECT u.id::text,u.status,(u.disabled_at IS NOT NULL),COALESCE(u.disabled_reason,''),u.disabled_at,u.created_at,p.user_id IS NOT NULL,p.updated_at FROM users u LEFT JOIN user_password_credentials p ON p.user_id=u.id WHERE u.id=$1`, id).
		Scan(&detail.ID, &detail.Status, &detail.Disabled, &detail.DisabledReason, &detail.DisabledAt, &detail.CreatedAt, &detail.PasswordEnabled, &detail.PasswordUpdatedAt)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 404, Code: "user_not_found"})
			return
		}
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.audit(r.Context(), s.AdminID, "admin.user.view", "user", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	identities, err := a.db.Query(r.Context(), `SELECT id::text,provider,status,COALESCE(email_display,''),verified_at,email_forwarding_enabled
		FROM identities WHERE user_id=$1 ORDER BY created_at,id`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for identities.Next() {
		var item struct {
			ID         string    `json:"id"`
			Provider   string    `json:"provider"`
			Status     string    `json:"status"`
			Email      string    `json:"email,omitempty"`
			VerifiedAt time.Time `json:"verified_at"`
			Forwarding *bool     `json:"forwarding_enabled,omitempty"`
		}
		var emailDisplay string
		var forwarding bool
		if err := identities.Scan(&item.ID, &item.Provider, &item.Status, &emailDisplay, &item.VerifiedAt, &forwarding); err != nil {
			identities.Close()
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if item.Provider == "email" {
			item.Email = emailDisplay
			item.Forwarding = &forwarding
		}
		detail.Identities = append(detail.Identities, item)
	}
	if err := identities.Err(); err != nil {
		identities.Close()
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	identities.Close()
	entitlements, err := a.db.Query(r.Context(), `SELECT product_code,starts_at,expires_at,grant_source,updated_at FROM user_entitlements WHERE user_id=$1 ORDER BY product_code`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer entitlements.Close()
	for entitlements.Next() {
		var item struct {
			ProductCode string     `json:"product_code"`
			StartsAt    time.Time  `json:"starts_at"`
			ExpiresAt   *time.Time `json:"expires_at"`
			GrantSource string     `json:"grant_source"`
			UpdatedAt   time.Time  `json:"updated_at"`
		}
		if err := entitlements.Scan(&item.ProductCode, &item.StartsAt, &item.ExpiresAt, &item.GrantSource, &item.UpdatedAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		detail.Entitlements = append(detail.Entitlements, item)
	}
	if err := entitlements.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	consents, err := a.db.Query(r.Context(), `SELECT terms_version,privacy_version,source,accepted_at FROM consents WHERE user_id=$1 ORDER BY accepted_at DESC,id DESC LIMIT 20`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer consents.Close()
	for consents.Next() {
		var item struct {
			TermsVersion   string    `json:"terms_version"`
			PrivacyVersion string    `json:"privacy_version"`
			Source         string    `json:"source"`
			AcceptedAt     time.Time `json:"accepted_at"`
		}
		if err := consents.Scan(&item.TermsVersion, &item.PrivacyVersion, &item.Source, &item.AcceptedAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		detail.Consents = append(detail.Consents, item)
	}
	detail.Identities = nonNilItems(detail.Identities)
	detail.Entitlements = nonNilItems(detail.Entitlements)
	detail.Consents = nonNilItems(detail.Consents)
	writeJSON(w, 200, detail)
}

func queryLimit(r *http.Request, fallback, maximum int) int {
	value := r.URL.Query().Get("limit")
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 1 {
		return fallback
	}
	if parsed > maximum {
		return maximum
	}
	return parsed
}

func nullIfEmpty(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func maskEmail(raw string) string {
	if raw == "" {
		return ""
	}
	parts := strings.Split(raw, "@")
	if len(parts) != 2 {
		return "已绑定邮箱"
	}
	local := parts[0]
	if len(local) <= 2 {
		local = "•"
	} else {
		local = local[:2] + "•••"
	}
	return local + "@" + parts[1]
}

func isUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for i, c := range value {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
			continue
		}
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}

func encodeUserCursor(cursor userCursor) string {
	return base64.RawURLEncoding.EncodeToString([]byte(cursor.CreatedAt.UTC().Format(time.RFC3339Nano) + "|" + cursor.ID))
}

func decodeUserCursor(value string) (userCursor, bool) {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return userCursor{}, false
	}
	parts := strings.SplitN(string(decoded), "|", 2)
	if len(parts) != 2 || !isUUID(parts[1]) {
		return userCursor{}, false
	}
	created, err := time.Parse(time.RFC3339Nano, parts[0])
	if err != nil {
		return userCursor{}, false
	}
	return userCursor{CreatedAt: created, ID: parts[1]}, true
}

func cursorTimestamp(value *userCursor) any {
	if value == nil {
		return nil
	}
	return value.CreatedAt
}
func cursorID(value *userCursor) any {
	if value == nil {
		return nil
	}
	return value.ID
}

func nonNilItems[T any](items []T) []T {
	if items == nil {
		return make([]T, 0)
	}
	return items
}
