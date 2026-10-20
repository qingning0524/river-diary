package httpapi

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/identity"
	"flowriver/server/internal/secure"
)

// Public user-feedback intake. Unauthenticated by design (the feedback form
// lives on the marketing site), so it is aggressively rate-limited and stores
// only an HMAC of the submitter IP.

type feedbackRequest struct {
	ContactEmail string `json:"contact_email"`
	Subject      string `json:"subject"`
	Body         string `json:"body"`
}

func (a *API) submitFeedback(w http.ResponseWriter, r *http.Request) {
	var req feedbackRequest
	if err := decodeJSON(w, r, &req); err != nil {
		writeError(w, r, err)
		return
	}
	body := strings.TrimSpace(req.Body)
	subject := strings.TrimSpace(req.Subject)
	contact := strings.TrimSpace(req.ContactEmail)
	if len([]rune(body)) < 5 || len([]rune(body)) > 4000 || len([]rune(subject)) > 200 {
		writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var contactCanonical string
	if contact != "" {
		parsed, err := identity.ParseEmail(contact)
		if err != nil {
			writeError(w, r, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		contactCanonical = parsed.Canonical
	}
	ip := a.clientIP(r)
	ipMAC := secure.MAC(a.authMAC, "feedback-ip-v1", ip)
	// Loopback callers are the local mail ingest (SMTP pipe) and other trusted
	// local services; per-IP buckets would rate-limit all inbound mail together.
	isLoopbackIP := ip == "127.0.0.1" || ip == "::1"
	userAgent := strings.TrimSpace(r.Header.Get("User-Agent"))
	userAgent = strings.ToValidUTF8(userAgent, "�")
	if len([]rune(userAgent)) > 300 {
		userAgent = string([]rune(userAgent)[:300])
	}
	key := ""
	if r.Header.Get("Idempotency-Key") != "" {
		var err error
		key, err = requestID(r)
		if err != nil {
			writeError(w, r, err)
			return
		}
	}

	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "feedback_begin")
		return
	}
	defer tx.Rollback(ctx)
	scope := "public-feedback:" + hex.EncodeToString(ipMAC)
	requestMAC := secure.MAC(a.authMAC, "public-feedback-request-v1", contactCanonical, subject, body)
	if key != "" {
		if _, err = tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,915311))`, scope+":"+key); err != nil {
			a.databaseFailure(w, r, "feedback_lock")
			return
		}
		if cached, found, e := a.cachedResponse(ctx, tx, scope, key, requestMAC); e != nil {
			writeError(w, r, e)
			return
		} else if found {
			writeJSONBytes(w, 202, cached)
			return
		}
	}
	limits := []struct {
		key    string
		max    int
		period time.Duration
	}{
		{"feedback-ip-hour:" + ip, 5, time.Hour},
		{"feedback-ip-day:" + ip, 12, 24 * time.Hour},
		{"feedback-global-day", 300, 24 * time.Hour},
	}
	if isLoopbackIP {
		limits = limits[2:]
	}
	for _, limit := range limits {
		count, err := a.hitRateLimit(ctx, tx, limit.key, limit.max, limit.period)
		if err != nil {
			a.databaseFailure(w, r, "feedback_rate")
			return
		}
		if count > limit.max {
			if err := tx.Commit(ctx); err != nil {
				a.databaseFailure(w, r, "feedback_rate_commit")
				return
			}
			writeError(w, r, apiError{Status: 429, Code: "rate_limited"})
			return
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO feedback_messages(contact_email,subject,body,user_agent,ip_mac)
		VALUES($1,$2,$3,$4,$5)`, contactCanonical, subject, body, userAgent, ipMAC); err != nil {
		a.databaseFailure(w, r, "feedback_insert")
		return
	}
	response := map[string]string{"message": "反馈已收到,感谢你的意见。若留下了邮箱,我们会尽快回复。"}
	if key != "" {
		encoded, _ := json.Marshal(response)
		if err = a.saveResponseDuration(ctx, tx, scope, key, requestMAC, encoded, 24*time.Hour); err != nil {
			a.databaseFailure(w, r, "feedback_cache")
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "feedback_commit")
		return
	}
	writeJSON(w, http.StatusAccepted, response)
}
