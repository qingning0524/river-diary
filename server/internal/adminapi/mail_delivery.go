package adminapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"flowriver/server/internal/mailer"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

type adminMailIntent struct {
	Recipient, Subject, Body, Purpose, FeedbackID string
	Message                                       mailer.Message
	ApplyResult                                   func(context.Context, pgx.Tx) error
}
type adminMailResult struct {
	ID        string `json:"id"`
	MailID    string `json:"mail_id"`
	Status    string `json:"status"`
	Recipient string `json:"recipient"`
	Subject   string `json:"subject"`
}

func writeAdminMailResult(w http.ResponseWriter, result adminMailResult) {
	switch result.Status {
	case "queued":
		writeJSON(w, http.StatusAccepted, result)
	case "failed":
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": map[string]string{"code": "mail_delivery_failed"}, "mail_id": result.MailID})
	default:
		writeJSON(w, http.StatusOK, result)
	}
}

// Commit delivery intent before any SMTP side effect. A cached in-flight or
// unconfirmed result is replayed without sending again, including after restart.
func (a *API) executeAdminMail(w http.ResponseWriter, r *http.Request, action, targetKind, targetID, fingerprint string, prepare func(pgx.Tx) (adminMailIntent, error)) {
	sender, ok := a.mailSender.(mailer.FullSender)
	if !ok {
		writeError(w, apiError{Status: 503, Code: "mail_not_supported"})
		return
	}
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if len(key) < 8 || len(key) > 128 || strings.ContainsAny(key, "\r\n\x00") {
		writeError(w, apiError{Status: 400, Code: "idempotency_key_required"})
		return
	}
	s := currentSession(r)
	keyMAC := secure.Digest(key)
	requestMAC := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-mail-request-v1", action, targetID, fingerprint)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `INSERT INTO admin_action_requests(admin_id,key_mac,request_mac,expires_at)
 VALUES($1,$2,$3,now()+interval '24 hours') ON CONFLICT(admin_id,key_mac) DO NOTHING`, s.AdminID, keyMAC, requestMAC)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		var priorMAC, prior []byte
		if err = tx.QueryRow(r.Context(), `SELECT request_mac,response_body FROM admin_action_requests WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC).Scan(&priorMAC, &prior); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if !secure.EqualMAC(priorMAC, requestMAC) {
			writeError(w, apiError{Status: 409, Code: "idempotency_key_reused"})
			return
		}
		var result adminMailResult
		if json.Unmarshal(prior, &result) != nil || result.MailID == "" {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeAdminMailResult(w, result)
		return
	}
	intent, err := prepare(tx)
	if err != nil {
		writeError(w, err)
		return
	}
	result := adminMailResult{ID: targetID, Status: "queued", Recipient: intent.Recipient, Subject: intent.Subject}
	if err = tx.QueryRow(r.Context(), `INSERT INTO admin_outbound_email(recipient,subject,body,purpose,feedback_id,status,created_by)
 VALUES($1,$2,$3,$4,NULLIF($5,'')::uuid,'queued',$6) RETURNING id::text`, intent.Recipient, intent.Subject, intent.Body, intent.Purpose, intent.FeedbackID, s.AdminID).Scan(&result.MailID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if result.ID == "" {
		result.ID = result.MailID
	}
	message := intent.Message
	if message.Subject == "" {
		message = mailer.Message{Template: "support_reply", Subject: intent.Subject, Body: intent.Body}
	}
	message.DeliveryID = result.MailID
	message.Reference = mailer.MessageReference(result.ID)
	message.SupportEmail = a.cfg.SMTPFrom
	formatted, renderErr := mailer.Render(message)
	if renderErr != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	message = formatted.Message
	encoded, _ := json.Marshal(formatted)
	if _, err = tx.Exec(r.Context(), `UPDATE admin_outbound_email SET formatted_payload=$2 WHERE id=$1`, result.MailID, encoded); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	pending, _ := json.Marshal(result)
	if _, err = tx.Exec(r.Context(), `UPDATE admin_action_requests SET response_body=$3 WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC, pending); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err = a.auditTx(r.Context(), tx, s.AdminID, action+".attempt", targetKind, result.ID, "mail_prepared", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err = tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err = http.NewResponseController(w).SetWriteDeadline(time.Now().Add(30 * time.Second)); err != nil && !errors.Is(err, http.ErrNotSupported) {
		writeAdminMailResult(w, result)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	var sendErr error
	if structured, ok := sender.(mailer.StructuredSender); ok {
		sendErr = structured.SendMessage(ctx, intent.Recipient, message)
	} else {
		sendErr = sender.SendMail(ctx, intent.Recipient, intent.Subject, formatted.Text)
	}
	cancel()
	// Recording must finish even if the browser disconnected after SMTP accepted.
	recordCtx, recordCancel := context.WithTimeout(context.WithoutCancel(r.Context()), 5*time.Second)
	defer recordCancel()
	finish, err := a.db.Begin(recordCtx)
	if err != nil {
		writeAdminMailResult(w, result)
		return
	}
	defer finish.Rollback(recordCtx)
	final := result
	final.Status = "sent"
	auditResult, errorCode := "success", ""
	if sendErr != nil {
		final.Status = "failed"
		auditResult, errorCode = "failure", "delivery_failed"
	}
	if errors.Is(sendErr, mailer.ErrDeliveryUnconfirmed) {
		final.Status = "queued"
		errorCode = "delivery_unconfirmed"
	}
	_, err = finish.Exec(recordCtx, `UPDATE admin_outbound_email SET status=$2,error_code=$3,sent_at=CASE WHEN $2='sent' THEN now() ELSE NULL END WHERE id=$1`, result.MailID, final.Status, errorCode)
	if err == nil && sendErr == nil && intent.ApplyResult != nil {
		err = intent.ApplyResult(recordCtx, finish)
	}
	if err == nil {
		err = a.auditTx(recordCtx, finish, s.AdminID, action+".result", targetKind, result.ID, errorCode, auditResult, s.IPMac)
	}
	confirmed, _ := json.Marshal(final)
	if err == nil {
		_, err = finish.Exec(recordCtx, `UPDATE admin_action_requests SET response_body=$3 WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC, confirmed)
	}
	if err == nil {
		err = finish.Commit(recordCtx)
	}
	if err != nil {
		a.log.Error("administrator mail result recording incomplete", "mail_id", result.MailID)
		writeAdminMailResult(w, result)
		return
	}
	writeAdminMailResult(w, final)
}

func adminMailReadError(err error, notFound string) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return apiError{Status: 404, Code: notFound}
	}
	return apiError{Status: 503, Code: "temporarily_unavailable"}
}
