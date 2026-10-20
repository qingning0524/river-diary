CREATE TABLE IF NOT EXISTS users (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status text NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'deleting', 'deleted', 'recovery_required')),
    created_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE IF NOT EXISTS identities (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider text NOT NULL CHECK (provider IN ('email', 'apple')),
    subject text NOT NULL,
    provider_client_id text,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    email_display text,
    email_canonical text,
    email_forwarding_enabled boolean NOT NULL DEFAULT true,
    refresh_token_ciphertext bytea,
    verified_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, subject),
    CHECK ((provider = 'email' AND email_canonical IS NOT NULL)
        OR (provider = 'apple' AND email_canonical IS NULL)),
    CHECK ((provider = 'email' AND provider_client_id IS NULL)
        OR (provider = 'apple' AND provider_client_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS identities_email_canonical
    ON identities(email_canonical) WHERE provider = 'email';
CREATE INDEX IF NOT EXISTS identities_user_id ON identities(user_id);

CREATE TABLE IF NOT EXISTS consents (
    id bigserial PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    terms_version text NOT NULL,
    privacy_version text NOT NULL,
    accepted_at timestamptz NOT NULL DEFAULT now(),
    source text NOT NULL CHECK (source IN ('email', 'apple'))
);

CREATE TABLE IF NOT EXISTS devices (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    instance_id uuid NOT NULL,
    platform text NOT NULL CHECK (platform IN ('ios', 'macos', 'other')),
    display_name text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz,
    UNIQUE (id, user_id),
    UNIQUE (user_id, instance_id)
);
CREATE INDEX IF NOT EXISTS devices_user_recent ON devices(user_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS auth_challenges (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    purpose text NOT NULL CHECK (purpose IN ('email_login', 'email_link', 'email_reauth', 'apple_login')),
    user_id uuid REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid,
    email_display text,
    email_canonical text,
    secret_mac bytea NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    request_ip_mac bytea,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'exchanging', 'consumed')),
    exchange_lease_id uuid,
    lease_until timestamptz,
    reauth_proof_mac bytea,
    CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS auth_challenges_email_recent
    ON auth_challenges(email_canonical, created_at DESC) WHERE consumed_at IS NULL;
CREATE INDEX IF NOT EXISTS auth_challenges_expiry ON auth_challenges(expires_at);

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
    bucket_mac bytea PRIMARY KEY,
    window_start timestamptz NOT NULL,
    hits integer NOT NULL CHECK (hits >= 0),
    expires_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS rate_limit_expiry ON rate_limit_buckets(expires_at);

CREATE TABLE IF NOT EXISTS outbox_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind text NOT NULL CHECK (kind IN ('email_otp', 'apple_revoke', 'account_delete')),
    deletion_job_id uuid,
    payload_ciphertext bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    lease_until timestamptz,
    completed_at timestamptz,
    last_error_code text
);
CREATE INDEX IF NOT EXISTS outbox_ready
    ON outbox_jobs(available_at, created_at) WHERE completed_at IS NULL;

CREATE TABLE IF NOT EXISTS sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id uuid NOT NULL,
    identity_id uuid REFERENCES identities(id) ON DELETE SET NULL,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked')),
    revoke_token_mac bytea NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    idle_expires_at timestamptz NOT NULL,
    absolute_expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    FOREIGN KEY (device_id, user_id) REFERENCES devices(id, user_id) ON DELETE CASCADE,
    CHECK (idle_expires_at <= absolute_expires_at)
);
CREATE INDEX IF NOT EXISTS sessions_user_active ON sessions(user_id, created_at DESC) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS reauth_proofs (
    token_mac bytea PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    purpose text NOT NULL CHECK (purpose IN ('account_delete','identity_change')),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    used_at timestamptz
);
CREATE INDEX IF NOT EXISTS reauth_proofs_expiry ON reauth_proofs(expires_at);

ALTER TABLE auth_challenges ADD CONSTRAINT auth_challenges_session_fk
    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS access_tokens (
    token_mac bytea PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS access_tokens_session ON access_tokens(session_id);
CREATE INDEX IF NOT EXISTS access_tokens_expiry ON access_tokens(expires_at);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_mac bytea PRIMARY KEY,
    session_id uuid NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    consumed_at timestamptz,
    request_id text,
    request_mac bytea,
    retry_until timestamptz,
    response_ciphertext bytea,
    CHECK ((consumed_at IS NULL AND request_id IS NULL)
        OR (consumed_at IS NOT NULL AND request_id IS NOT NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS refresh_one_current_per_session
    ON refresh_tokens(session_id) WHERE consumed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS refresh_request_once
    ON refresh_tokens(session_id,request_id) WHERE request_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS refresh_tokens_session ON refresh_tokens(session_id, created_at DESC);

CREATE TABLE IF NOT EXISTS idempotency_results (
    scope text NOT NULL,
    request_id text NOT NULL,
    request_mac bytea NOT NULL,
    response_ciphertext bytea NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (scope, request_id)
);
CREATE INDEX IF NOT EXISTS idempotency_expiry ON idempotency_results(expires_at);

CREATE TABLE IF NOT EXISTS audit_events (
    id bigserial PRIMARY KEY,
    user_id uuid,
    kind text NOT NULL,
    request_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_events_expiry ON audit_events(created_at);

CREATE TABLE IF NOT EXISTS provider_events (
    event_id text PRIMARY KEY,
    provider text NOT NULL,
    event_type text NOT NULL,
    payload_mac bytea NOT NULL,
    received_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz
);

CREATE TABLE IF NOT EXISTS deletion_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    old_user_id uuid NOT NULL,
    session_id uuid NOT NULL,
    request_id text NOT NULL,
    request_mac bytea NOT NULL,
    request_access_mac bytea NOT NULL,
    status_token_mac bytea NOT NULL UNIQUE,
    status_expires_at timestamptz NOT NULL,
    requested_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    apple_revocation_status text NOT NULL DEFAULT 'not_required'
        CHECK (apple_revocation_status IN ('not_required','pending','complete','manual_action_required')),
    last_error_code text
);
CREATE UNIQUE INDEX IF NOT EXISTS deletion_session_request ON deletion_jobs(session_id,request_id);
CREATE INDEX IF NOT EXISTS deletion_access_request ON deletion_jobs(request_access_mac,request_id);
CREATE INDEX IF NOT EXISTS deletion_jobs_pending
    ON deletion_jobs(requested_at) WHERE completed_at IS NULL;

CREATE TABLE IF NOT EXISTS security_event_outbox (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    old_user_id uuid NOT NULL,
    identity_id uuid,
    session_id uuid,
    request_id text,
    request_mac bytea,
    event_type text NOT NULL CHECK (event_type IN ('account_deleted', 'identity_revoked', 'apple_consent_revoked')),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    available_at timestamptz NOT NULL DEFAULT now(),
    attempts integer NOT NULL DEFAULT 0,
    lease_until timestamptz,
    delivered_at timestamptz,
    last_error_code text
);
CREATE INDEX IF NOT EXISTS security_event_outbox_pending
    ON security_event_outbox(available_at, occurred_at) WHERE delivered_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS security_event_session_request
    ON security_event_outbox(session_id,request_id) WHERE session_id IS NOT NULL AND request_id IS NOT NULL;
