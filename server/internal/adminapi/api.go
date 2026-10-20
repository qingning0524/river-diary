package adminapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/adminui"
	"flowriver/server/internal/config"
	"flowriver/server/internal/mailer"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	sessionCookie = "__Host-flowriver-admin"
	csrfCookie    = "__Host-flowriver-admin-csrf"
	maxBodyBytes  = 32 << 10
)

type API struct {
	db          *pgxpool.Pool
	cfg         config.Config
	totpBox     *secure.Box
	actionBox   *secure.Box
	log         *slog.Logger
	startedAt   time.Time
	passwordSem chan struct{}
	assets      http.Handler
	fakeHash    string
	mailSender  mailer.Sender
}

type session struct {
	AdminID              string
	Username             string
	TokenMAC             []byte
	CSRFMac              []byte
	IPMac                []byte
	ReauthenticatedUntil *time.Time
}

type apiError struct {
	Status int
	Code   string
}

func (e apiError) Error() string { return e.Code }

func New(db *pgxpool.Pool, cfg config.Config, logger *slog.Logger, mailSender mailer.Sender) (*API, error) {
	if !cfg.AdminEnabled {
		return nil, fmt.Errorf("administrator console is disabled")
	}
	box, err := secure.NewBox(cfg.AdminTOTPEncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("initialize administrator TOTP encryption: %w", err)
	}
	activationKey := secure.MAC(cfg.AdminAuditHMACKey, "admin-activation-output-encryption-v1")
	actionBox, err := secure.NewBox(activationKey)
	if err != nil {
		return nil, fmt.Errorf("initialize activation output encryption: %w", err)
	}
	assets, err := adminui.Handler()
	if err != nil {
		return nil, fmt.Errorf("load administrator console: %w", err)
	}
	return &API{db: db, cfg: cfg, totpBox: box, actionBox: actionBox, log: logger, startedAt: time.Now().UTC(), passwordSem: make(chan struct{}, 1), assets: assets, fakeHash: dummyPasswordHash(), mailSender: mailSender}, nil
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /admin-api/v1/auth/session", a.sessionInfo)
	mux.HandleFunc("POST /admin-api/v1/auth/login", a.login)
	mux.HandleFunc("POST /admin-api/v1/auth/mfa", a.completeMFA)
	mux.HandleFunc("POST /admin-api/v1/auth/logout", a.logout)
	mux.HandleFunc("POST /admin-api/v1/auth/reauthenticate", a.reauthenticate)
	mux.HandleFunc("POST /admin-api/v1/auth/change-password", a.requireSession(a.changePassword))
	mux.HandleFunc("GET /admin-api/v1/overview", a.requireSession(a.overview))
	mux.HandleFunc("GET /admin-api/v1/users", a.requireSession(a.users))
	mux.HandleFunc("GET /admin-api/v1/users/summary", a.requireSession(a.userSummary))
	mux.HandleFunc("GET /admin-api/v1/users/{id}/activity", a.requireSession(a.userActivity))
	mux.HandleFunc("GET /admin-api/v1/users/{id}", a.requireSession(a.userDetail))
	mux.HandleFunc("POST /admin-api/v1/users/{id}/password/reset", a.requireSession(a.resetUserPassword))
	mux.HandleFunc("GET /admin-api/v1/devices", a.requireSession(a.devices))
	mux.HandleFunc("GET /admin-api/v1/mail-jobs", a.requireSession(a.mailJobs))
	mux.HandleFunc("GET /admin-api/v1/security-events", a.requireSession(a.securityEvents))
	mux.HandleFunc("GET /admin-api/v1/audit", a.requireSession(a.auditEvents))
	mux.HandleFunc("GET /admin-api/v1/operations", a.requireSession(a.operations))
	mux.HandleFunc("GET /admin-api/v1/config-status", a.requireSession(a.configStatus))
	mux.HandleFunc("GET /admin-api/v1/activation/batches", a.requireSession(a.activationBatches))
	mux.HandleFunc("GET /admin-api/v1/activation/codes", a.requireSession(a.activationCodes))
	mux.HandleFunc("POST /admin-api/v1/activation/batches", a.requireSession(a.createActivationBatch))
	mux.HandleFunc("POST /admin-api/v1/activation/batches/import", a.requireSession(a.importActivationBatch))
	mux.HandleFunc("DELETE /admin-api/v1/activation/codes/{id}", a.requireSession(a.revokeActivationCode))
	mux.HandleFunc("POST /admin-api/v1/devices/{id}/revoke", a.requireSession(a.revokeDevice))
	mux.HandleFunc("POST /admin-api/v1/operations/restore-drill", a.requireSession(a.recordRestoreDrill))
	// 公告与下载管理
	mux.HandleFunc("GET /admin-api/v1/announcements", a.requireSession(a.listAnnouncements))
	mux.HandleFunc("POST /admin-api/v1/announcements", a.requireSession(a.createAnnouncement))
	mux.HandleFunc("POST /admin-api/v1/announcements/{id}", a.requireSession(a.updateAnnouncement))
	mux.HandleFunc("POST /admin-api/v1/announcements/{id}/activate", a.requireSession(a.activateAnnouncement(true)))
	mux.HandleFunc("POST /admin-api/v1/announcements/{id}/deactivate", a.requireSession(a.activateAnnouncement(false)))
	mux.HandleFunc("DELETE /admin-api/v1/announcements/{id}", a.requireSession(a.deleteAnnouncement))
	mux.HandleFunc("GET /admin-api/v1/downloads", a.requireSession(a.listDownloads))
	mux.HandleFunc("POST /admin-api/v1/downloads", a.requireSession(a.uploadDownload))
	mux.HandleFunc("POST /admin-api/v1/downloads/{id}/activate", a.requireSession(a.activateDownload(true)))
	mux.HandleFunc("POST /admin-api/v1/downloads/{id}/deactivate", a.requireSession(a.activateDownload(false)))
	mux.HandleFunc("POST /admin-api/v1/downloads/{id}/note", a.requireSession(a.updateDownloadNote))
	// 用户管理增强
	mux.HandleFunc("POST /admin-api/v1/users/{id}/disable", a.requireSession(a.setUserDisabled(true)))
	mux.HandleFunc("POST /admin-api/v1/users/{id}/enable", a.requireSession(a.setUserDisabled(false)))
	mux.HandleFunc("POST /admin-api/v1/users/{id}/force-logout", a.requireSession(a.forceLogoutUser))
	mux.HandleFunc("GET /admin-api/v1/users/{id}/sessions", a.requireSession(a.userSessions))
	mux.HandleFunc("POST /admin-api/v1/users/{id}/sessions/{sid}/revoke", a.requireSession(a.revokeUserSession))
	mux.HandleFunc("POST /admin-api/v1/users/{id}/entitlements", a.requireSession(a.grantEntitlement))
	mux.HandleFunc("DELETE /admin-api/v1/users/{id}/entitlements/{product}", a.requireSession(a.revokeEntitlement))
	// 管理员管理
	mux.HandleFunc("GET /admin-api/v1/admins", a.requireSession(a.listAdmins))
	mux.HandleFunc("POST /admin-api/v1/admins", a.requireSession(a.createAdmin))
	mux.HandleFunc("POST /admin-api/v1/admins/{id}/disable", a.requireSession(a.setAdminDisabled(false)))
	mux.HandleFunc("POST /admin-api/v1/admins/{id}/enable", a.requireSession(a.setAdminDisabled(true)))
	mux.HandleFunc("POST /admin-api/v1/admins/{id}/totp-reset", a.requireSession(a.resetAdminTOTP))
	mux.HandleFunc("GET /admin-api/v1/admin-sessions", a.requireSession(a.listAdminSessions))
	mux.HandleFunc("POST /admin-api/v1/admin-sessions/{id}/revoke", a.requireSession(a.revokeAdminSession))
	// 更新日志管理
	mux.HandleFunc("GET /admin-api/v1/changelog", a.requireSession(a.listChangelog))
	mux.HandleFunc("POST /admin-api/v1/changelog", a.requireSession(a.createChangelog))
	mux.HandleFunc("POST /admin-api/v1/changelog/{id}", a.requireSession(a.updateChangelog))
	mux.HandleFunc("DELETE /admin-api/v1/changelog/{id}", a.requireSession(a.deleteChangelog))
	mux.HandleFunc("POST /admin-api/v1/changelog/{id}/publish", a.requireSession(a.activateChangelog(true)))
	mux.HandleFunc("POST /admin-api/v1/changelog/{id}/unpublish", a.requireSession(a.activateChangelog(false)))
	// 运营与诊断
	mux.HandleFunc("GET /admin-api/v1/stats", a.requireSession(a.stats))
	mux.HandleFunc("GET /admin-api/v1/ratelimits/top", a.requireSession(a.rateLimitTop))
	mux.HandleFunc("POST /admin-api/v1/ratelimits/lookup", a.requireSession(a.rateLimitLookup))
	mux.HandleFunc("POST /admin-api/v1/ratelimits/clear", a.requireSession(a.rateLimitClear))
	mux.HandleFunc("GET /admin-api/v1/backup-runs", a.requireSession(a.backupRuns))
	mux.HandleFunc("POST /admin-api/v1/mail-jobs/{id}/retry", a.requireSession(a.retryMailJob))
	// 反馈收件箱与邮件发送
	mux.HandleFunc("GET /admin-api/v1/mailbox/feedback", a.requireSession(a.listFeedback))
	mux.HandleFunc("POST /admin-api/v1/mailbox/feedback/{id}/read", a.requireSession(a.setFeedbackStatus("read")))
	mux.HandleFunc("POST /admin-api/v1/mailbox/feedback/{id}/archive", a.requireSession(a.setFeedbackStatus("archived")))
	mux.HandleFunc("POST /admin-api/v1/mailbox/feedback/{id}/reply", a.requireSession(a.replyFeedback))
	mux.HandleFunc("POST /admin-api/v1/mailbox/send", a.requireSession(a.sendMail))
	mux.HandleFunc("POST /admin-api/v1/mailbox/preview", a.requireSessionMode(a.previewMail, false))
	mux.HandleFunc("GET /admin-api/v1/mailbox/outbound", a.requireSession(a.listOutbound))
	mux.HandleFunc("GET /admin-api/v1/mailbox/outbound/{id}", a.requireSession(a.outboundDetail))
	mux.HandleFunc("GET /admin-api/v1/mailbox/inbound", a.requireSession(a.listInbound))
	mux.HandleFunc("POST /admin-api/v1/mailbox/inbound/{id}/read", a.requireSession(a.markInboundRead))
	mux.HandleFunc("POST /admin-api/v1/mailbox/inbound/{id}/reply", a.requireSession(a.replyInbound))
	mux.HandleFunc("DELETE /admin-api/v1/mailbox/inbound/{id}", a.requireSession(a.deleteInbound))
	mux.Handle("/", a.assets)
	protected := a.boundary(mux)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if len(a.cfg.AdminAllowedNetworks) > 0 {
			ip := net.ParseIP(a.requestIP(r))
			allowed := false
			for _, network := range a.cfg.AdminAllowedNetworks {
				if ip != nil && network.Contains(ip) {
					allowed = true
					break
				}
			}
			if !allowed {
				writeError(w, apiError{Status: 403, Code: "admin_network_rejected"})
				return
			}
		}
		protected.ServeHTTP(w, r)
	})
}

func (a *API) boundary(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID, err := secure.RandomToken(18)
		if err != nil {
			writeError(w, apiError{Status: 500, Code: "internal_error"})
			return
		}
		requestID = "a_" + requestID
		w.Header().Set("X-Request-ID", requestID)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'")
		w.Header().Set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
		w.Header().Set("Cross-Origin-Opener-Policy", "same-origin")
		w.Header().Set("X-Request-ID", requestID)
		if r.Method == http.MethodPost {
			limit := int64(maxBodyBytes)
			if strings.HasPrefix(r.URL.Path, "/admin-api/v1/downloads") {
				limit = maxDownloadBytes + (1 << 20)
			}
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		ctx := context.WithValue(r.Context(), requestIDKey{}, requestID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type requestIDKey struct{}

func (a *API) sessionInfo(w http.ResponseWriter, r *http.Request) {
	s, err := a.readSession(r, false)
	if err != nil {
		if apiErr, ok := err.(apiError); ok && apiErr.Status == 503 {
			writeError(w, err)
			return
		}
		clearCookies(w)
		setup, setupErr := a.bootstrapAvailable(r.Context())
		if setupErr != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, 200, map[string]any{"authenticated": false, "setup_required": setup})
		return
	}
	writeJSON(w, 200, map[string]any{
		"authenticated":             true,
		"username":                  s.Username,
		"reauthentication_required": s.ReauthenticatedUntil == nil || time.Now().After(*s.ReauthenticatedUntil),
	})
}

func (a *API) requireSession(next http.HandlerFunc) http.HandlerFunc {
	return a.requireSessionMode(next, true)
}
func (a *API) requireSessionMode(next http.HandlerFunc, recentMFA bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		s, err := a.readSession(r, true)
		if err != nil {
			if apiErr, ok := err.(apiError); ok && apiErr.Status == http.StatusUnauthorized {
				clearCookies(w)
			}
			writeError(w, err)
			return
		}
		if !safeMethod(r.Method) {
			if err := a.verifyCSRFAndOrigin(r, s); err != nil {
				writeError(w, err)
				return
			}
		}
		if recentMFA && r.Method != http.MethodGet && r.Method != http.MethodHead {
			if err := a.requireRecentMFA(w, r, s); err != nil {
				writeError(w, err)
				return
			}
		}
		if r.Method == http.MethodGet || r.Method == http.MethodHead {
			if token, err := r.Cookie(sessionCookie); err == nil {
				if csrf, err := r.Cookie(csrfCookie); err == nil {
					a.setCookies(w, token.Value, csrf.Value)
				}
			}
		}
		r = r.WithContext(context.WithValue(r.Context(), sessionKey{}, s))
		next(w, r)
	}
}

type sessionKey struct{}

func (a *API) readSession(r *http.Request, touch bool) (session, error) {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil || len(cookie.Value) < 32 || len(cookie.Value) > 128 {
		return session{}, apiError{Status: 401, Code: "admin_auth_required"}
	}
	tokenMAC := secure.Digest(cookie.Value)
	var s session
	err = a.db.QueryRow(r.Context(), `
		SELECT s.admin_id::text, a.username, s.token_mac, s.csrf_mac, s.ip_mac, s.reauthenticated_until
		FROM admin_sessions s JOIN admin_accounts a ON a.id=s.admin_id
		WHERE s.token_mac=$1 AND s.revoked_at IS NULL AND s.idle_expires_at>now()
		  AND s.absolute_expires_at>now() AND a.disabled_at IS NULL`, tokenMAC).
		Scan(&s.AdminID, &s.Username, &s.TokenMAC, &s.CSRFMac, &s.IPMac, &s.ReauthenticatedUntil)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return session{}, apiError{Status: 401, Code: "admin_auth_required"}
		}
		return session{}, apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if touch {
		if _, err := a.db.Exec(r.Context(), `UPDATE admin_sessions SET last_seen_at=now(), idle_expires_at=LEAST(now()+interval '15 minutes',absolute_expires_at) WHERE token_mac=$1`, tokenMAC); err != nil {
			return session{}, apiError{Status: 503, Code: "temporarily_unavailable"}
		}
	}
	return s, nil
}

func (a *API) verifyCSRFAndOrigin(r *http.Request, s session) error {
	if r.Header.Get("Origin") != a.cfg.AdminOrigin {
		return apiError{Status: 403, Code: "origin_rejected"}
	}
	csrfCookie, err := r.Cookie(csrfCookie)
	if err != nil || csrfCookie.Value == "" || len(csrfCookie.Value) > 128 {
		return apiError{Status: 403, Code: "csrf_rejected"}
	}
	if !secure.EqualMAC(s.CSRFMac, secure.Digest(csrfCookie.Value)) || !secure.EqualMAC(s.CSRFMac, secure.Digest(r.Header.Get("X-CSRF-Token"))) {
		return apiError{Status: 403, Code: "csrf_rejected"}
	}
	return nil
}

func currentSession(r *http.Request) session {
	s, _ := r.Context().Value(sessionKey{}).(session)
	return s
}

func (a *API) requestIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer := net.ParseIP(strings.Trim(host, "[]"))
	// Caddy connects over loopback and overwrites X-Real-IP with the peer it saw.
	// Never trust a forwarded header sent by a non-loopback peer.
	if peer != nil && peer.IsLoopback() {
		if ip := net.ParseIP(strings.TrimSpace(r.Header.Get("X-Real-IP"))); ip != nil {
			return ip.String()
		}
	}
	if peer == nil {
		return "unknown"
	}
	return peer.String()
}

func (a *API) ipMAC(r *http.Request) []byte {
	return secure.MAC(a.cfg.AdminAuditHMACKey, "admin-request-ip", a.requestIP(r))
}

func (a *API) audit(ctx context.Context, adminID, action, targetType, targetID, reason, result string, ipMAC []byte) error {
	return insertAudit(ctx, a.db, adminID, action, targetType, targetID, reason, result, ipMAC)
}

func (a *API) auditTx(ctx context.Context, tx pgx.Tx, adminID, action, targetType, targetID, reason, result string, ipMAC []byte) error {
	return insertAudit(ctx, tx, adminID, action, targetType, targetID, reason, result, ipMAC)
}

type dbExecutor interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func insertAudit(ctx context.Context, executor dbExecutor, adminID, action, targetType, targetID, reason, result string, ipMAC []byte) error {
	requestID, _ := ctx.Value(requestIDKey{}).(string)
	if requestID == "" {
		requestID = "admin_background"
	}
	_, err := executor.Exec(ctx, `INSERT INTO admin_audit_events(admin_id,action,target_type,target_id,reason_code,result,request_id,ip_mac)
		VALUES(NULLIF($1,'')::uuid,$2,$3,$4,$5,$6,$7,$8)`, adminID, action, targetType, targetID, reason, result, requestID, ipMAC)
	return err
}

func (a *API) mustAudit(r *http.Request, s session, action, targetType, targetID, reason, result string) error {
	if err := a.audit(r.Context(), s.AdminID, action, targetType, targetID, reason, result, s.IPMac); err != nil {
		a.log.Error("administrator audit write failed", "request_id", r.Context().Value(requestIDKey{}), "action", action)
		return fmt.Errorf("administrator audit write failed")
	}
	return nil
}

func (a *API) bootstrapAvailable(ctx context.Context) (bool, error) {
	var exists bool
	if err := a.db.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM admin_accounts)`).Scan(&exists); err != nil {
		return false, err
	}
	return !exists, nil
}

func safeMethod(method string) bool {
	return method == http.MethodGet || method == http.MethodHead || method == http.MethodOptions
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, err error) {
	code := "internal_error"
	status := 500
	if apiErr, ok := err.(apiError); ok {
		code, status = apiErr.Code, apiErr.Status
	}
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code}})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, destination any) error {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return apiError{Status: 400, Code: "invalid_request"}
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return apiError{Status: 400, Code: "invalid_request"}
	}
	return nil
}

func clearCookies(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: "", Path: "/", MaxAge: -1, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	http.SetCookie(w, &http.Cookie{Name: csrfCookie, Value: "", Path: "/", MaxAge: -1, Secure: true, HttpOnly: false, SameSite: http.SameSiteStrictMode})
}

func (a *API) setCookies(w http.ResponseWriter, rawToken, rawCSRF string) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: rawToken, Path: "/", MaxAge: 15 * 60, Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
	http.SetCookie(w, &http.Cookie{Name: csrfCookie, Value: rawCSRF, Path: "/", MaxAge: 15 * 60, Secure: true, HttpOnly: false, SameSite: http.SameSiteStrictMode})
}
