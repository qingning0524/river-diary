package adminapi

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// ---- 邮件收件箱(入站) ----

func (a *API) listInbound(w http.ResponseWriter, r *http.Request) {
	limit := queryLimit(r, 25, 100)
	query := strings.TrimSpace(r.URL.Query().Get("q"))
	status := r.URL.Query().Get("status")
	if len([]rune(query)) > 200 || (status != "" && status != "new" && status != "read" && status != "replied") {
		writeError(w, apiError{Status: 400, Code: "invalid_query"})
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
	rows, err := a.db.Query(r.Context(), `SELECT id::text,from_addr,from_name,to_addr,subject,text_body,status,replied_at,created_at
		FROM inbound_mail
		WHERE ($1::timestamptz IS NULL OR (created_at,id)<($1::timestamptz,$2::uuid))
 AND ($4='' OR status=$4) AND ($5='' OR from_addr ILIKE '%'||$5||'%' OR from_name ILIKE '%'||$5||'%' OR subject ILIKE '%'||$5||'%' OR text_body ILIKE '%'||$5||'%')
		ORDER BY created_at DESC,id DESC LIMIT $3`,
		nullableTimestamp(after), nullIfEmpty(afterID), limit+1, status, escapeLike(query))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID        string     `json:"id"`
		FromAddr  string     `json:"from_addr"`
		FromName  string     `json:"from_name"`
		ToAddr    string     `json:"to_addr"`
		Subject   string     `json:"subject"`
		TextBody  string     `json:"text_body"`
		Status    string     `json:"status"`
		RepliedAt *time.Time `json:"replied_at"`
		CreatedAt time.Time  `json:"created_at"`
	}
	items := make([]item, 0, limit+1)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.FromAddr, &it.FromName, &it.ToAddr, &it.Subject, &it.TextBody, &it.Status, &it.RepliedAt, &it.CreatedAt); err != nil {
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
	var unread int
	if err := a.db.QueryRow(r.Context(), `SELECT count(*)::int FROM inbound_mail WHERE status='new'`).Scan(&unread); err != nil {
		unread = 0
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": items, "next_cursor": next, "unread": unread, "updated_at": time.Now().UTC()})
}

func (a *API) markInboundRead(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var state string
	err = tx.QueryRow(r.Context(), `UPDATE inbound_mail SET status=CASE WHEN status='new' THEN 'read' ELSE status END WHERE id=$1 RETURNING status`, id).Scan(&state)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, apiError{Status: 404, Code: "mail_not_found"})
			return
		}
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	s := currentSession(r)
	if err = a.auditTx(r.Context(), tx, s.AdminID, "admin.inbound.read", "inbound_mail", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": state})
}

type inboundReplyRequest struct {
	mailOptions
	Body string `json:"body"`
}

func (a *API) replyInbound(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input inboundReplyRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.mailOptions.validate() {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	body := strings.TrimSpace(input.Body)
	if len([]rune(body)) < 2 || len([]rune(body)) > 8000 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	admin := currentSession(r)
	a.executeAdminMail(w, r, "admin.inbound.reply", "inbound_mail", id, body+input.mailOptions.fingerprint(), func(tx pgx.Tx) (adminMailIntent, error) {
		var from, subject, name, originalBody, messageID string
		var created time.Time
		if err := tx.QueryRow(r.Context(), `SELECT from_addr,subject,from_name,text_body,message_id,created_at FROM inbound_mail WHERE id=$1 FOR UPDATE`, id).Scan(&from, &subject, &name, &originalBody, &messageID, &created); err != nil {
			return adminMailIntent{}, adminMailReadError(err, "mail_not_found")
		}
		if from == "" {
			return adminMailIntent{}, apiError{Status: 409, Code: "mail_no_sender"}
		}
		title := inboundSubject(subject)
		message := input.mailOptions.message(title, body)
		if message.RecipientName == "" {
			message.RecipientName = safeRecipientName(name)
		}
		message.OriginalSubject = subject
		if message.OriginalSubject == "" {
			message.OriginalSubject = "（无主题）"
		}
		message.OriginalDate = originalDate(created)
		message.InReplyTo = messageID
		if input.IncludeOriginal {
			message.OriginalBody = originalExcerpt(originalBody)
		}

		return adminMailIntent{Recipient: from, Subject: title, Body: body, Purpose: "feedback_reply", Message: message, ApplyResult: func(ctx context.Context, tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE inbound_mail SET status='replied',replied_at=now(),replied_by=$2 WHERE id=$1`, id, admin.AdminID)
			return err
		}}, nil
	})
}

func (a *API) deleteInbound(w http.ResponseWriter, r *http.Request) {
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
	tag, err := tx.Exec(r.Context(), `DELETE FROM inbound_mail WHERE id=$1`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "mail_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.inbound.delete", "inbound_mail", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "deleted"})
}
