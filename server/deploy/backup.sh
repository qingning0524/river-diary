#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${BACKUP_AGE_RECIPIENT:?BACKUP_AGE_RECIPIENT is required}"
: "${BACKUP_REMOTE:?BACKUP_REMOTE is required}"
: "${RCLONE_CONFIG:?RCLONE_CONFIG must name a protected rclone config file}"

case "$BACKUP_REMOTE" in
  *:*) ;;
  *) printf '%s\n' "BACKUP_REMOTE must be a configured remote path (remote:bucket/path)." >&2; exit 2 ;;
esac

umask 077
tmp_dir=$(mktemp -d /var/lib/flowriver/tmp/backup.XXXXXX)
started_ms=$(date +%s%3N)
record_state() {
  local state="$1"
  local code="$2"
  local object_name="$3"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  psql -X -q -v ON_ERROR_STOP=1 \
    -v backup_state="$state" -v backup_code="$code" \
    -v backup_updated_at="$timestamp" -v backup_object_name="$object_name" \
    "$DATABASE_URL" -c "INSERT INTO backup_status(singleton,state,code,updated_at,object_name)
      VALUES(true,:'backup_state',:'backup_code',:'backup_updated_at'::timestamptz,:'backup_object_name')
      ON CONFLICT(singleton) DO UPDATE SET state=EXCLUDED.state,code=EXCLUDED.code,
        updated_at=EXCLUDED.updated_at,object_name=EXCLUDED.object_name" >/dev/null
}
record_history() {
  local state="$1"
  local code="$2"
  local object_name="$3"
  local now_ms
  now_ms=$(date +%s%3N)
  local duration=$((now_ms - started_ms))
  psql -X -q -v ON_ERROR_STOP=1 \
    -v run_state="$state" -v run_code="$code" \
    -v run_object_name="$object_name" -v run_duration="$duration" \
    "$DATABASE_URL" -c "INSERT INTO backup_runs(state,code,summary,object_name,duration_ms)
      VALUES(:'run_state',:'run_code','backup.sh',:'run_object_name',:'run_duration'::bigint)" >/dev/null
}

success=0
failure_code=backup_failed
recorded_object=
cleanup() {
  find "$tmp_dir" -maxdepth 1 -type f -delete 2>/dev/null || true
  rmdir "$tmp_dir" 2>/dev/null || true
}
finish() {
  result=$?
  trap - EXIT INT TERM
  if [ "$success" -ne 1 ]; then
    record_state failure "$failure_code" "$recorded_object" || true
    record_history failure "$failure_code" "$recorded_object" || true
  fi
  cleanup
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stamp=$(date -u +%Y%m%dT%H%M%SZ)
dump_file="$tmp_dir/flowriver-$stamp.dump"
encrypted_name="flowriver-accounts-$stamp.dump.age"
encrypted_file="$tmp_dir/$encrypted_name"
remote_file="${BACKUP_REMOTE%/}/flowriver-accounts-$stamp.dump.age"
recorded_object="$remote_file"
failure_code=backup_in_progress
record_state running "backup_in_progress" "$remote_file"

failure_code=database_dump_failed
pg_dump --format=custom --compress=6 --no-owner --no-privileges --file="$dump_file" "$DATABASE_URL"
failure_code=database_dump_invalid
pg_restore --list "$dump_file" >/dev/null
failure_code=age_encryption_failed
age --encrypt --recipient "$BACKUP_AGE_RECIPIENT" --output "$encrypted_file" "$dump_file"
failure_code=offsite_upload_failed
rclone copyto "$encrypted_file" "$remote_file" --config "$RCLONE_CONFIG"
failure_code=offsite_verify_failed
rclone check "$tmp_dir" "${BACKUP_REMOTE%/}" --include "/$encrypted_name" --one-way --download --config "$RCLONE_CONFIG"
failure_code=backup_status_write_failed
record_state success "" "$remote_file"
record_history success "" "$remote_file"
success=1

printf '%s\n' "Encrypted account backup uploaded and verified: $remote_file"
