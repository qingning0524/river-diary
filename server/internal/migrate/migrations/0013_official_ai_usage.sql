CREATE TABLE IF NOT EXISTS ai_usage (
    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    month date NOT NULL,
    requests integer NOT NULL DEFAULT 0 CHECK (requests >= 0),
    input_tokens bigint NOT NULL DEFAULT 0 CHECK (input_tokens >= 0),
    output_tokens bigint NOT NULL DEFAULT 0 CHECK (output_tokens >= 0),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, month)
);
