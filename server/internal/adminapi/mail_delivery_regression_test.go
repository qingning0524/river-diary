package adminapi

import (
	"context"
	"flowriver/server/internal/mailer"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

type recordingAdminSender struct {
	sent      atomic.Int32
	afterSend func()
}

type unconfirmedAdminSender struct{ recordingAdminSender }

func (s *unconfirmedAdminSender) SendMail(context.Context, string, string, string) error {
	s.sent.Add(1)
	return mailer.ErrDeliveryUnconfirmed
}
func TestAdministrativeMailUnconfirmedSMTPIsNotAutomaticallyRetried(t *testing.T) {
	f := testAdminAPI(t)
	sender := &unconfirmedAdminSender{}
	f.api.mailSender = sender
	path, body := seedAdminMail(t, f, "manual")
	for i := 0; i < 2; i++ {
		w := adminMailRequest(f, path, body, "smtp-unconfirmed-123456")
		if w.Code != http.StatusAccepted {
			t.Fatalf("SMTP acknowledgement unknown: %d %s", w.Code, w.Body.String())
		}
	}
	if sender.sent.Load() != 1 {
		t.Fatal("unconfirmed SMTP submission was resent")
	}
	var status, code string
	if err := f.db.QueryRow(context.Background(), `SELECT status,error_code FROM admin_outbound_email`).Scan(&status, &code); err != nil || status != "queued" || code != "delivery_unconfirmed" {
		t.Fatal("unconfirmed SMTP outcome missing from history")
	}
}

func (s *recordingAdminSender) SendOTP(context.Context, string, string) error { return nil }
func (s *recordingAdminSender) SendMail(context.Context, string, string, string) error {
	s.sent.Add(1)
	if s.afterSend != nil {
		s.afterSend()
	}
	return nil
}

func adminMailRequest(f adminFixture, path, body, key string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodPost, "https://admin.test/admin-api/v1"+path, strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:12345"
	r.Header.Set("Origin", f.api.cfg.AdminOrigin)
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("X-CSRF-Token", f.csrf)
	r.Header.Set("Idempotency-Key", key)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: f.token})
	r.AddCookie(&http.Cookie{Name: csrfCookie, Value: f.csrf})
	w := httptest.NewRecorder()
	f.api.Handler().ServeHTTP(w, r)
	return w
}

func seedAdminMail(t *testing.T, f adminFixture, kind string) (string, string) {
	t.Helper()
	var id string
	switch kind {
	case "manual":
		return "/mailbox/send", `{"to":"qa@example.test","subject":"test","body":"local fixture"}`
	case "feedback":
		if err := f.db.QueryRow(context.Background(), `INSERT INTO feedback_messages(contact_email,subject,body) VALUES('qa@example.test','test','local fixture') RETURNING id::text`).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return "/mailbox/feedback/" + id + "/reply", `{"body":"local fixture reply"}`
	default:
		if err := f.db.QueryRow(context.Background(), `INSERT INTO inbound_mail(from_addr,subject,text_body) VALUES('qa@example.test','test','local fixture') RETURNING id::text`).Scan(&id); err != nil {
			t.Fatal(err)
		}
		return "/mailbox/inbound/" + id + "/reply", `{"body":"local fixture reply"}`
	}
}

func TestAdministrativeMailAuditsBeforeDelivery(t *testing.T) {
	for _, kind := range []string{"manual", "feedback", "inbound"} {
		t.Run(kind, func(t *testing.T) {
			f := testAdminAPI(t)
			s := &recordingAdminSender{}
			f.api.mailSender = s
			path, body := seedAdminMail(t, f, kind)
			if _, err := f.db.Exec(context.Background(), `ALTER TABLE admin_audit_events ADD CONSTRAINT fail_mail_audit CHECK(false)`); err != nil {
				t.Fatal(err)
			}
			w := adminMailRequest(f, path, body, "audited-request-123456")
			if w.Code != 503 || s.sent.Load() != 0 {
				t.Fatalf("unlogged mail must never leave service: status=%d sent=%d body=%s", w.Code, s.sent.Load(), w.Body.String())
			}
		})
	}
}

func TestAdministrativeMailRetryDoesNotSendTwice(t *testing.T) {
	for _, kind := range []string{"manual", "feedback", "inbound"} {
		t.Run(kind, func(t *testing.T) {
			f := testAdminAPI(t)
			s := &recordingAdminSender{}
			f.api.mailSender = s
			path, body := seedAdminMail(t, f, kind)
			for n := 0; n < 2; n++ {
				w := adminMailRequest(f, path, body, "same-mail-request-123456")
				if w.Code != 200 {
					t.Fatal(w.Body.String())
				}
			}
			if s.sent.Load() != 1 {
				t.Fatalf("response retry resent mail: %d deliveries", s.sent.Load())
			}
			var count int
			if err := f.db.QueryRow(context.Background(), `SELECT count(*) FROM admin_outbound_email`).Scan(&count); err != nil || count != 1 {
				t.Fatalf("expected one delivery history: count=%d error=%v", count, err)
			}
		})
	}
}

func TestAdministrativeMailUncertainRecordingDoesNotResend(t *testing.T) {
	f := testAdminAPI(t)
	s := &recordingAdminSender{}
	f.api.mailSender = s
	path, body := seedAdminMail(t, f, "manual")
	s.afterSend = func() {
		if _, err := f.db.Exec(context.Background(), `ALTER TABLE admin_outbound_email ADD CONSTRAINT fail_result_write CHECK(status<>'sent')`); err != nil {
			t.Error(err)
		}
	}
	for n := 0; n < 2; n++ {
		w := adminMailRequest(f, path, body, "uncertain-mail-request-123456")
		if w.Code != http.StatusAccepted {
			t.Fatalf("unconfirmed result must be explicit: %d %s", w.Code, w.Body.String())
		}
	}
	if s.sent.Load() != 1 {
		t.Fatal(fmt.Sprintf("unconfirmed delivery was repeated %d times", s.sent.Load()))
	}
}
