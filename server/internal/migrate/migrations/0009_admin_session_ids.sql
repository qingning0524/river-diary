-- Give management listings a public identifier independent of authentication digests.
-- The default backfills existing sessions without changing their token lookup or validity.
ALTER TABLE admin_sessions ADD COLUMN id uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX admin_sessions_public_id ON admin_sessions(id);
