package adminapi

import (
	"context"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/identity"
	"github.com/jackc/pgx/v5"
)

// ---- 用户反馈收件箱 ----

func (a *API) listFeedback(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if len([]rune(query)) > 200 {
		writeError(w, apiError{Status: 400, Code: "invalid_query"})
		return
	}
	status := r.URL.Query().Get("status")
	if status != "" && status != "new" && status != "read" && status != "replied" && status != "archived" {
		writeError(w, apiError{Status: 400, Code: "invalid_status_filter"})
		return
	}
	var after time.Time
	var afterID string
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		decoded, ok := decodeDeviceCursor(raw)
		if !ok {
			writeError(w, apiError{Status: 400, Code: "invalid_cursor"})
			return
		}
		after, afterID = decoded.Timestamp, decoded.ID
	}
	rows, err := a.db.Query(r.Context(), `SELECT id::text,contact_email,subject,body,user_agent,status,reply_body,replied_at,created_at
		FROM feedback_messages
		WHERE ($1='' OR status=$1)
		  AND ($2::timestamptz IS NULL OR (created_at,id)<($2::timestamptz,$3::uuid))
 AND ($5='' OR contact_email ILIKE '%'||$5||'%' OR subject ILIKE '%'||$5||'%' OR body ILIKE '%'||$5||'%')
		ORDER BY created_at DESC,id DESC LIMIT $4`,
		status, nullableTimestamp(after), nullIfEmpty(afterID), limit+1, escapeLike(query))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID           string     `json:"id"`
		ContactEmail string     `json:"contact_email"`
		Subject      string     `json:"subject"`
		Body         string     `json:"body"`
		UserAgent    string     `json:"user_agent"`
		Status       string     `json:"status"`
		ReplyBody    string     `json:"reply_body"`
		RepliedAt    *time.Time `json:"replied_at"`
		CreatedAt    time.Time  `json:"created_at"`
	}
	items := make([]item, 0, limit+1)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.ContactEmail, &it.Subject, &it.Body, &it.UserAgent, &it.Status, &it.ReplyBody, &it.RepliedAt, &it.CreatedAt); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	next := ""
	if len(items) > limit {
		last := items[limit-1]
		next = encodeDeviceCursor(last.CreatedAt, last.ID)
		items = items[:limit]
	}
	var newCount int
	if err := a.db.QueryRow(r.Context(), `SELECT count(*)::int FROM feedback_messages WHERE status='new'`).Scan(&newCount); err != nil {
		newCount = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": items, "next_cursor": next, "unread": newCount, "updated_at": time.Now().UTC()})
}

func (a *API) setFeedbackStatus(target string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
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
		tag, err := tx.Exec(r.Context(), `UPDATE feedback_messages SET status=$2 WHERE id=$1
			AND (($2='read' AND status='new') OR ($2='archived' AND status<>'archived'))`, id, target)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if tag.RowsAffected() == 0 {
			writeError(w, apiError{Status: 409, Code: "feedback_state_unchanged"})
			return
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.feedback."+target, "feedback_message", id, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": target})
	}
}

type feedbackReplyRequest struct {
	Body string `json:"body"`
	mailOptions
}

func (a *API) replyFeedback(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input feedbackReplyRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.mailOptions.validate() {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	body := strings.TrimSpace(input.Body)
	if len([]rune(body)) < 2 || len([]rune(body)) > 4000 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	admin := currentSession(r)
	a.executeAdminMail(w, r, "admin.feedback.reply", "feedback_message", id, body+input.mailOptions.fingerprint(), func(tx pgx.Tx) (adminMailIntent, error) {
		var contact, subject, state, originalBody string
		var created time.Time
		if err := tx.QueryRow(r.Context(), `SELECT contact_email,subject,status,body,created_at FROM feedback_messages WHERE id=$1 FOR UPDATE`, id).Scan(&contact, &subject, &state, &originalBody, &created); err != nil {
			return adminMailIntent{}, adminMailReadError(err, "feedback_not_found")
		}
		if contact == "" {
			return adminMailIntent{}, apiError{Status: 409, Code: "feedback_no_contact"}
		}
		if state == "archived" {
			return adminMailIntent{}, apiError{Status: 409, Code: "feedback_archived"}
		}
		title := feedbackSubject(subject)
		message := input.mailOptions.message(title, body)
		message.OriginalSubject = subject
		if message.OriginalSubject == "" {
			message.OriginalSubject = "（无主题）"
		}
		message.OriginalDate = originalDate(created)
		if input.IncludeOriginal {
			message.OriginalBody = originalExcerpt(originalBody)
		}

		return adminMailIntent{Recipient: contact, Subject: title, Body: body, Purpose: "feedback_reply", FeedbackID: id, Message: message, ApplyResult: func(ctx context.Context, tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE feedback_messages SET status=CASE WHEN status='archived' THEN 'archived' ELSE 'replied' END,reply_body=$2,replied_at=now(),replied_by=$3 WHERE id=$1`, id, body, admin.AdminID)
			return err
		}}, nil
	})
}

// ---- 邮件发送 ----

type sendMailRequest struct {
	mailOptions
	To      string `json:"to"`
	Subject string `json:"subject"`
	Body    string `json:"body"`
}

func (a *API) sendMail(w http.ResponseWriter, r *http.Request) {
	var input sendMailRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.mailOptions.validate() {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	parsed, err := identity.ParseEmail(input.To)
	if err != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_recipient"})
		return
	}
	subject, body := strings.TrimSpace(input.Subject), strings.TrimSpace(input.Body)
	if len([]rune(subject)) < 1 || len([]rune(subject)) > 200 || strings.ContainsAny(subject, "\r\n") || len([]rune(body)) < 1 || len([]rune(body)) > 8000 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if !strings.HasPrefix(subject, "[FlowRiver]") {
		subject = "[FlowRiver] " + subject
	}
	if len([]rune(subject)) > 200 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	a.executeAdminMail(w, r, "admin.mail.send", "outbound_email", "", parsed.Canonical+"\n"+subject+"\n"+body+input.mailOptions.fingerprint(), func(pgx.Tx) (adminMailIntent, error) {
		return adminMailIntent{Recipient: parsed.Canonical, Subject: subject, Body: body, Purpose: "manual", Message: input.mailOptions.message(subject, body)}, nil
	})
}

func (a *API) listOutbound(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	status := r.URL.Query().Get("status")
	if len([]rune(query)) > 200 || (status != "" && status != "queued" && status != "sent" && status != "failed") {
		writeError(w, apiError{Status: 400, Code: "invalid_query"})
		return
	}
	var after time.Time
	var afterID string
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		parsed, ok := decodeDeviceCursor(raw)
		if !ok {
			writeError(w, apiError{Status: 400, Code: "invalid_cursor"})
			return
		}
		after, afterID = parsed.Timestamp, parsed.ID
	}
	rows, err := a.db.Query(r.Context(), `SELECT o.id::text,o.recipient,o.subject,o.purpose,o.status,o.error_code,o.sent_at,o.created_at,COALESCE(u.username,'')
		FROM admin_outbound_email o LEFT JOIN admin_accounts u ON u.id=o.created_by
		WHERE ($1='' OR o.status=$1)
 AND ($2::timestamptz IS NULL OR (o.created_at,o.id)<($2::timestamptz,$3::uuid))
 AND ($5='' OR o.recipient ILIKE '%'||$5||'%' OR o.subject ILIKE '%'||$5||'%' OR o.body ILIKE '%'||$5||'%' OR (o.formatted_payload#>>'{view,reference}') ILIKE '%'||$5||'%')
 ORDER BY o.created_at DESC,o.id DESC LIMIT $4`, status, nullableTimestamp(after), nullIfEmpty(afterID), limit+1, escapeLike(query))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID        string     `json:"id"`
		Recipient string     `json:"recipient"`
		Subject   string     `json:"subject"`
		Purpose   string     `json:"purpose"`
		Status    string     `json:"status"`
		ErrorCode string     `json:"error_code"`
		SentAt    *time.Time `json:"sent_at"`
		CreatedAt time.Time  `json:"created_at"`
		CreatedBy string     `json:"created_by"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Recipient, &it.Subject, &it.Purpose, &it.Status, &it.ErrorCode, &it.SentAt, &it.CreatedAt, &it.CreatedBy); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	next := ""
	if len(items) > limit {
		last := items[limit-1]
		next = encodeDeviceCursor(last.CreatedAt, last.ID)
		items = items[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": items, "next_cursor": next, "updated_at": time.Now().UTC()})
}
