CREATE TABLE IF NOT EXISTS activation_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label text NOT NULL CHECK (length(label) BETWEEN 1 AND 120),
    product_code text NOT NULL DEFAULT 'riverdiary_premium'
        CHECK (product_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
    duration_days integer NOT NULL CHECK (duration_days BETWEEN 0 AND 36500),
    expires_at timestamptz,
    created_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS activation_batches_recent ON activation_batches(created_at DESC);

CREATE TABLE IF NOT EXISTS activation_codes (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id uuid NOT NULL REFERENCES activation_batches(id) ON DELETE RESTRICT,
    code_mac bytea NOT NULL UNIQUE,
    code_suffix text NOT NULL CHECK (length(code_suffix) BETWEEN 3 AND 8),
    created_at timestamptz NOT NULL DEFAULT now(),
    redeemed_at timestamptz,
    redeemed_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
    revoked_at timestamptz,
    CHECK ((redeemed_at IS NULL AND redeemed_user_id IS NULL)
        OR (redeemed_at IS NOT NULL AND redeemed_user_id IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS activation_codes_batch ON activation_codes(batch_id, created_at DESC);
CREATE INDEX IF NOT EXISTS activation_codes_user ON activation_codes(redeemed_user_id, redeemed_at DESC)
    WHERE redeemed_user_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS user_entitlements (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_code text NOT NULL CHECK (product_code ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
    starts_at timestamptz NOT NULL,
    expires_at timestamptz,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, product_code),
    CHECK (expires_at IS NULL OR expires_at > starts_at)
);
CREATE INDEX IF NOT EXISTS user_entitlements_expiry ON user_entitlements(expires_at)
    WHERE expires_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS activation_redemptions (
    id bigserial PRIMARY KEY,
    activation_code_id uuid NOT NULL UNIQUE REFERENCES activation_codes(id) ON DELETE RESTRICT,
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    product_code text NOT NULL,
    granted_at timestamptz NOT NULL DEFAULT now(),
    starts_at timestamptz NOT NULL,
    expires_at timestamptz,
    CHECK (expires_at IS NULL OR expires_at > starts_at)
);
CREATE INDEX IF NOT EXISTS activation_redemptions_user ON activation_redemptions(user_id, granted_at DESC);

CREATE TABLE IF NOT EXISTS activation_batch_requests (
    admin_id uuid NOT NULL REFERENCES admin_accounts(id) ON DELETE CASCADE,
    key_mac bytea NOT NULL,
    request_mac bytea NOT NULL,
    response_ciphertext bytea,
    retry_until timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (admin_id, key_mac)
);
CREATE INDEX IF NOT EXISTS activation_batch_requests_expiry ON activation_batch_requests(retry_until);
