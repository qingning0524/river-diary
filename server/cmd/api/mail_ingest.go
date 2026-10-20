package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"mime/quotedprintable"
	"net/mail"
	"net/textproto"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgxpool"
	htmlparse "golang.org/x/net/html"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
)

// runMailIngest is the Postfix pipe entry point: it receives a full RFC 5322
// message on stdin and stores it in inbound_mail for the administrator inbox.
// Exit code 75 (EX_TEMPFAIL) asks Postfix to retry on transient failures.
func runMailIngest(ctx context.Context, _ []string) error {
	raw, readErr := io.ReadAll(io.LimitReader(os.Stdin, 4<<20))
	if readErr != nil {
		return fmt.Errorf("mail-ingest: read stdin: %w", readErr)
	}
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		if envBytes, err := os.ReadFile("/etc/flowriver/inbound.env"); err == nil {
			for _, line := range strings.Split(string(envBytes), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "DATABASE_URL=") {
					dsn = strings.TrimSpace(strings.TrimPrefix(line, "DATABASE_URL="))
				}
			}
		}
	}
	if dsn == "" {
		return tempFail(fmt.Errorf("mail-ingest: DATABASE_URL unavailable (write it to /etc/flowriver/inbound.env)"))
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return tempFail(fmt.Errorf("mail-ingest: connect database: %w", err))
	}
	defer pool.Close()

	parsed := parseInbound(raw)
	digest := sha256.Sum256(raw)
	rawStored := raw
	if len(rawStored) > 1_000_000 {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		_, _ = zw.Write(raw)
		_ = zw.Close()
		rawStored = buf.Bytes()
	}

	var lastErr error
	for attempt := 0; attempt < 3; attempt++ {
		var inserted string
		err := pool.QueryRow(ctx, `INSERT INTO inbound_mail(message_id,from_addr,from_name,to_addr,subject,text_body,raw,ingest_digest)
 VALUES($1,$2,$3,$4,$5,$6,$7,$8)
 ON CONFLICT(ingest_digest) WHERE ingest_digest IS NOT NULL DO UPDATE SET ingest_digest=EXCLUDED.ingest_digest
			RETURNING id::text`,
			parsed.MessageID, parsed.FromAddr, parsed.FromName, parsed.ToAddr, parsed.Subject, parsed.Body, rawStored, digest[:]).Scan(&inserted)
		if err == nil {
			return nil
		}
		lastErr = err
		select {
		case <-ctx.Done():
			return tempFail(fmt.Errorf("mail-ingest: %w", ctx.Err()))
		case <-time.After(600 * time.Millisecond):
		}
	}
	return tempFail(fmt.Errorf("mail-ingest: insert failed: %w", lastErr))
}

func tempFail(err error) error {
	fmt.Fprintln(os.Stderr, err.Error())
	os.Exit(75)
	return nil
}

type inboundParsed struct {
	MessageID string
	FromAddr  string
	FromName  string
	ToAddr    string
	Subject   string
	Body      string
}

func parseInbound(raw []byte) inboundParsed {
	var out inboundParsed
	msg, err := mail.ReadMessage(bytes.NewReader(raw))
	if err != nil {
		out.Body = bestEffortText(raw)
		return out
	}
	out.MessageID = strings.TrimSpace(msg.Header.Get("Message-ID"))
	if len(out.MessageID) > 500 {
		out.MessageID = out.MessageID[:500]
	}
	out.Subject = decodeMimeWords(msg.Header.Get("Subject"))
	fromHeader := decodeMimeWords(msg.Header.Get("From"))
	if addr, err := mail.ParseAddress(fromHeader); err == nil {
		out.FromAddr = addr.Address
		out.FromName = strings.TrimSpace(addr.Name)
	} else {
		out.FromName = fromHeader
	}
	out.ToAddr = decodeMimeWords(msg.Header.Get("To"))
	out.Body = messageText(textproto.MIMEHeader(msg.Header), msg.Body)
	out.Body = limitMailText(out.Body, 50000)
	out.Subject = limitMailText(out.Subject, 500)
	out.FromName = limitMailText(out.FromName, 200)
	out.FromAddr = limitMailText(out.FromAddr, 254)
	out.ToAddr = limitMailText(out.ToAddr, 254)

	return out
}

// messageText walks a message or multipart tree and returns the first
// usable text/plain part (falling back to stripped text/html).
func messageText(header textproto.MIMEHeader, body io.Reader) string {
	plain, html := mailTextAlternatives(header, body)
	if plain != "" {
		return strings.TrimSpace(plain)
	}
	return strings.TrimSpace(html)
}
func mailTextAlternatives(header textproto.MIMEHeader, body io.Reader) (string, string) {
	if disposition, _, _ := mime.ParseMediaType(header.Get("Content-Disposition")); disposition == "attachment" {
		return "", ""
	}
	mediaType, params, err := mime.ParseMediaType(header.Get("Content-Type"))
	if err != nil {
		mediaType = "text/plain"
	}
	if strings.HasPrefix(mediaType, "multipart/") {
		reader := multipart.NewReader(body, params["boundary"])
		var plain, html string
		for {
			part, err := reader.NextRawPart()
			if err != nil {
				break
			}
			p, h := mailTextAlternatives(part.Header, part)
			if plain == "" {
				plain = p
			}
			if html == "" {
				html = h
			}
			if plain != "" {
				break
			}
		}
		return plain, html
	}
	switch mediaType {
	case "text/plain":
		return strings.TrimSpace(decodePart(body, header)), ""
	case "text/html":
		return "", strings.TrimSpace(stripHTMLTags(decodePart(body, header)))
	default:
		return "", ""
	}
}

func decodePart(body io.Reader, header textproto.MIMEHeader) string {
	switch strings.ToLower(strings.TrimSpace(header.Get("Content-Transfer-Encoding"))) {
	case "base64":
		raw, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, body))
		if err != nil {
			return ""
		}
		body = bytes.NewReader(raw)
	case "quoted-printable":
		body = quotedprintable.NewReader(body)
	}
	data, err := io.ReadAll(io.LimitReader(body, 400_000))
	if err != nil && len(data) == 0 {
		return ""
	}
	return decodeCharset(data, header.Get("Content-Type"))
}

func decodeCharset(data []byte, contentType string) string {
	charset := "utf-8"
	if _, params, err := mime.ParseMediaType(contentType); err == nil && params["charset"] != "" {
		charset = strings.ToLower(params["charset"])
	} else if !utf8.Valid(data) {
		return string(data)
	}
	switch {
	case strings.Contains(charset, "2312") || strings.Contains(charset, "gbk") || strings.Contains(charset, "gb18030"):
		decoded, err := simplifiedchinese.GB18030.NewDecoder().Bytes(data)
		if err == nil {
			return string(decoded)
		}
		return string(data)
	case strings.Contains(charset, "utf-16"):
		decoded, err := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder().Bytes(data)
		if err == nil {
			return string(decoded)
		}
		return string(data)
	case strings.Contains(charset, "8859") || strings.Contains(charset, "latin"):
		return string(data) // 近似处理:Latin 系单字节直接透传
	default:
		return string(data)
	}
}

func decodeMimeWords(value string) string {
	dec := &mime.WordDecoder{
		CharsetReader: func(charset string, input io.Reader) (io.Reader, error) {
			data, err := io.ReadAll(input)
			if err != nil {
				return nil, err
			}
			return strings.NewReader(decodeCharset(data, "text/plain; charset="+charset)), nil
		},
	}
	decoded, err := dec.DecodeHeader(value)
	if err != nil {
		return value
	}
	return decoded
}

func stripHTMLTags(text string) string {
	var out strings.Builder
	tokens := htmlparse.NewTokenizer(strings.NewReader(text))
	suppressed := 0
	for {
		kind := tokens.Next()
		if kind == htmlparse.ErrorToken {
			break
		}
		token := tokens.Token()
		switch kind {
		case htmlparse.StartTagToken:
			if token.Data == "head" || token.Data == "script" || token.Data == "style" {
				suppressed++
				continue
			}
			if suppressed == 0 && (token.Data == "p" || token.Data == "div" || token.Data == "br" || token.Data == "li") {
				out.WriteByte('\n')
			}
		case htmlparse.SelfClosingTagToken:
			if suppressed == 0 && token.Data == "br" {
				out.WriteByte('\n')
			}
		case htmlparse.EndTagToken:
			if token.Data == "head" || token.Data == "script" || token.Data == "style" {
				if suppressed > 0 {
					suppressed--
				}
				continue
			}
			if suppressed == 0 && (token.Data == "p" || token.Data == "div" || token.Data == "li") {
				out.WriteByte('\n')
			}
		case htmlparse.TextToken:
			if suppressed == 0 {
				out.WriteString(token.Data)
			}
		}
	}
	return strings.TrimSpace(out.String())
}
func limitMailText(value string, max int) string {
	value = strings.ToValidUTF8(value, "�")
	runes := []rune(value)
	if len(runes) <= max {
		return value
	}
	suffix := []rune("\n…[内容过长已截断]")
	if max <= len(suffix) {
		return string(runes[:max])
	}
	return string(runes[:max-len(suffix)]) + string(suffix)
}

func bestEffortText(raw []byte) string {
	text := string(raw)
	if idx := strings.Index(text, "\r\n\r\n"); idx >= 0 {
		text = text[idx+4:]
	}
	text = strings.TrimSpace(text)
	text = limitMailText(text, 20000)
	return text
}
