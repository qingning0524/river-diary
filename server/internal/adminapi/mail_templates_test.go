package adminapi

import (
	"context"
	"encoding/json"
	"flowriver/server/internal/mailer"
	"net/http"
	"strings"
	"testing"
)

type structuredAdminCapture struct {
	recordingAdminSender
	message mailer.Message
}

func (s *structuredAdminCapture) SendMessage(_ context.Context, _ string, msg mailer.Message) error {
	s.sent.Add(1)
	s.message = msg
	return nil
}

func TestPreviewRequiresSessionAndCSRFButDoesNotRequireSendMFA(t *testing.T) {
	f := testAdminAPI(t)
	if _, err := f.db.Exec(context.Background(), `UPDATE admin_sessions SET reauthenticated_until=NULL`); err != nil {
		t.Fatal(err)
	}
	payload := `{"source":"manual","to":"qa@example.test","subject":"产品更新","body":"## 更新内容\n\n- 优化导航\n- 修复问题","template":"product_update","recipient_name":"林女士"}`
	w := f.request(http.MethodPost, "/mailbox/preview", strings.NewReader(payload), "application/json")
	if w.Code != 200 || !strings.Contains(w.Body.String(), "河流日记团队") {
		t.Fatalf("read-only preview failed: %d %s", w.Code, w.Body.String())
	}
	var count int
	if err := f.db.QueryRow(context.Background(), `SELECT count(*) FROM admin_outbound_email`).Scan(&count); err != nil || count != 0 {
		t.Fatal("preview triggered a delivery")
	}
	w = f.request(http.MethodPost, "/announcements", strings.NewReader(`{}`), "application/json")
	if w.Code != 403 {
		t.Fatal("preview exception weakened write MFA")
	}
	bad := f
	bad.csrf = "invalid"
	w = bad.request(http.MethodPost, "/mailbox/preview", strings.NewReader(payload), "application/json")
	if w.Code != 403 {
		t.Fatal("preview bypassed CSRF")
	}
	bad = f
	bad.token = "invalid"
	w = bad.request(http.MethodPost, "/mailbox/preview", strings.NewReader(payload), "application/json")
	if w.Code != 401 {
		t.Fatal("preview bypassed authentication")
	}
}

func TestBrandedReplyPersistsExactContentAndThreadContext(t *testing.T) {
	f := testAdminAPI(t)
	capture := &structuredAdminCapture{}
	f.api.mailSender = capture
	var id string
	if err := f.db.QueryRow(context.Background(), `INSERT INTO inbound_mail(message_id,from_addr,from_name,subject,text_body) VALUES('<original@example.test>','qa@example.test','林女士','导航问题','<script>原始内容</script>') RETURNING id::text`).Scan(&id); err != nil {
		t.Fatal(err)
	}
	payload := `{"body":"感谢您的反馈。\n\n- 导航可在顶部访问\n- 请补充版本信息","template":"support_reply","include_original":true}`
	w := adminMailRequest(f, "/mailbox/inbound/"+id+"/reply", payload, "branded-reply-123456")
	if w.Code != 200 {
		t.Fatal(w.Body.String())
	}
	var result adminMailResult
	if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
		t.Fatal(err)
	}
	if capture.message.InReplyTo != "<original@example.test>" || capture.message.RecipientName != "林女士" || capture.message.DeliveryID != result.MailID {
		t.Fatal("reply lost threading or identity metadata")
	}
	detail := f.request(http.MethodGet, "/mailbox/outbound/"+result.MailID, nil, "")
	var data struct {
		Formatted mailer.FormattedMessage `json:"formatted"`
		Legacy    bool                    `json:"legacy"`
	}
	if detail.Code != 200 || json.Unmarshal(detail.Body.Bytes(), &data) != nil || data.Legacy {
		t.Fatal("prepared mail was not retained in history")
	}
	if data.Formatted.Message.Subject != capture.message.Subject || data.Formatted.Message.Reference != capture.message.Reference || !data.Formatted.Message.Date.Equal(capture.message.Date) {
		t.Fatal("history and delivery differ")
	}
	if strings.Contains(data.Formatted.HTML, "<script>") || !strings.Contains(data.Formatted.HTML, "河流日记支持团队") {
		t.Fatal("mail quote injected markup or brand missing")
	}
}

func TestMailSearchAndOutboundPaginationIncludeFormattedReferences(t *testing.T) {
	f := testAdminAPI(t)
	var admin string
	if err := f.db.QueryRow(context.Background(), `SELECT id::text FROM admin_accounts LIMIT 1`).Scan(&admin); err != nil {
		t.Fatal(err)
	}
	if _, err := f.db.Exec(context.Background(), `INSERT INTO admin_outbound_email(recipient,subject,body,status,created_by,formatted_payload) SELECT 'qa@example.test','mail '||i,'body','sent',$1::uuid,jsonb_build_object('view',jsonb_build_object('reference','FR-'||i)) FROM generate_series(1,32)i`, admin); err != nil {
		t.Fatal(err)
	}
	w := f.request(http.MethodGet, "/mailbox/outbound?limit=25", nil, "")
	var first struct {
		Messages []json.RawMessage `json:"messages"`
		Cursor   string            `json:"next_cursor"`
	}
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &first) != nil || len(first.Messages) != 25 || first.Cursor == "" {
		t.Fatal("outbound first page incomplete")
	}
	w = f.request(http.MethodGet, "/mailbox/outbound?q=FR-32", nil, "")
	if w.Code != 200 || json.Unmarshal(w.Body.Bytes(), &first) != nil || len(first.Messages) != 1 {
		t.Fatal("reference search failed")
	}
}
