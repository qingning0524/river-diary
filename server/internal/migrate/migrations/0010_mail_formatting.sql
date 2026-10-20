-- Preserve the exact prepared message alongside historical plain-text bodies.
ALTER TABLE admin_outbound_email ADD COLUMN formatted_payload jsonb NOT NULL DEFAULT '{}'::jsonb;
-- Only newly ingested messages receive a digest; existing mail remains unchanged.
ALTER TABLE inbound_mail ADD COLUMN ingest_digest bytea;
CREATE UNIQUE INDEX inbound_mail_ingest_digest ON inbound_mail(ingest_digest) WHERE ingest_digest IS NOT NULL;
