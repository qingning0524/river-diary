package mailer

import (
	"bytes"
	"fmt"
	"html/template"
	"net/mail"
	"strings"
	"time"
	"unicode/utf8"
)

// Message is the immutable content shared by preview, delivery and history.
type Message struct {
	Template         string    `json:"template"`
	RecipientName    string    `json:"recipient_name,omitempty"`
	Subject          string    `json:"subject"`
	Body             string    `json:"body"`
	Reference        string    `json:"reference,omitempty"`
	OriginalSubject  string    `json:"original_subject,omitempty"`
	OriginalBody     string    `json:"original_body,omitempty"`
	OriginalDate     string    `json:"original_date,omitempty"`
	SupportEmail     string    `json:"support_email,omitempty"`
	InReplyTo        string    `json:"in_reply_to,omitempty"`
	DeliveryID       string    `json:"delivery_id,omitempty"`
	VerificationCode string    `json:"verification_code,omitempty"`
	Date             time.Time `json:"date"`
}
type BodyBlock struct {
	Kind  string   `json:"kind"`
	Text  string   `json:"text,omitempty"`
	Lines []string `json:"lines,omitempty"`
	Items []string `json:"items,omitempty"`
}
type Preview struct {
	Template         string      `json:"template"`
	Label            string      `json:"label"`
	Title            string      `json:"title"`
	Subject          string      `json:"subject"`
	Greeting         string      `json:"greeting"`
	Blocks           []BodyBlock `json:"blocks"`
	Reference        string      `json:"reference"`
	Date             string      `json:"date"`
	Signature        string      `json:"signature"`
	SupportEmail     string      `json:"support_email"`
	OriginalSubject  string      `json:"original_subject,omitempty"`
	OriginalBody     string      `json:"original_body,omitempty"`
	OriginalDate     string      `json:"original_date,omitempty"`
	VerificationCode string      `json:"verification_code,omitempty"`
}
type FormattedMessage struct {
	Message Message `json:"message"`
	View    Preview `json:"view"`
	HTML    string  `json:"html"`
	Text    string  `json:"text"`
}

func ValidTemplate(value string) bool {
	return value == "support_reply" || value == "product_update" || value == "account_notice"
}
func MessageReference(id string) string {
	id = strings.ToUpper(strings.ReplaceAll(id, "-", ""))
	if len(id) > 12 {
		id = id[:12]
	}
	return "FR-" + id
}
func bodyBlocks(body string) []BodyBlock {
	groups := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n\n")
	blocks := make([]BodyBlock, 0, len(groups))
	for _, group := range groups {
		group = strings.TrimSpace(group)
		if group == "" {
			continue
		}
		lines := strings.Split(group, "\n")
		if len(lines) == 1 && strings.HasPrefix(group, "## ") {
			blocks = append(blocks, BodyBlock{Kind: "heading", Text: strings.TrimSpace(group[3:])})
			continue
		}
		items := []string{}
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "- ") || strings.HasPrefix(line, "* ") {
				items = append(items, strings.TrimSpace(line[2:]))
			} else {
				break
			}
		}
		if len(items) == len(lines) {
			blocks = append(blocks, BodyBlock{Kind: "list", Items: items})
		} else {
			blocks = append(blocks, BodyBlock{Kind: "paragraph", Text: group, Lines: lines})
		}
	}
	return blocks
}
func Render(message Message) (FormattedMessage, error) {
	if message.Template == "" {
		message.Template = "support_reply"
	}
	if !ValidTemplate(message.Template) && message.Template != "verification" {
		return FormattedMessage{}, fmt.Errorf("invalid email template")
	}
	if !utf8.ValidString(message.Body) || strings.ContainsAny(message.Subject, "\r\n") || utf8.RuneCountInString(message.Subject) > 200 || strings.TrimSpace(message.Subject) == "" {
		return FormattedMessage{}, fmt.Errorf("invalid email content")
	}
	if utf8.RuneCountInString(message.RecipientName) > 60 || strings.ContainsAny(message.RecipientName, "\r\n") {
		return FormattedMessage{}, fmt.Errorf("invalid recipient name")
	}
	if message.SupportEmail == "" {
		message.SupportEmail = "account@mail.flowriver.xyz"
	}
	if address, err := mail.ParseAddress(message.SupportEmail); err != nil || address.Address != message.SupportEmail {
		return FormattedMessage{}, fmt.Errorf("invalid support email")
	}
	if message.Date.IsZero() {
		message.Date = time.Now().UTC()
	}
	view := Preview{Template: message.Template, Subject: message.Subject, Greeting: "您好：", Blocks: bodyBlocks(message.Body), Reference: message.Reference, Date: message.Date.In(time.FixedZone("UTC+8", 8*3600)).Format("2006年01月02日 15:04"), SupportEmail: message.SupportEmail, OriginalSubject: message.OriginalSubject, OriginalBody: message.OriginalBody, OriginalDate: message.OriginalDate}
	if name := strings.TrimSpace(message.RecipientName); name != "" {
		view.Greeting = name + "，您好："
	}
	switch message.Template {
	case "support_reply":
		view.Label = "客户支持 · SUPPORT"
		view.Title = "关于您反馈的回复"
		view.Signature = "河流日记支持团队"
	case "product_update":
		view.Label = "产品动态 · PRODUCT"
		view.Title = "来自河流日记的新消息"
		view.Signature = "河流日记团队"
	case "account_notice":
		view.Label = "账号服务 · ACCOUNT"
		view.Title = "关于您的账号服务"
		view.Signature = "FlowRiver 账号服务团队"
	case "verification":
		if len(message.VerificationCode) != 8 || strings.Trim(message.VerificationCode, "0123456789") != "" {
			return FormattedMessage{}, fmt.Errorf("invalid verification code")
		}
		view.Label = "安全验证 · SECURITY"
		view.Title = "验证您的邮箱"
		view.Signature = "FlowRiver 账号服务团队"
		view.VerificationCode = message.VerificationCode
	}
	var html bytes.Buffer
	if err := brandTemplate.Execute(&html, view); err != nil {
		return FormattedMessage{}, err
	}
	var plain strings.Builder
	fmt.Fprintf(&plain, "河流日记 River Diary\n%s\n\n%s\n\n", view.Title, view.Greeting)
	for _, block := range view.Blocks {
		switch block.Kind {
		case "list":
			for _, item := range block.Items {
				fmt.Fprintf(&plain, "• %s\n", item)
			}
		case "heading":
			plain.WriteString(block.Text + "\n")
		default:
			plain.WriteString(block.Text + "\n")
		}
		plain.WriteString("\n")
	}
	if view.VerificationCode != "" {
		fmt.Fprintf(&plain, "验证码：%s\n10 分钟内有效。请勿向任何人透露此验证码。\n\n", view.VerificationCode)
	}
	if view.OriginalSubject != "" || view.OriginalBody != "" {
		fmt.Fprintf(&plain, "原始主题：%s\n%s\n", view.OriginalSubject, view.OriginalDate)
		if view.OriginalBody != "" {
			fmt.Fprintf(&plain, "%s\n", view.OriginalBody)
		}
		plain.WriteString("\n")
	}
	fmt.Fprintf(&plain, "%s\n%s\n", view.Signature, view.Date)
	if view.Reference != "" {
		fmt.Fprintf(&plain, "参考编号：%s\n", view.Reference)
	}
	fmt.Fprintf(&plain, "\n直接回复此邮件即可联系我们。\n官网：https://flowriver.xyz\n联系邮箱：%s\n", view.SupportEmail)
	return FormattedMessage{Message: message, View: view, HTML: html.String(), Text: plain.String()}, nil
}

var brandTemplate = template.Must(template.New("flowriver-email").Parse(`<!doctype html>
<html lang="zh-CN"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>{{.Subject}}</title><style>@media only screen and (max-width:640px){.mail-space{padding:28px 24px!important}.mail-title{font-size:26px!important}.mail-shell{border-radius:16px!important}}</style></head>
<body style="margin:0;padding:0;background:#f1f2f2;color:#26323b;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Microsoft YaHei',Arial,sans-serif">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">{{.Title}} · {{.Reference}}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#f1f2f2"><tr><td align="center" style="padding:32px 12px">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="mail-shell" style="max-width:620px;background:#ffffff;border:1px solid #e1e5e6;border-radius:22px;overflow:hidden">
<tr><td class="mail-space" style="padding:30px 40px;border-bottom:1px solid #e8ecee"><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td width="46" valign="middle"><div style="width:36px;height:36px;line-height:36px;text-align:center;border-radius:11px;background:#48677a;color:#ffffff;font-weight:700;font-size:18px">F</div></td><td valign="middle"><strong style="font-size:17px;letter-spacing:.2px;color:#263b49">河流日记</strong><br><span style="font-size:10px;letter-spacing:2px;color:#7b8b95">RIVER DIARY</span></td><td align="right" valign="middle" style="font-size:11px;color:#88969e">FlowRiver</td></tr></table></td></tr>
<tr><td class="mail-space" style="padding:36px 40px 18px"><div style="font-size:10px;letter-spacing:1.8px;font-weight:600;color:#48677a">{{.Label}}</div><h1 class="mail-title" style="margin:12px 0 0;font-size:30px;line-height:1.35;letter-spacing:-.7px;font-weight:650;color:#263b49">{{.Title}}</h1>{{if .Reference}}<p style="margin:12px 0 0;font-size:11px;color:#8a98a1">参考编号 {{.Reference}}</p>{{end}}</td></tr>
<tr><td class="mail-space" style="padding:16px 40px 32px;font-size:15px;line-height:1.85;color:#3e4a52;overflow-wrap:anywhere"><p style="margin:0 0 20px">{{.Greeting}}</p>
{{range .Blocks}}{{if eq .Kind "heading"}}<h2 style="margin:24px 0 10px;font-size:17px;color:#263b49">{{.Text}}</h2>{{else if eq .Kind "list"}}<ul style="margin:12px 0 20px;padding-left:22px">{{range .Items}}<li style="margin:6px 0">{{.}}</li>{{end}}</ul>{{else}}<p style="margin:0 0 18px">{{range $index,$line:=.Lines}}{{if $index}}<br>{{end}}{{$line}}{{end}}</p>{{end}}{{end}}
{{if .VerificationCode}}<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:24px 12px;background:#edf2f5;border:1px solid #dae4eb;border-radius:14px"><div style="font-size:11px;letter-spacing:2px;color:#627a8c">邮箱验证码</div><div style="margin-top:10px;font-size:32px;font-weight:700;letter-spacing:6px;font-family:Consolas,monospace;color:#263b49">{{.VerificationCode}}</div><div style="margin-top:12px;font-size:11px;color:#6f8290">10 分钟内有效 · 请勿向任何人透露</div></td></tr></table><p style="margin-top:18px;color:#798994;font-size:12px">如果这不是您发起的操作，请忽略此邮件。</p>{{end}}
{{if or .OriginalSubject .OriginalBody}}<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-top:24px"><tr><td style="padding:18px 20px;border-left:3px solid #b9cad6;background:#f5f7f8;border-radius:0 10px 10px 0;font-size:12px;line-height:1.7;color:#75838d"><strong style="color:#556875">原始主题</strong><br>{{.OriginalSubject}}{{if .OriginalDate}}<div style="font-size:10px;margin-top:5px">{{.OriginalDate}}</div>{{end}}{{if .OriginalBody}}<div style="white-space:pre-line;margin-top:10px">{{.OriginalBody}}</div>{{end}}</td></tr></table>{{end}}
<p style="margin:28px 0 0;color:#48677a;font-size:13px"><strong>{{.Signature}}</strong><br><span style="font-size:11px;color:#8a98a1">{{.Date}}</span></p></td></tr>
<tr><td class="mail-space" style="padding:24px 40px;background:#f8fafb;border-top:1px solid #e8ecee;font-size:11px;line-height:1.8;color:#8a98a1">直接回复此邮件即可联系我们。<br><a href="https://flowriver.xyz" style="color:#48677a;text-decoration:none">flowriver.xyz</a><span style="padding:0 10px;color:#c5cdd2">·</span><a href="mailto:{{.SupportEmail}}" style="color:#48677a;text-decoration:none">{{.SupportEmail}}</a><div style="margin-top:13px;font-size:10px;color:#a4afb6">FlowRiver · 河流日记<br>记录是起点，理解是下一步。</div></td></tr>
</table><div style="padding-top:18px;font-size:10px;letter-spacing:1px;color:#a1adb4">RIVER DIARY · FLOWRIVER</div>
</td></tr></table></body></html>`))
