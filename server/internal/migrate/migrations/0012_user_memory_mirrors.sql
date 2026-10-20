-- Optional end-to-end encrypted cloud mirror. The service stores only the
-- ciphertext envelope and public encryption parameters; it never receives the
-- passphrase or plaintext memory. A user row is removed with the account.
CREATE TABLE IF NOT EXISTS user_memory_mirrors (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    format text NOT NULL,
    format_version integer NOT NULL CHECK (format_version = 1),
    kdf_name text NOT NULL,
    kdf_iterations integer NOT NULL CHECK (kdf_iterations BETWEEN 100000 AND 2000000),
    kdf_salt bytea NOT NULL CHECK (octet_length(kdf_salt) = 16),
    cipher_name text NOT NULL,
    cipher_iv bytea NOT NULL CHECK (octet_length(cipher_iv) = 12),
    ciphertext bytea NOT NULL CHECK (octet_length(ciphertext) BETWEEN 1 AND 16777216),
    client_updated_at timestamptz,
    summary jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
