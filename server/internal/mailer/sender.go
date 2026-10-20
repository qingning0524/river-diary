package mailer

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net"
	"net/mail"
	"net/smtp"
	"net/textproto"
	"regexp"
	"strings"
	"time"
)

type Sender interface {
	SendOTP(context.Context, string, string) error
}
type FullSender interface {
	Sender
	SendMail(context.Context, string, string, string) error
}
type StructuredSender interface {
	FullSender
	SendMessage(context.Context, string, Message) error
}

var ErrDeliveryUnconfirmed = errors.New("SMTP delivery acknowledgement unavailable")

type ConsoleSender struct{ Logf func(string, ...any) }

func (s ConsoleSender) SendOTP(_ context.Context, to, code string) error {
	if s.Logf != nil {
		s.Logf("development OTP delivery", "to", to, "code", code)
	}
	return nil
}
func (s ConsoleSender) SendMail(ctx context.Context, to, subject, body string) error {
	return s.SendMessage(ctx, to, Message{Subject: subject, Body: body, Template: "support_reply"})
}
func (s ConsoleSender) SendMessage(_ context.Context, to string, msg Message) error {
	if s.Logf != nil {
		s.Logf("development mail delivery", "to", to, "template", msg.Template, "body_bytes", len(msg.Body))
	}
	return nil
}

type SMTPSender struct{ Address, TLSMode, Username, Password, From string }

func (s SMTPSender) SendOTP(ctx context.Context, to, code string) error {
	return s.SendMessage(ctx, to, Message{Template: "verification", Subject: "河流日记 · 邮箱安全验证码", Body: "这是用于完成邮箱安全验证的验证码。", VerificationCode: code})
}
func (s SMTPSender) SendMail(ctx context.Context, to, subject, body string) error {
	return s.SendMessage(ctx, to, Message{Template: "support_reply", Subject: subject, Body: body})
}
func (s SMTPSender) SendMessage(ctx context.Context, to string, msg Message) error {
	data, err := BuildMessage(s.From, to, msg)
	if err != nil {
		return err
	}
	return s.send(ctx, to, data)
}

var messageIDPattern = regexp.MustCompile("^<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~:@-]+>$")
var deliveryIDPattern = regexp.MustCompile(`^[A-Za-z0-9-]{8,80}$`)

func ValidMessageID(value string) bool {
	return len(value) <= 250 && messageIDPattern.MatchString(value) && strings.Count(value, "@") >= 1
}

func BuildMessage(from, to string, msg Message) ([]byte, error) {
	sender, err := mail.ParseAddress(from)
	if err != nil || sender.Address != from {
		return nil, fmt.Errorf("invalid SMTP sender address")
	}
	recipient, err := mail.ParseAddress(to)
	if err != nil || recipient.Address != to {
		return nil, fmt.Errorf("invalid recipient address")
	}
	if msg.SupportEmail == "" {
		msg.SupportEmail = from
	}
	if msg.DeliveryID == "" {
		entropy := make([]byte, 16)
		if _, err = rand.Read(entropy); err != nil {
			return nil, err
		}
		msg.DeliveryID = hex.EncodeToString(entropy)
	}
	if !deliveryIDPattern.MatchString(msg.DeliveryID) {
		return nil, fmt.Errorf("invalid delivery identifier")
	}
	if msg.Reference == "" && msg.Template != "verification" {
		msg.Reference = MessageReference(msg.DeliveryID)
	}
	rendered, err := Render(msg)
	if err != nil {
		return nil, err
	}
	msg = rendered.Message
	var content bytes.Buffer
	writer := multipart.NewWriter(&content)
	for _, part := range []struct{ kind, body string }{{"text/plain", rendered.Text}, {"text/html", rendered.HTML}} {
		header := textproto.MIMEHeader{"Content-Type": {part.kind + "; charset=UTF-8"}, "Content-Transfer-Encoding": {"quoted-printable"}}
		stream, err := writer.CreatePart(header)
		if err != nil {
			return nil, err
		}
		encoded := quotedprintable.NewWriter(stream)
		if _, err = io.WriteString(encoded, part.body); err != nil {
			return nil, err
		}
		if err = encoded.Close(); err != nil {
			return nil, err
		}
	}
	if err = writer.Close(); err != nil {
		return nil, err
	}
	var result bytes.Buffer
	fmt.Fprintf(&result, "From: %s\r\nTo: %s\r\nReply-To: %s\r\nDate: %s\r\nMessage-ID: <flowriver.%s@%s>\r\nSubject: %s\r\nMIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=%q\r\n", (&mail.Address{Name: "河流日记 River Diary", Address: from}).String(), (&mail.Address{Name: msg.RecipientName, Address: to}).String(), msg.SupportEmail, msg.Date.UTC().Format(time.RFC1123Z), msg.DeliveryID, from[strings.LastIndexByte(from, '@')+1:], mime.QEncoding.Encode("utf-8", msg.Subject), writer.Boundary())
	if ValidMessageID(msg.InReplyTo) {
		fmt.Fprintf(&result, "In-Reply-To: %s\r\nReferences: %s\r\n", msg.InReplyTo, msg.InReplyTo)
	}
	result.WriteString("\r\n")
	result.Write(content.Bytes())
	return result.Bytes(), nil
}

func (s SMTPSender) send(ctx context.Context, to string, data []byte) error {
	host, _, err := net.SplitHostPort(s.Address)
	if err != nil {
		return fmt.Errorf("invalid SMTP address")
	}
	conn, err := (&net.Dialer{Timeout: 8 * time.Second}).DialContext(ctx, "tcp", s.Address)
	if err != nil {
		return fmt.Errorf("connect SMTP: %w", err)
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	deadline := time.Now().Add(15 * time.Second)
	if end, ok := ctx.Deadline(); ok && end.Before(deadline) {
		deadline = end
	}
	conn.SetDeadline(deadline)
	var client *smtp.Client
	if s.TLSMode == "implicit" {
		tlsConn := tls.Client(conn, &tls.Config{ServerName: host, MinVersion: tls.VersionTLS12})
		if err = tlsConn.HandshakeContext(ctx); err != nil {
			return fmt.Errorf("SMTP TLS handshake: %w", err)
		}
		client, err = smtp.NewClient(tlsConn, host)
	} else {
		client, err = smtp.NewClient(conn, host)
	}
	if err != nil {
		return fmt.Errorf("start SMTP session: %w", err)
	}
	defer client.Close()
	if s.TLSMode == "starttls" {
		if ok, _ := client.Extension("STARTTLS"); !ok {
			return fmt.Errorf("SMTP server does not offer STARTTLS")
		}
		if err = client.StartTLS(&tls.Config{ServerName: host, MinVersion: tls.VersionTLS12}); err != nil {
			return fmt.Errorf("start SMTP TLS: %w", err)
		}
	}
	if s.Username != "" {
		if err = client.Auth(smtp.PlainAuth("", s.Username, s.Password, host)); err != nil {
			return fmt.Errorf("SMTP authentication failed: %w", err)
		}
	}
	if err = client.Mail(s.From); err != nil {
		return fmt.Errorf("SMTP MAIL FROM failed: %w", err)
	}
	if err = client.Rcpt(to); err != nil {
		return fmt.Errorf("SMTP RCPT TO failed: %w", err)
	}
	stream, err := client.Data()
	if err != nil {
		return fmt.Errorf("SMTP DATA failed: %w", err)
	}
	// Do not close the DATA writer after a partial write: that could publish a truncated message.
	if _, err = stream.Write(data); err != nil {
		return fmt.Errorf("write SMTP message: %w", err)
	}
	if err = stream.Close(); err != nil {
		var rejection *textproto.Error
		if errors.As(err, &rejection) {
			return fmt.Errorf("SMTP message rejected: %w", err)
		}
		return ErrDeliveryUnconfirmed
	}
	// DATA's success response is the acceptance boundary; QUIT failure is not a send failure.
	_ = client.Quit()
	return nil
}
