#!/usr/bin/env zsh

# Source this from the app build/run scripts so they use the same toolchain as
# XCTest. An explicitly supplied DEVELOPER_DIR always wins.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  RIVER_XCODE_BETA_APP="${XCODE_BETA_APP:-$HOME/Downloads/Xcode-beta.app}"
  if [[ -d "$RIVER_XCODE_BETA_APP/Contents/Developer" ]]; then
    export DEVELOPER_DIR="$RIVER_XCODE_BETA_APP/Contents/Developer"
  fi
fi

if ! RIVER_SWIFT_EXECUTABLE="$(/usr/bin/xcrun --find swift 2>/dev/null)"; then
  echo "Unable to locate Swift for DEVELOPER_DIR=${DEVELOPER_DIR:-<xcode-select>}" >&2
  return 1
fi

if ! RIVER_SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || [[ ! -d "$RIVER_SDKROOT" ]]; then
  echo "Unable to locate the macOS SDK for DEVELOPER_DIR=${DEVELOPER_DIR:-<xcode-select>}" >&2
  return 1
fi

export RIVER_SWIFT_EXECUTABLE
export SDKROOT="$RIVER_SDKROOT"
echo "Swift toolchain: $RIVER_SWIFT_EXECUTABLE"
echo "macOS SDK: $SDKROOT"
