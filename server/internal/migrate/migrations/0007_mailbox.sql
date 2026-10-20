-- 0007_mailbox: 用户反馈收件箱 + 管理员外发邮件
CREATE TABLE IF NOT EXISTS feedback_messages (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_email text NOT NULL DEFAULT '' CHECK (length(contact_email) <= 254),
    subject text NOT NULL DEFAULT '' CHECK (length(subject) <= 200),
    body text NOT NULL CHECK (char_length(body) BETWEEN 1 AND 4000),
    user_agent text NOT NULL DEFAULT '' CHECK (length(user_agent) <= 300),
    ip_mac bytea,
    status text NOT NULL DEFAULT 'new' CHECK (status IN ('new','read','replied','archived')),
    reply_body text NOT NULL DEFAULT '' CHECK (length(reply_body) <= 4000),
    replied_at timestamptz,
    replied_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS feedback_messages_status_idx ON feedback_messages(status, created_at DESC);
CREATE INDEX IF NOT EXISTS feedback_messages_recent_idx ON feedback_messages(created_at DESC);

CREATE TABLE IF NOT EXISTS admin_outbound_email (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient text NOT NULL CHECK (length(recipient) <= 254),
    subject text NOT NULL CHECK (length(subject) BETWEEN 1 AND 200),
    body text NOT NULL CHECK (length(body) <= 8000),
    purpose text NOT NULL DEFAULT 'manual' CHECK (purpose IN ('manual','feedback_reply')),
    feedback_id uuid REFERENCES feedback_messages(id) ON DELETE SET NULL,
    status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','sent','failed')),
    error_code text NOT NULL DEFAULT '' CHECK (length(error_code) <= 120),
    sent_at timestamptz,
    created_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_outbound_email_recent_idx ON admin_outbound_email(created_at DESC);
