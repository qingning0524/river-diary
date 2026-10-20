CREATE TABLE IF NOT EXISTS admin_accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username text NOT NULL UNIQUE,
    password_hash text NOT NULL,
    totp_secret_ciphertext bytea NOT NULL,
    totp_last_step bigint NOT NULL DEFAULT -1,
    disabled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_login_at timestamptz
);

CREATE TABLE IF NOT EXISTS admin_login_challenges (
    challenge_mac bytea PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    ip_mac bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS admin_login_challenges_expiry
    ON admin_login_challenges(expires_at);

CREATE TABLE IF NOT EXISTS admin_auth_buckets (
    bucket_mac bytea PRIMARY KEY,
    window_start timestamptz NOT NULL,
    hits integer NOT NULL CHECK (hits >= 0),
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS admin_auth_buckets_expiry
    ON admin_auth_buckets(expires_at);

CREATE TABLE IF NOT EXISTS admin_sessions (
    token_mac bytea PRIMARY KEY,
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    csrf_mac bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    idle_expires_at timestamptz NOT NULL,
    absolute_expires_at timestamptz NOT NULL,
    reauthenticated_until timestamptz,
    revoked_at timestamptz,
    ip_mac bytea NOT NULL,
    CHECK (idle_expires_at <= absolute_expires_at)
);
CREATE INDEX IF NOT EXISTS admin_sessions_account_recent
    ON admin_sessions(admin_id, created_at DESC);
CREATE INDEX IF NOT EXISTS admin_sessions_expiry
    ON admin_sessions(absolute_expires_at);

CREATE TABLE IF NOT EXISTS admin_audit_events (
    id bigserial PRIMARY KEY,
    admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    action text NOT NULL,
    target_type text NOT NULL DEFAULT '',
    target_id text NOT NULL DEFAULT '',
    reason_code text NOT NULL DEFAULT '',
    result text NOT NULL CHECK (result IN ('success', 'denied', 'failure')),
    request_id text NOT NULL,
    ip_mac bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_audit_events_recent
    ON admin_audit_events(created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS operations_status (
    id bigserial PRIMARY KEY,
    kind text NOT NULL CHECK (kind IN ('restore_drill')),
    result text NOT NULL CHECK (result IN ('success', 'failure')),
    summary text NOT NULL CHECK (length(summary) BETWEEN 1 AND 240),
    admin_id uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS operations_status_recent
    ON operations_status(kind, created_at DESC, id DESC);

CREATE TABLE IF NOT EXISTS admin_action_requests (
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    key_mac bytea NOT NULL,
    request_mac bytea NOT NULL,
    response_body jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (admin_id,key_mac)
);
CREATE INDEX IF NOT EXISTS admin_action_requests_expiry
    ON admin_action_requests(expires_at);

CREATE TABLE IF NOT EXISTS backup_status (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    state text NOT NULL CHECK (state IN ('running', 'success', 'failure')),
    code text NOT NULL DEFAULT '',
    updated_at timestamptz NOT NULL,
    object_name text NOT NULL DEFAULT ''
);
