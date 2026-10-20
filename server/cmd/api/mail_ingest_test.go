package main

import (
	"mime"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestParseInboundPrefersPlainBodyAndSkipsAttachments(t *testing.T) {
	raw := "From: Owner@EXAMPLE.TEST\r\nTo: account@mail.flowriver.xyz\r\nSubject: test\r\nContent-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=x.bin\r\n\r\nattachment bytes\r\n--outer\r\nContent-Type: multipart/alternative; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>HTML fallback</p>\r\n--inner\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n实际正文 <div>代码示例</div>\r\n--inner--\r\n--outer--\r\n"
	parsed := parseInbound([]byte(raw))
	if parsed.Body != "实际正文 <div>代码示例</div>" {
		t.Fatalf("wrong MIME part selected: %q", parsed.Body)
	}
	if parsed.FromAddr != "Owner@EXAMPLE.TEST" {
		t.Fatal("sender local-part case was changed")
	}
}
func TestParseInboundSafeUnicodeLimits(t *testing.T) {
	subject := strings.Repeat("主题", 300)
	body := strings.Repeat("记录", 40000)
	raw := "From: sender@example.test\r\nTo: account@mail.flowriver.xyz\r\nSubject: " + mime.QEncoding.Encode("utf-8", subject) + "\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n" + body
	parsed := parseInbound([]byte(raw))
	if !utf8.ValidString(parsed.Body) || utf8.RuneCountInString(parsed.Body) > 50000 || utf8.RuneCountInString(parsed.Subject) > 500 {
		t.Fatalf("parsed mail cannot be stored safely: body=%d subject=%d", utf8.RuneCountInString(parsed.Body), utf8.RuneCountInString(parsed.Subject))
	}
}
func TestHTMLMailFallbackExcludesScriptAndKeepsParagraphs(t *testing.T) {
	raw := "From: sender@example.test\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><head><style>.secret{}</style></head><body><p>第一段</p><script>bad()</script><p>第二段 &amp; 其他</p></body></html>"
	parsed := parseInbound([]byte(raw))
	if strings.Contains(parsed.Body, "bad()") || strings.Contains(parsed.Body, "secret") || !strings.Contains(parsed.Body, "第一段\n") || !strings.Contains(parsed.Body, "第二段 & 其他") {
		t.Fatalf("invalid HTML fallback: %q", parsed.Body)
	}
}
