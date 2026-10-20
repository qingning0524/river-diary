-- 0005_admin_expansion: 公告、下载管理、账号封禁、权益授予来源、备份历史
ALTER TABLE users ADD COLUMN disabled_at timestamptz;
ALTER TABLE users ADD COLUMN disabled_reason text;

CREATE TABLE IF NOT EXISTS announcements (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    level text NOT NULL DEFAULT 'info' CHECK (level IN ('info','warn','critical')),
    title text NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    body text NOT NULL DEFAULT '' CHECK (length(body) <= 500),
    placement text NOT NULL DEFAULT 'banner' CHECK (placement IN ('banner','download','both')),
    href text NOT NULL DEFAULT '' CHECK (length(href) <= 300),
    active boolean NOT NULL DEFAULT false,
    starts_at timestamptz,
    ends_at timestamptz,
    created_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (starts_at IS NULL OR ends_at IS NULL OR starts_at < ends_at)
);
CREATE INDEX IF NOT EXISTS announcements_active_idx ON announcements(active, created_at DESC);

CREATE TABLE IF NOT EXISTS download_artifacts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    platform text NOT NULL CHECK (platform IN ('macos','ios')),
    version text NOT NULL CHECK (length(version) BETWEEN 1 AND 60),
    filename text NOT NULL CHECK (length(filename) BETWEEN 1 AND 200),
    size_bytes bigint NOT NULL CHECK (size_bytes > 0),
    sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    note text NOT NULL DEFAULT '' CHECK (length(note) <= 500),
    is_active boolean NOT NULL DEFAULT false,
    created_by uuid REFERENCES admin_accounts(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS download_artifacts_active_platform
    ON download_artifacts(platform) WHERE is_active;
CREATE INDEX IF NOT EXISTS download_artifacts_platform_idx
    ON download_artifacts(platform, created_at DESC);

ALTER TABLE user_entitlements ADD COLUMN grant_source text NOT NULL DEFAULT 'activation_code';

CREATE TABLE IF NOT EXISTS backup_runs (
    id bigserial PRIMARY KEY,
    state text NOT NULL CHECK (state IN ('running','success','failure')),
    code text NOT NULL DEFAULT '',
    summary text NOT NULL DEFAULT '',
    object_name text NOT NULL DEFAULT '',
    duration_ms bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS backup_runs_created_idx ON backup_runs(created_at DESC);
