#!/usr/bin/env bash
# 安装前检查：API-only Caddyfile 不得覆盖承载官网/登录/控制台的多站点配置。
# 用法：
#   sudo deploy/install-caddyfile.sh deploy/Caddyfile
#   sudo deploy/install-caddyfile.sh website/deploy/Caddyfile
#   RIVER_CADDY_TARGET=/tmp/Caddyfile deploy/install-caddyfile.sh --dry-run deploy/Caddyfile
set -euo pipefail

source_file="${1:?usage: install-caddyfile.sh <Caddyfile> [--dry-run]}"
shift || true
target="${RIVER_CADDY_TARGET:-/etc/caddy/Caddyfile}"
dry_run=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 64 ;;
  esac
done

[[ -f "$source_file" ]] || { printf 'missing Caddyfile: %s\n' "$source_file" >&2; exit 66; }

# 检测目标是否已有官网/登录/用户控制台站点。
target_has_website=0
for site in flowriver.xyz www.flowriver.xyz login.flowriver.xyz user.flowriver.xyz; do
  pattern="^[[:space:]]*${site//./\\.}[[:space:]]*\\{"
  if [[ -f "$target" ]] && grep -Eq "$pattern" "$target"; then target_has_website=1; fi
done

source_has_website=0
for site in flowriver.xyz www.flowriver.xyz login.flowriver.xyz user.flowriver.xyz; do
  pattern="^[[:space:]]*${site//./\\.}[[:space:]]*\\{"
  if grep -Eq "$pattern" "$source_file"; then source_has_website=1; fi
done

if (( target_has_website && ! source_has_website )); then
  printf '%s\n' \
    "REFUSE: $target 已包含官网/登录/控制台站点，而 $source_file 只有 api/admin。" \
    "直接覆盖会让这些站点 404。请把 api/admin 站点块合并进现有配置，" \
    "或改用包含六站点的 website/deploy/Caddyfile。" >&2
  exit 3
fi

if (( dry_run )); then
  printf 'OK: %s -> %s (website sites: %s)\n' "$source_file" "$target" "$([[ $source_has_website -eq 1 ]] && echo yes || echo no)"
  exit 0
fi

backup="${target}.before-flowriver-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -f "$target" ]]; then
  cp -p "$target" "$backup"
  printf 'backup: %s\n' "$backup"
fi
install -D -m 0644 "$source_file" "$target"

if ! command -v caddy >/dev/null 2>&1; then
  printf 'caddy is not in PATH; config installed but not validated\n' >&2
  exit 0
fi
if ! caddy validate --config "$target" --adapter caddyfile; then
  if [[ -f "$backup" ]]; then
    cp -p "$backup" "$target"
    printf 'validation failed; restored %s\n' "$backup" >&2
  fi
  exit 4
fi
if systemctl is-active --quiet caddy 2>/dev/null; then
  systemctl reload caddy
else
  systemctl enable --now caddy
fi
printf 'installed and reloaded: %s\n' "$target"
