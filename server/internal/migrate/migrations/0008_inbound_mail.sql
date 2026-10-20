-- 0008_inbound_mail: 完整入站邮件存储(轻量 webmail)
CREATE TABLE IF NOT EXISTS inbound_mail (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id text NOT NULL DEFAULT '' CHECK (length(message_id) <= 500),
    from_addr text NOT NULL DEFAULT '' CHECK (length(from_addr) <= 254),
    from_name text NOT NULL DEFAULT '' CHECK (length(from_name) <= 200),
    to_addr text NOT NULL DEFAULT '' CHECK (length(to_addr) <= 254),
    subject text NOT NULL DEFAULT '' CHECK (length(subject) <= 500),
    text_body text NOT NULL DEFAULT '' CHECK (length(text_body) <= 50000),
    raw bytea,
    status text NOT NULL DEFAULT 'new' CHECK (status IN ('new','read','replied')),
    replied_at timestamptz,
    replied_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS inbound_mail_recent_idx ON inbound_mail(created_at DESC);
