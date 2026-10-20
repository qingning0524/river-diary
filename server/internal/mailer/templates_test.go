package mailer

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/mail"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

func TestBrandedContentEscapesMarkupAndPreservesPlainFallback(t *testing.T) {
	msg := Message{Template: "support_reply", Subject: "关于问题的回复", RecipientName: "林女士", Body: "## 处理进展\n\n- 已修复导航\n- <script>alert(1)</script>\n\n下一段内容", Reference: "FR-123456789ABC", OriginalSubject: "<img src=x onerror=alert(1)>", Date: time.Date(2026, 10, 8, 23, 30, 0, 0, time.UTC)}
	rendered, err := Render(msg)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rendered.HTML, "<script>") || strings.Contains(rendered.HTML, "<img src=x") {
		t.Fatal("untrusted body or subject injected markup")
	}
	for _, text := range []string{"河流日记支持团队", "FR-123456789ABC", "2026年10月09日 07:30", "&lt;script&gt;"} {
		if !strings.Contains(rendered.HTML, text) {
			t.Errorf("HTML missing %q", text)
		}
	}
	if !strings.Contains(rendered.Text, "下一段内容") || !strings.Contains(rendered.Text, "林女士，您好") {
		t.Fatal("plain alternative lost content")
	}
	if len(rendered.View.Blocks) != 3 || rendered.View.Blocks[1].Kind != "list" {
		t.Fatal("paragraph and list structure lost")
	}
}

func captureSMTPMode(t *testing.T, mode string) (SMTPSender, <-chan []byte) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	messages := make(chan []byte, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetDeadline(time.Now().Add(5 * time.Second))
		r := textproto.NewReader(bufio.NewReader(conn))
		w := textproto.NewWriter(bufio.NewWriter(conn))
		w.PrintfLine("220 test SMTP")
		for {
			line, err := r.ReadLine()
			if err != nil {
				return
			}
			switch {
			case strings.HasPrefix(line, "EHLO"), strings.HasPrefix(line, "HELO"):
				w.PrintfLine("250 fixture")
			case strings.HasPrefix(line, "MAIL"), strings.HasPrefix(line, "RCPT"):
				w.PrintfLine("250 OK")
			case line == "DATA":
				w.PrintfLine("354 continue")
				data, err := r.ReadDotBytes()
				if err != nil {
					return
				}
				messages <- data
				if mode == "noack" {
					return
				}
				w.PrintfLine("250 accepted")
				if mode == "quit" {
					return
				}
			case line == "QUIT":
				w.PrintfLine("221 bye")
				return
			default:
				w.PrintfLine("250 OK")
			}
		}
	}()
	return SMTPSender{Address: ln.Addr().String(), TLSMode: "loopback", From: "account@mail.flowriver.xyz"}, messages
}

func captureSMTP(t *testing.T, breakAfterAcceptance bool) (SMTPSender, <-chan []byte) {
	mode := "normal"
	if breakAfterAcceptance {
		mode = "quit"
	}
	return captureSMTPMode(t, mode)
}

func TestSMTPAdministrativeMailHasUnicodeSubjectAndBothAlternatives(t *testing.T) {
	sender, captured := captureSMTP(t, false)
	subject := strings.Repeat("中", 100)
	if err := sender.SendMail(context.Background(), "recipient@example.test", subject, "测试正文\n\n- 第一点\n- 第二点"); err != nil {
		t.Fatal(err)
	}
	data := <-captured
	message, err := mail.ReadMessage(strings.NewReader(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
	if err != nil || decoded != subject {
		t.Fatal("UTF-8 subject did not round-trip")
	}
	media, params, err := mime.ParseMediaType(message.Header.Get("Content-Type"))
	if err != nil || media != "multipart/alternative" {
		t.Fatal("mail does not contain HTML and plain alternatives")
	}
	reader := multipart.NewReader(message.Body, params["boundary"])
	count := 0
	for {
		part, err := reader.NextRawPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(quotedprintable.NewReader(part))
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(body), "测试正文") {
			t.Fatal("alternative lost body")
		}
		count++
	}
	if count != 2 || message.Header.Get("Reply-To") == "" || message.Header.Get("Message-ID") == "" {
		t.Fatal("message headers or alternatives incomplete")
	}
}

func TestSMTPAcceptanceDoesNotBecomeFailureWhenQuitDisconnects(t *testing.T) {
	sender, _ := captureSMTP(t, true)
	if err := sender.SendMail(context.Background(), "recipient@example.test", "accepted", "one delivery"); err != nil {
		t.Fatalf("DATA already accepted; QUIT must not trigger retry: %v", err)
	}
}

func TestSMTPMissingDataAcknowledgementIsExplicitlyUnconfirmed(t *testing.T) {
	sender, _ := captureSMTPMode(t, "noack")
	if err := sender.SendMail(context.Background(), "recipient@example.test", "test", "test body"); !errors.Is(err, ErrDeliveryUnconfirmed) {
		t.Fatalf("missing acknowledgement was not classified as unknown: %v", err)
	}
}
func TestBrandedMessageThreadHeadersAndVerification(t *testing.T) {
	data, err := BuildMessage("account@mail.flowriver.xyz", "recipient@example.test", Message{Subject: "回复邮件", Body: "测试正文", DeliveryID: "12345678-1234-1234-1234-123456789abc", InReplyTo: "<original@example.test>"})
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := mail.ReadMessage(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Header.Get("In-Reply-To") != "<original@example.test>" || parsed.Header.Get("References") == "" {
		t.Fatal("message lost reply threading")
	}
	data, err = BuildMessage("account@mail.flowriver.xyz", "recipient@example.test", Message{Subject: "安全验证码", Template: "verification", Body: "验证您的邮箱", VerificationCode: "12345678"})
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(data, []byte("12345678")) {
		t.Fatal("verification message lost the code")
	}
	if ValidMessageID("<original@example.test>\r\nBcc: another@example.test") {
		t.Fatal("reply header injection accepted")
	}
}
