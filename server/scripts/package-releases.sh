#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd)
dist_dir="$root_dir/dist"
for arch in amd64 arm64; do
  binary="$dist_dir/flowriver-api-linux-$arch"
  if [[ ! -x "$binary" ]]; then
    printf 'Missing executable release binary: %s\n' "$binary" >&2
    exit 2
  fi
  stage_dir=$(mktemp -d "$dist_dir/.release-$arch.XXXXXX")
  cleanup() { rm -r "$stage_dir"; }
  trap cleanup EXIT INT TERM
  install -m 0755 "$binary" "$stage_dir/flowriver-api"
  mkdir -p "$stage_dir/deploy"
  install -m 0644 "$root_dir/.env.example" "$stage_dir/env.example"
  install -m 0644 "$root_dir/deploy/Caddyfile" "$stage_dir/deploy/Caddyfile"
  install -m 0644 "$root_dir/deploy/Caddyfile.admin-only" "$stage_dir/deploy/Caddyfile.admin-only"
  install -m 0755 "$root_dir/deploy/backup.sh" "$stage_dir/deploy/backup.sh"
  install -m 0644 "$root_dir/deploy/backup.env.example" "$stage_dir/deploy/backup.env.example"
  install -m 0644 "$root_dir/deploy/flowriver-api.service" "$stage_dir/deploy/flowriver-api.service"
  install -m 0644 "$root_dir/deploy/flowriver-admin-only.service" "$stage_dir/deploy/flowriver-admin-only.service"
  install -m 0644 "$root_dir/deploy/flowriver-backup.service" "$stage_dir/deploy/flowriver-backup.service"
  install -m 0644 "$root_dir/deploy/flowriver-backup.timer" "$stage_dir/deploy/flowriver-backup.timer"
  mkdir -p "$stage_dir/api"
  install -m 0644 "$root_dir/api/openapi.yaml" "$stage_dir/api/openapi.yaml"
  if [[ -f "$root_dir/api/admin-openapi.yaml" ]]; then
    install -m 0644 "$root_dir/api/admin-openapi.yaml" "$stage_dir/api/admin-openapi.yaml"
  fi
  mkdir -p "$stage_dir/docs"
  install -m 0644 "$root_dir/../docs/operations/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md" "$stage_dir/docs/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md"
  install -m 0644 "$root_dir/../docs/operations/FLOWRIVER_SELF_HOSTED_SMTP_DNS.md" "$stage_dir/docs/FLOWRIVER_SELF_HOSTED_SMTP_DNS.md"
  install -m 0644 "$root_dir/../docs/operations/FLOWRIVER_ACTIVATION_CODES.md" "$stage_dir/docs/FLOWRIVER_ACTIVATION_CODES.md"
  cat > "$stage_dir/RELEASE-INFO.txt" <<INFO
FlowRiver account and administrator API
Target: Linux $arch, 64-bit
Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Go: $(go version)

The binary embeds the compiled administrator interface and API assets.
Read docs/FLOWRIVER_SERVER_DEPLOYMENT_TUTORIAL.md before installation.
Never copy a live server.env, SMTP password, Apple private key or rclone file
into this release archive.
INFO
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$stage_dir" && sha256sum flowriver-api > SHA256SUMS)
  else
    (cd "$stage_dir" && shasum -a 256 flowriver-api > SHA256SUMS)
  fi
  tar -czf "$dist_dir/flowriver-release-linux-$arch.tar.gz" -C "$stage_dir" .
  rm -r "$stage_dir"
  trap - EXIT INT TERM
done
