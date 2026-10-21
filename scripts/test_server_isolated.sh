#!/bin/zsh
# T01/T17：用一次性 PostgreSQL 集群跑服务端集成测试，不跳过数据库用例。
#
# 默认 `go test ./...` 在 TEST_DATABASE_URL 缺失时会跳过全部 PostgreSQL 集成
# 用例（38 例），发布门禁不能接受“静默 skip”。本脚本在系统临时目录里 initdb
# 一个独立集群，只监听 127.0.0.1 的随机端口，跑完立即停止并删除。
#
# 用法：
#   scripts/test_server_isolated.sh [--keep] [go test 参数...]
#
# 退出码：0 全部通过；1 测试失败；65 缺少工具链；70 集群启动失败。
set -euo pipefail

repo_root="${0:A:h:h}"
server_dir="$repo_root/server"
keep=0
go_args=()
for arg in "$@"; do
  case "$arg" in
    --keep) keep=1 ;;
    *) go_args+=("$arg") ;;
  esac
done

find_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  for candidate in "/opt/homebrew/bin/$name" "/usr/local/bin/$name" "/usr/local/go/bin/$name"; do
    if [[ -x "$candidate" ]]; then
      print -r -- "$candidate"
      return 0
    fi
  done
  return 1
}

initdb_bin="$(find_tool initdb || true)"
pg_ctl_bin="$(find_tool pg_ctl || true)"
createdb_bin="$(find_tool createdb || true)"
go_bin="$(find_tool go || true)"
for pair in "initdb:$initdb_bin" "pg_ctl:$pg_ctl_bin" "createdb:$createdb_bin" "go:$go_bin"; do
  tool="${pair%%:*}"
  tool_path="${pair#*:}"
  if [[ -z "$tool_path" ]]; then
    print -u2 "FAIL: 找不到 $tool；请安装 PostgreSQL 16 与 Go 后重试。"
    exit 65
  fi
done

if [[ ! -d "$server_dir" ]]; then
  print -u2 "FAIL: 找不到服务端目录 $server_dir"
  exit 65
fi

port="$(python3 - <<'PY'
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

work_root="$(mktemp -d "${TMPDIR%/}/RiverDiary-pg-gate.XXXXXX")"
cluster="$work_root/pgdata"
sock_dir="$work_root/socket"
mkdir -p "$sock_dir" "$work_root/tmp"
log_path="$work_root/postgres.log"
test_log="$work_root/go-test.log"
started=0

cleanup() {
  if [[ "$started" -eq 1 ]]; then
    "$pg_ctl_bin" -D "$cluster" -m immediate stop >/dev/null 2>&1 || true
  fi
  if [[ "$keep" -eq 0 ]]; then
    rm -rf "$work_root" 2>/dev/null || true
  else
    print -r -- "Kept work root: $work_root"
  fi
}
trap cleanup EXIT

# macOS 上 locale 未定义会让 postmaster 启动时报 "became multithreaded"。
export LC_ALL="${LC_ALL:-en_US.UTF-8}"

print -r -- "Isolated PostgreSQL cluster: $cluster (port $port)"
if ! "$initdb_bin" -D "$cluster" -U flowriver --auth=trust --no-locale -E UTF8 \
    > "$work_root/initdb.log" 2>&1; then
  tail -10 "$work_root/initdb.log" >&2
  print -u2 "FAIL: initdb 失败"
  exit 70
fi

if ! "$pg_ctl_bin" -D "$cluster" -l "$log_path" \
    -o "-p $port -k $sock_dir -c listen_addresses=127.0.0.1 -c fsync=off" \
    start >/dev/null 2>&1; then
  tail -10 "$log_path" >&2
  print -u2 "FAIL: PostgreSQL 启动失败"
  exit 70
fi
started=1

if ! "$createdb_bin" -h 127.0.0.1 -p "$port" -U flowriver flowriver_gate_test; then
  print -u2 "FAIL: 创建测试库失败"
  exit 70
fi

export TEST_DATABASE_URL="postgres://flowriver@127.0.0.1:$port/flowriver_gate_test?sslmode=disable"
export PATH="$(dirname "$go_bin"):$PATH"
# 工作区沙箱/CI 里用户级 go-build 缓存可能不可写；把缓存放进一次性目录，
# 保证门禁不会因为缓存权限而“没跑就失败”。
export GOCACHE="$work_root/gocache"
export GOTMPDIR="$work_root/tmp"

print -r -- "Running go test ./... against TEST_DATABASE_URL=$TEST_DATABASE_URL"
set +e
( cd "$server_dir" && "$go_bin" test -count=1 -v ./... ) > "$test_log" 2>&1
test_status=$?
set -e

runs="$(grep -c '^=== RUN' "$test_log" || true)"
passes="$(grep -c '^--- PASS' "$test_log" || true)"
skips="$(grep -c '^--- SKIP' "$test_log" || true)"
fails="$(grep -c '^--- FAIL' "$test_log" || true)"

print -r -- "Top-level tests passed: $passes"
print -r -- "Top-level tests skipped: $skips"
print -r -- "Top-level tests failed:  $fails"
print -r -- "(RUN lines include subtests: $runs)"
if [[ -n "${RIVER_TEST_GREP:-}" ]]; then
  print -r -- "--- selected test log lines ---"
  grep -E "$RIVER_TEST_GREP" "$test_log" || true
fi

if [[ "$skips" -ne 0 ]]; then
  grep '^--- SKIP' "$test_log" | head -10 >&2
fi

if [[ "$test_status" -ne 0 ]]; then
  print -u2 "FAIL: go test exited with $test_status"
  grep -E '^--- FAIL|^FAIL' "$test_log" | head -20 >&2
  tail -30 "$test_log" >&2
  exit 1
fi
if [[ "$skips" -ne 0 ]]; then
  print -u2 "FAIL: 仍有 $skips 个顶层用例被跳过；发布门禁要求数据库集成全部执行。"
  exit 1
fi
print -r -- "PASS: all server tests ran against an isolated PostgreSQL (0 skipped)."
