#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESOLVER="$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release.sh"
TEST_ROOT="$(mktemp -d /private/tmp/seedkeep-xcode-dir.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

EXPLICIT_DIR="$TEST_ROOT/Explicit.app/Contents/Developer"
mkdir -p "$EXPLICIT_DIR/usr/bin" "$EXPLICIT_DIR/Platforms/iPhoneSimulator.platform"
touch "$EXPLICIT_DIR/usr/bin/xcodebuild" "$EXPLICIT_DIR/usr/bin/xcrun"
chmod +x "$EXPLICIT_DIR/usr/bin/xcodebuild" "$EXPLICIT_DIR/usr/bin/xcrun"

OUTPUT="$(bash "$RESOLVER" "$EXPLICIT_DIR")" || {
    printf 'FAIL: an explicit valid DEVELOPER_DIR was rejected\n%s\n' "$OUTPUT" >&2
    exit 1
}
if [[ "$OUTPUT" != "$EXPLICIT_DIR" ]]; then
    printf 'FAIL: explicit DEVELOPER_DIR was not preserved\n' >&2
    exit 1
fi

printf 'PASS: explicit DEVELOPER_DIR wins\n'

DEFAULT_DIR="/Applications/Xcode.app/Contents/Developer"
OUTPUT="$(bash "$RESOLVER")" || {
    printf 'FAIL: the standard Xcode developer directory fallback was rejected\n%s\n' "$OUTPUT" >&2
    exit 1
}
if [[ "$OUTPUT" != "$DEFAULT_DIR" ]]; then
    printf 'FAIL: unset DEVELOPER_DIR did not select the standard Xcode installation\n' >&2
    exit 1
fi

printf 'PASS: unset DEVELOPER_DIR selects the standard Xcode installation\n'

INVALID_DIR="$TEST_ROOT/Missing.app/Contents/Developer"
if OUTPUT="$(bash "$RESOLVER" "$INVALID_DIR" 2>&1)"; then
    printf 'FAIL: an invalid DEVELOPER_DIR was accepted\n%s\n' "$OUTPUT" >&2
    exit 1
fi
if [[ "$OUTPUT" != *"DEVELOPER_DIR"* ]]; then
    printf 'FAIL: invalid-directory error did not name DEVELOPER_DIR\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: invalid DEVELOPER_DIR fails early with a named setting\n'

AUTH_KEY_PATH="$TEST_ROOT/AuthKey_TESTKEY.p8"
touch "$AUTH_KEY_PATH"
if OUTPUT="$({
    DEVELOPER_DIR="$INVALID_DIR" \
    IOS_RELEASE_KEY_ID="TESTKEY" \
    IOS_RELEASE_ISSUER_ID="11111111-2222-3333-4444-555555555555" \
    IOS_RELEASE_KEY_PATH="$AUTH_KEY_PATH" \
    "$RELEASE_SCRIPT" --check-auth
} 2>&1)"; then
    printf 'FAIL: release preflight accepted an invalid DEVELOPER_DIR\n%s\n' "$OUTPUT" >&2
    exit 1
fi
if [[ "$OUTPUT" != *"DEVELOPER_DIR"* ]]; then
    printf 'FAIL: release preflight did not name the invalid DEVELOPER_DIR\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: release preflight validates DEVELOPER_DIR before reporting readiness\n'
