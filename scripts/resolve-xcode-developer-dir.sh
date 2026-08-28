#!/usr/bin/env bash

set -euo pipefail

CANDIDATE="${1:-/Applications/Xcode.app/Contents/Developer}"

if [[ ! -x "$CANDIDATE/usr/bin/xcodebuild" || ! -d "$CANDIDATE/Platforms/iPhoneSimulator.platform" ]]; then
    echo "[release] ERROR: DEVELOPER_DIR must identify a complete Xcode developer directory containing xcodebuild and the iOS Simulator platform." >&2
    exit 1
fi

printf '%s\n' "$CANDIDATE"
