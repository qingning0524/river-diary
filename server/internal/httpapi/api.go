package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strings"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/mailer"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	accessLifetime  = 15 * time.Minute
	refreshIdle     = 30 * 24 * time.Hour
	refreshAbsolute = 90 * 24 * time.Hour
	refreshRetry    = 60 * time.Second
	maxRequestBytes = 64 << 10
)

type API struct {
	db          *pgxpool.Pool
	cfg         config.Config
	authMAC     []byte
	outboxBox   *secure.Box
	resultBox   *secure.Box
	appleBox    *secure.Box
	mailer      mailer.Sender
	log         *slog.Logger
	apple       *AppleProvider
	journal     SecurityJournal
	passwordSem chan struct{}
}

type AppleTokenRevoker interface {
	Revoke(context.Context, string, string) error
}

func (a *API) SecurityJournal() SecurityJournal     { return a.journal }
func (a *API) AppleTokenRevoker() AppleTokenRevoker { return a.apple }

type Principal struct {
	UserID     string
	SessionID  string
	DeviceID   string
	IdentityID string
}

type contextKey uint8

const principalKey contextKey = 1

type apiError struct {
	Status int
	Code   string
}

func (e apiError) Error() string { return e.Code }

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:-]{8,128}$`)
var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

func New(db *pgxpool.Pool, cfg config.Config, sender mailer.Sender, logger *slog.Logger) (*API, error) {
	outboxBox, err := secure.NewBox(cfg.OutboxEncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("initialize outbox encryption: %w", err)
	}
	resultBox, err := secure.NewBox(cfg.IdempotencyKey)
	if err != nil {
		return nil, fmt.Errorf("initialize idempotency encryption: %w", err)
	}
	appleBox, err := secure.NewBox(cfg.AppleTokenEncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("initialize Apple token encryption: %w", err)
	}
	api := &API{db: db, cfg: cfg, authMAC: cfg.AuthHMACKey, outboxBox: outboxBox, resultBox: resultBox, appleBox: appleBox, mailer: sender, log: logger, passwordSem: make(chan struct{}, 1)}
	if cfg.AppleEnabled {
		api.apple, err = NewAppleProvider(cfg, appleBox)
		if err != nil {
			return nil, fmt.Errorf("initialize Apple provider: %w", err)
		}
	}
	if cfg.SecurityJournalEndpoint != "" {
		api.journal, err = NewHTTPSecurityJournal(cfg)
		if err != nil {
			return nil, fmt.Errorf("initialize security journal: %w", err)
		}
	}
	return api, nil
}

func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", a.live)
	mux.HandleFunc("GET /health/ready", a.ready)
	mux.HandleFunc("GET /v1/announcements/active", a.announcementsActive)
	mux.HandleFunc("GET /v1/site-status", a.siteStatus)
	mux.HandleFunc("GET /downloads/{filename}", a.downloadArtifact)
	mux.HandleFunc("GET /v1/changelog", a.changelogPublished)
	mux.HandleFunc("POST /v1/feedback", a.submitFeedback)
	mux.HandleFunc("POST /v1/auth/email/start", a.emailStart)
	mux.HandleFunc("POST /v1/auth/email/verify", a.emailVerify)
	mux.HandleFunc("POST /v1/auth/password/login", a.passwordLogin)
	mux.HandleFunc("POST /v1/auth/password/reset/start", a.passwordResetStart)
	mux.HandleFunc("POST /v1/auth/password/reset/complete", a.passwordResetComplete)
	mux.HandleFunc("GET /v1/me/password", a.passwordStatus)
	mux.HandleFunc("GET /v1/me/sessions", a.consoleSessions)
	mux.HandleFunc("POST /v1/me/sessions/{id}/revoke", a.consoleRevokeSession)
	mux.HandleFunc("GET /v1/me/activity", a.consoleActivity)
	mux.HandleFunc("GET /v1/me/redemptions", a.consoleRedemptions)
	mux.HandleFunc("GET /v1/me/feedback", a.consoleFeedback)
	mux.HandleFunc("POST /v1/me/feedback", a.consoleSubmitFeedback)
	mux.HandleFunc("GET /v1/me/memory-mirror/meta", a.memoryMirrorMeta)
	mux.HandleFunc("GET /v1/me/memory-mirror", a.memoryMirrorDownload)
	mux.HandleFunc("PUT /v1/me/memory-mirror", a.memoryMirrorUpload)
	mux.HandleFunc("DELETE /v1/me/memory-mirror", a.memoryMirrorDelete)
	mux.HandleFunc("POST /v1/auth/refresh", a.refresh)
	mux.HandleFunc("POST /v1/auth/logout", a.logout)
	mux.HandleFunc("GET /v1/me", a.me)
	mux.HandleFunc("GET /v1/me/entitlements", a.entitlements)
	mux.HandleFunc("GET /v1/ai/quota", a.officialAIQuota)
	mux.HandleFunc("POST /v1/ai/chat", a.officialAIChat)
	mux.HandleFunc("POST /v1/me/activation-codes/redeem", a.redeemActivationCode)
	mux.HandleFunc("GET /v1/me/devices", a.devices)
	mux.HandleFunc("POST /v1/me/devices/{id}/revoke", a.revokeDevice)
	mux.HandleFunc("POST /v1/me/identities/email/start", a.linkEmailStart)
	mux.HandleFunc("POST /v1/me/identities/email/complete", a.linkEmailComplete)
	mux.HandleFunc("DELETE /v1/me/identities/{id}", a.revokeIdentity)
	mux.HandleFunc("GET /v1/me/security-changes/{id}", a.securityChangeStatus)
	mux.HandleFunc("POST /v1/me/identities/apple/start", a.linkAppleStart)
	mux.HandleFunc("POST /v1/me/identities/apple/complete", a.linkAppleComplete)
	mux.HandleFunc("POST /v1/auth/apple/start", a.appleStart)
	mux.HandleFunc("POST /v1/auth/apple/complete", a.appleComplete)
	mux.HandleFunc("POST /v1/provider/apple/notifications", a.appleNotification)
	mux.HandleFunc("POST /v1/me/reauth/email/start", a.reauthEmailStart)
	mux.HandleFunc("POST /v1/me/reauth/email/verify", a.reauthEmailVerify)
	mux.HandleFunc("POST /v1/me/reauth/apple/start", a.reauthAppleStart)
	mux.HandleFunc("POST /v1/me/reauth/apple/complete", a.reauthAppleComplete)
	mux.HandleFunc("POST /v1/me/deletion", a.deleteAccount)
	mux.HandleFunc("GET /v1/me/deletion-status", a.deletionStatus)
	return a.requestBoundary(mux)
}

func (a *API) requestBoundary(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID, err := secure.RandomToken(18)
		if err != nil {
			writeError(w, r, apiError{Status: 500, Code: "internal_error"})
			return
		}
		requestID = "r_" + requestID
		w.Header().Set("X-Request-ID", requestID)
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch {
			limit := int64(maxRequestBytes)
			if r.Method == http.MethodPut && r.URL.Path == "/v1/me/memory-mirror" {
				limit = memoryMirrorMaxEnvelope
			}
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		tracked := &responseState{ResponseWriter: w}
		defer func() {
			if recovered := recover(); recovered != nil {
				a.log.Error("request handler panic recovered", "request_id", requestID)
				if !tracked.wrote {
					writeError(tracked, r.WithContext(context.WithValue(r.Context(), requestIDContextKey{}, requestID)), apiError{Status: 500, Code: "internal_error"})
				}
			}
		}()
		next.ServeHTTP(tracked, r.WithContext(context.WithValue(r.Context(), requestIDContextKey{}, requestID)))
	})
}

type responseState struct {
	http.ResponseWriter
	wrote bool
}

func (w *responseState) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *responseState) WriteHeader(code int) {
	if w.wrote {
		return
	}
	w.wrote = true
	w.ResponseWriter.WriteHeader(code)
}
func (w *responseState) Write(data []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

type requestIDContextKey struct{}

func (a *API) live(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) ready(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := a.db.Ping(ctx); err != nil {
		writeError(w, r, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func (a *API) authenticate(r *http.Request) (context.Context, Principal, error) {
	parts := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || parts[1] == "" || len(parts[1]) > 256 {
		return r.Context(), Principal{}, apiError{Status: 401, Code: "auth_required"}
	}
	tokenMAC := secure.Digest(parts[1])
	var p Principal
	err := a.db.QueryRow(r.Context(), `
		SELECT s.user_id::text, s.id::text, s.device_id::text, COALESCE(s.identity_id::text,'')
		FROM access_tokens a
		JOIN sessions s ON s.id=a.session_id
		JOIN users u ON u.id=s.user_id
		JOIN devices d ON d.id=s.device_id AND d.user_id=s.user_id
		WHERE a.token_mac=$1 AND a.revoked_at IS NULL AND a.expires_at>now()
		  AND s.status='active' AND s.idle_expires_at>now() AND s.absolute_expires_at>now()
		  AND s.revoked_at IS NULL AND d.revoked_at IS NULL AND u.status='active' AND u.disabled_at IS NULL`, tokenMAC).
		Scan(&p.UserID, &p.SessionID, &p.DeviceID, &p.IdentityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return r.Context(), Principal{}, apiError{Status: 401, Code: "auth_required"}
	}
	if err != nil {
		return r.Context(), Principal{}, apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	updated, err := a.db.Exec(r.Context(), `UPDATE devices SET last_seen_at=now() WHERE id=$1 AND last_seen_at<now()-interval '5 minutes'`, p.DeviceID)
	if err != nil {
		return r.Context(), Principal{}, apiError{Status: 503, Code: "temporarily_unavailable"}
	}
	if updated.RowsAffected() > 0 {
		if _, err := a.db.Exec(r.Context(), `UPDATE sessions SET last_seen_at=now() WHERE id=$1`, p.SessionID); err != nil {
			return r.Context(), Principal{}, apiError{Status: 503, Code: "temporarily_unavailable"}
		}
	}
	return context.WithValue(r.Context(), principalKey, p), p, nil
}

func (a *API) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, _, err := a.authenticate(r)
		if err != nil {
			writeError(w, r, err)
			return
		}
		next(w, r.WithContext(ctx))
	}
}

func principalFrom(ctx context.Context) Principal {
	p, _ := ctx.Value(principalKey).(Principal)
	return p
}

func (a *API) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	remote := net.ParseIP(strings.Trim(host, "[]"))
	if remote != nil && remote.IsLoopback() {
		// The deployment proxy must overwrite this header with the real peer.
		// The application trusts it only on a loopback connection.
		forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-For"))
		if !strings.Contains(forwarded, ",") {
			if ip := net.ParseIP(forwarded); ip != nil {
				return ip.String()
			}
		}
	}
	if remote == nil {
		return "unknown"
	}
	return remote.String()
}

func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) error {
	if r.Header.Get("Content-Type") != "application/json" && !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json;") {
		return apiError{Status: 400, Code: "invalid_request"}
	}
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			return apiError{Status: 413, Code: "request_too_large"}
		}
		return apiError{Status: 400, Code: "invalid_request"}
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return apiError{Status: 400, Code: "invalid_request"}
	}
	return nil
}

func requestID(r *http.Request) (string, error) {
	id := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if !requestIDPattern.MatchString(id) {
		return "", apiError{Status: 400, Code: "invalid_request"}
	}
	return id, nil
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, r *http.Request, err error) {
	var problem apiError
	if !errors.As(err, &problem) {
		problem = apiError{Status: 500, Code: "internal_error"}
	}
	if problem.Status == 429 {
		w.Header().Set("Retry-After", "60")
	}
	request, _ := r.Context().Value(requestIDContextKey{}).(string)
	writeJSON(w, problem.Status, map[string]string{"error": problem.Code, "request_id": request})
}

func uuid() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}

func validUUID(id string) bool { return uuidPattern.MatchString(id) }

func bearerHash(token string) []byte { return secure.Digest(token) }

func audit(ctx context.Context, tx pgx.Tx, userID, kind, request string) error {
	var uid any
	if userID != "" {
		uid = userID
	}
	_, err := tx.Exec(ctx, `INSERT INTO audit_events(user_id,kind,request_id) VALUES($1,$2,$3)`, uid, kind, request)
	return err
}

func tokenResponseBytes(v TokenResponse) ([]byte, error) { return json.Marshal(v) }
