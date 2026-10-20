#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
test_home="${RIVER_DIARY_MAC_TEST_HOME:-${TMPDIR%/}/RiverDiaryMacTests-$(id -u)}"
mkdir -p "$test_home"
test_home="$(cd "$test_home" && pwd -P)"
real_home="$(cd "$HOME" && pwd -P)"
temporary_root="$(cd "${TMPDIR%/}" && pwd -P)"
shared_temporary_root="$(cd /tmp && pwd -P)"

case "$test_home/" in
  "$real_home/"*)
    print -u2 "Mac tests must not use the real user home."
    exit 65
    ;;
esac

case "$test_home/" in
  "$temporary_root/"*|"$shared_temporary_root/"*) ;;
  *)
    print -u2 "Mac test home must be inside TMPDIR or /tmp."
    exit 65
    ;;
esac

source "$repo_root/scripts/select_xcode.sh"
exec /usr/bin/env \
  CFFIXED_USER_HOME="$test_home" \
  RIVER_DIARY_MAC_TEST_HOME="$test_home" \
  "$RIVER_SWIFT_EXECUTABLE" test --package-path "$repo_root/macos/RiverDiaryMac" "$@"
