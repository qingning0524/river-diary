-- 0006_changelog: 官网/客户端更新日志
CREATE TABLE IF NOT EXISTS changelog_entries (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_date date NOT NULL,
    version_tag text NOT NULL DEFAULT '' CHECK (length(version_tag) <= 40),
    title text NOT NULL CHECK (length(title) BETWEEN 1 AND 160),
    body text NOT NULL DEFAULT '' CHECK (length(body) <= 4000),
    is_published boolean NOT NULL DEFAULT false,
    created_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);
CREATE INDEX IF NOT EXISTS changelog_published_idx ON changelog_entries(is_published, entry_date DESC);
