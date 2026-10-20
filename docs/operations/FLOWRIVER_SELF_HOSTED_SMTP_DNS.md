# FlowRiver 自建 SMTP：DNS 与验收

这台 Ubuntu VPS 已安装 Postfix 与 OpenDKIM。Postfix 只监听 `127.0.0.1:25`，只接受本机 API 投递；它不会接收公网邮件，也不是开放中继。出站 TCP/25 已从 VPS 实测可连接 Gmail MX。API 还需部署支持 `SMTP_TLS_MODE=loopback` 的版本，DNS 验收完成后才启用发信。

## 在阿里云 DNS 配置记录

当前 `flowriver.xyz` 使用 `dns1.hichina.com`。请在权威 DNS 区域添加：

| 类型 | 主机记录 | 记录值 |
|---|---|---|
| A | `mail` | `198.23.189.187` |
| TXT | `mail` | `v=spf1 ip4:198.23.189.187 -all` |
| TXT | `_dmarc.mail` | `v=DMARC1; p=none; adkim=r; aspf=r` |
| TXT | `flowriver._domainkey.mail` | 见下方 DKIM 公钥 |

`flowriver._domainkey.mail` 的 TXT 值：

```text
v=DKIM1; h=sha256; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApZfOnV9Ck5n/NgNZw7vW1fKwKDk5MLRq5duGsg49oAYYFBfMO8AvP/23ZE7ok01KXRVNqtsORSIjx4e491PzRyjpcOo50wxf0EmA/d5wU+8oN9JT01/1hlVAOKqV93L4KhOawWdDhPdGcZC82tyRemqGhkfCxWDOMSKOeIhCt/317FCO/+sgDiirA2g6HRpzV4/ygPhTlZLi9jE+Kz1x1xDedheXbAPrXWiQDVJYzZplSaO0CfuSs9ErWM+lJL03+lazwpwgPymrDY/+2J7AOxPy6kp4btW4faEuPj/PCS3zSwIBU95QczEB+ZLfPgEES1GMxWjAPz+ADHexoFaHPQIDAQAB
```

SPF 需要每个发信域只有一条记录。如果 `mail` 已有 SPF，请合并而不是再新增一条。不要把 `.p8` 或服务器上的 DKIM 私钥填入 DNS；DNS 只发布上面的公钥。

## 设置 PTR/rDNS

VPS 控制面板中的 PTR/rDNS 已设置为：

```text
mail.flowriver.xyz
```

公网 DNS 现在确认 PTR 返回 `mail.flowriver.xyz.`，该主机的 A 记录返回 `198.23.189.187`。Gmail 要求发信 IP 有有效 PTR，且 PTR 指向的主机名再解析回同一 IP；未符合时邮件可能被拒收或进入垃圾箱。[Gmail 发件人指南](https://support.google.com/mail/answer/81126?hl=zh-Hans)

## 发信范围与后续验证

首期只发送账号验证码，From 地址为 `account@mail.flowriver.xyz`。Postfix 直接向收件方 MX 投递并对外使用 TLS。它不提供邮箱收件箱、MX 入站服务或退信处理；SMTP 接受邮件只表示收件方服务器接收了投递，不代表最终进入收件箱。

截至 2026-10-01，公网 A、SPF、DKIM、DMARC、PTR 查询均已通过，`opendkim-testkey` 显示 DNS 公钥与服务器密钥匹配，Postfix 配置检查通过。验证码测试已由 Gmail MX 接收（SMTP `2.0.0`）；最终收件箱分类和真实邮件头认证结果仍待用户查看。DKIM 私钥保存在服务器 `/etc/opendkim/keys/mail.flowriver.xyz/flowriver.private`（权限 `0600`），需要作为秘密单独备份。
