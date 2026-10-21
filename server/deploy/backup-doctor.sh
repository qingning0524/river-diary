#!/usr/bin/env bash
# 异机备份配置自检。只读检查，不创建/上传任何备份。
# 用法（服务器上）：
#   set -a; . /etc/flowriver/backup.env; set +a
#   sudo -E deploy/backup-doctor.sh
set -u

errors=0
warnings=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; errors=$((errors + 1)); }

require_command() {
  if command -v "$1" >/dev/null 2>&1; then pass "found $1: $(command -v "$1")"; else fail "missing $1"; fi
}

require_command pg_dump
require_command pg_restore
require_command psql
require_command age
require_command rclone

if [[ -n "${BACKUP_AGE_RECIPIENT:-}" ]]; then
  case "$BACKUP_AGE_RECIPIENT" in
    age1*|ssh-*) pass "BACKUP_AGE_RECIPIENT is set" ;;
    *) fail "BACKUP_AGE_RECIPIENT does not look like an age/ssh public key" ;;
  esac
else
  fail "BACKUP_AGE_RECIPIENT is not set"
fi

if [[ -n "${BACKUP_REMOTE:-}" ]]; then
  case "$BACKUP_REMOTE" in
    *:*) pass "BACKUP_REMOTE is a remote path" ;;
    *) fail "BACKUP_REMOTE must be remote:bucket/path, not a local directory" ;;
  esac
else
  fail "BACKUP_REMOTE is not set"
fi

if [[ -n "${RCLONE_CONFIG:-}" ]]; then
  if [[ -r "$RCLONE_CONFIG" ]]; then
    mode=$(stat -c '%a' "$RCLONE_CONFIG" 2>/dev/null || echo '?')
    case "$mode" in
      600|400) pass "RCLONE_CONFIG is readable and private ($mode)" ;;
      *) fail "RCLONE_CONFIG permissions are $mode; use 600 or 400" ;;
    esac
  else
    fail "RCLONE_CONFIG is not readable: $RCLONE_CONFIG"
  fi
else
  fail "RCLONE_CONFIG is not set"
fi

if [[ -n "${DATABASE_URL:-}" ]]; then
  if psql -X -q -At "$DATABASE_URL" -c 'SELECT 1' >/dev/null 2>&1; then
    pass "DATABASE_URL connects"
    state=$(psql -X -q -At "$DATABASE_URL" -c "SELECT state || ' / ' || coalesce(code,'') FROM backup_status WHERE singleton" 2>/dev/null || true)
    if [[ -n "$state" ]]; then
      case "$state" in
        fresh*) pass "backup_status is fresh" ;;
        *) warn "backup_status is '$state' (not fresh)" ;;
      esac
    else
      warn "backup_status has no row yet"
    fi
  else
    fail "DATABASE_URL cannot connect"
  fi
else
  fail "DATABASE_URL is not set"
fi

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet flowriver-backup.timer; then
    pass "flowriver-backup.timer is active"
  else
    fail "flowriver-backup.timer is not active"
  fi
fi

printf '\nResult: %d error(s), %d warning(s)\n' "$errors" "$warnings"
[[ "$errors" -eq 0 ]]
