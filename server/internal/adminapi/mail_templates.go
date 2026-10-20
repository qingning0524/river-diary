package adminapi

import (
	"encoding/json"
	"flowriver/server/internal/identity"
	"flowriver/server/internal/mailer"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type mailOptions struct {
	Template        string `json:"template"`
	RecipientName   string `json:"recipient_name"`
	IncludeOriginal bool   `json:"include_original"`
}

func (o *mailOptions) validate() bool {
	if o.Template == "" {
		o.Template = "support_reply"
	}
	o.RecipientName = strings.TrimSpace(o.RecipientName)
	return mailer.ValidTemplate(o.Template) && utf8.RuneCountInString(o.RecipientName) <= 60 && !strings.ContainsAny(o.RecipientName, "\r\n\x00")
}
func (o mailOptions) fingerprint() string { data, _ := json.Marshal(o); return string(data) }
func (o mailOptions) message(subject, body string) mailer.Message {
	return mailer.Message{Template: o.Template, RecipientName: o.RecipientName, Subject: subject, Body: body}
}
func originalExcerpt(body string) string {
	runes := []rune(body)
	if len(runes) > 1200 {
		return string(runes[:1200]) + "\n…"
	}
	return body
}
func originalDate(date time.Time) string {
	return date.In(time.FixedZone("UTC+8", 8*3600)).Format("2006年01月02日 15:04")
}
func feedbackSubject(subject string) string {
	if subject == "" {
		return "回复:您的 FlowRiver 反馈"
	}
	value := []rune("回复:" + subject)
	if len(value) > 200 {
		return string(value[:199]) + "…"
	}
	return string(value)
}
func inboundSubject(subject string) string {
	if !strings.HasPrefix(strings.ToLower(subject), "re:") {
		subject = "Re: " + subject
	}
	if !strings.Contains(subject, "FlowRiver") {
		subject += "（河流日记）"
	}
	runes := []rune(subject)
	if len(runes) > 200 {
		subject = string(runes[:199]) + "…"
	}
	return subject
}

type previewMailRequest struct {
	Source   string `json:"source"`
	SourceID string `json:"source_id"`
	To       string `json:"to"`
	Subject  string `json:"subject"`
	Body     string `json:"body"`
	mailOptions
}

func (a *API) previewMail(w http.ResponseWriter, r *http.Request) {
	var input previewMailRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.mailOptions.validate() || utf8.RuneCountInString(input.Body) > 8000 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	message := input.mailOptions.message(input.Subject, input.Body)
	to := input.To
	switch input.Source {
	case "manual":
		parsed, err := identity.ParseEmail(to)
		if err != nil {
			writeError(w, apiError{Status: 400, Code: "invalid_recipient"})
			return
		}
		to = parsed.Canonical
		message.Subject = strings.TrimSpace(message.Subject)
		if !strings.HasPrefix(message.Subject, "[FlowRiver]") {
			message.Subject = "[FlowRiver] " + message.Subject
		}
	case "feedback":
		if !isUUID(input.SourceID) {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		var subject, body string
		var created time.Time
		if err := a.db.QueryRow(r.Context(), `SELECT contact_email,subject,body,created_at FROM feedback_messages WHERE id=$1`, input.SourceID).Scan(&to, &subject, &body, &created); err != nil {
			writeError(w, adminMailReadError(err, "feedback_not_found"))
			return
		}
		if to == "" {
			writeError(w, apiError{Status: 409, Code: "feedback_no_contact"})
			return
		}
		message.Subject = feedbackSubject(subject)
		message.OriginalSubject = subject
		message.OriginalDate = originalDate(created)
		if input.IncludeOriginal {
			message.OriginalBody = originalExcerpt(body)
		}
	case "inbound":
		if !isUUID(input.SourceID) {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		var subject, body, name string
		var created time.Time
		if err := a.db.QueryRow(r.Context(), `SELECT from_addr,from_name,subject,text_body,message_id,created_at FROM inbound_mail WHERE id=$1`, input.SourceID).Scan(&to, &name, &subject, &body, &message.InReplyTo, &created); err != nil {
			writeError(w, adminMailReadError(err, "mail_not_found"))
			return
		}
		if message.RecipientName == "" {
			message.RecipientName = safeRecipientName(name)
		}
		if to == "" {
			writeError(w, apiError{Status: 409, Code: "mail_no_sender"})
			return
		}
		message.Subject = inboundSubject(subject)
		message.OriginalSubject = subject
		message.OriginalDate = originalDate(created)
		if input.IncludeOriginal {
			message.OriginalBody = originalExcerpt(body)
		}
	default:
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	message.Reference = "FR-发送后生成"
	message.SupportEmail = a.cfg.SMTPFrom
	formatted, err := mailer.Render(message)
	if err != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	writeJSON(w, 200, map[string]any{"to": to, "subject": message.Subject, "formatted": formatted, "threaded": mailer.ValidMessageID(message.InReplyTo)})
}

func (a *API) outboundDetail(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var to, subject, body, status, purpose, code, operator string
	var formatted json.RawMessage
	var created time.Time
	var sent *time.Time
	err := a.db.QueryRow(r.Context(), `SELECT o.recipient,o.subject,o.body,o.status,o.purpose,o.error_code,o.formatted_payload,o.created_at,o.sent_at,COALESCE(a.username,'') FROM admin_outbound_email o LEFT JOIN admin_accounts a ON a.id=o.created_by WHERE o.id=$1`, id).Scan(&to, &subject, &body, &status, &purpose, &code, &formatted, &created, &sent, &operator)
	if err != nil {
		writeError(w, adminMailReadError(err, "mail_not_found"))
		return
	}
	writeJSON(w, 200, map[string]any{"id": id, "recipient": to, "subject": subject, "body": body, "status": status, "purpose": purpose, "error_code": code, "formatted": formatted, "legacy": string(formatted) == "{}", "created_at": created, "sent_at": sent, "created_by": operator})
}

func safeRecipientName(value string) string {
	runes := []rune(strings.Join(strings.Fields(value), " "))
	if len(runes) > 60 {
		runes = runes[:60]
	}
	return string(runes)
}
