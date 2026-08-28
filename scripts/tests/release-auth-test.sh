#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release.sh"
TEST_ROOT="$(mktemp -d /private/tmp/seedkeep-release-auth.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home"
cat > "$TEST_ROOT/bin/security" <<'SECURITY'
#!/usr/bin/env bash
case "$*" in
    *"-s IOS_RELEASE_KEY_ID "*) printf '%s\n' "${FAKE_KEYCHAIN_KEY_ID:-}" ;;
    *"-s IOS_RELEASE_ISSUER_ID "*) printf '%s\n' "${FAKE_KEYCHAIN_ISSUER_ID:-}" ;;
    *) exit 44 ;;
esac
SECURITY
chmod +x "$TEST_ROOT/bin/security"

ENV_KEY_PATH="$TEST_ROOT/env-key.p8"
touch "$ENV_KEY_PATH"

OUTPUT="$({
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    USER="release-test" \
    IOS_RELEASE_KEY_ID="ENVKEY1234" \
    IOS_RELEASE_ISSUER_ID="11111111-2222-3333-4444-555555555555" \
    IOS_RELEASE_KEY_PATH="$ENV_KEY_PATH" \
    FAKE_KEYCHAIN_KEY_ID="KEYCHAIN99" \
    FAKE_KEYCHAIN_ISSUER_ID="not-a-uuid" \
    "$RELEASE_SCRIPT" --check-auth
} 2>&1)" || {
    printf 'FAIL: environment credentials did not override conflicting Keychain values\n%s\n' "$OUTPUT" >&2
    exit 1
}

if [[ "$OUTPUT" == *"ENVKEY1234"* || "$OUTPUT" == *"11111111-2222-3333-4444-555555555555"* ]]; then
    printf 'FAIL: credential values leaked into auth-check output\n' >&2
    exit 1
fi

printf 'PASS: environment credentials override Keychain values without leaking them\n'

KEYCHAIN_KEY_ID="KEYCHAIN99"
KEYCHAIN_ISSUER_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
KEYCHAIN_KEY_PATH="$TEST_ROOT/home/.appstoreconnect/private_keys/AuthKey_${KEYCHAIN_KEY_ID}.p8"
mkdir -p "$(dirname "$KEYCHAIN_KEY_PATH")"
touch "$KEYCHAIN_KEY_PATH"

OUTPUT="$({
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    USER="release-test" \
    FAKE_KEYCHAIN_KEY_ID="$KEYCHAIN_KEY_ID" \
    FAKE_KEYCHAIN_ISSUER_ID="$KEYCHAIN_ISSUER_ID" \
    "$RELEASE_SCRIPT" --check-auth
} 2>&1)" || {
    printf 'FAIL: Keychain credentials were not used when environment overrides were absent\n%s\n' "$OUTPUT" >&2
    exit 1
}

if [[ "$OUTPUT" == *"$KEYCHAIN_KEY_ID"* || "$OUTPUT" == *"$KEYCHAIN_ISSUER_ID"* ]]; then
    printf 'FAIL: Keychain credential values leaked into auth-check output\n' >&2
    exit 1
fi

printf 'PASS: Keychain credentials supply the default private-key path without leaking them\n'

if OUTPUT="$({
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    USER="release-test" \
    FAKE_KEYCHAIN_KEY_ID="" \
    FAKE_KEYCHAIN_ISSUER_ID="" \
    "$RELEASE_SCRIPT" --check-auth
} 2>&1)"; then
    printf 'FAIL: missing Keychain services unexpectedly passed auth validation\n' >&2
    exit 1
fi

if [[ "$OUTPUT" != *"IOS_RELEASE_KEY_ID"* || "$OUTPUT" != *"IOS_RELEASE_ISSUER_ID"* ]]; then
    printf 'FAIL: missing-credential error did not name both required Keychain services\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: missing credentials fail closed and name both Keychain services\n'

MISSING_KEY_PATH="$TEST_ROOT/missing-key.p8"
if OUTPUT="$({
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    USER="release-test" \
    IOS_RELEASE_KEY_ID="MISSING123" \
    IOS_RELEASE_ISSUER_ID="99999999-8888-7777-6666-555555555555" \
    IOS_RELEASE_KEY_PATH="$MISSING_KEY_PATH" \
    "$RELEASE_SCRIPT" --check-auth
} 2>&1)"; then
    printf 'FAIL: missing private-key file unexpectedly passed auth validation\n' >&2
    exit 1
fi

if [[ "$OUTPUT" != *"IOS_RELEASE_KEY_PATH"* ]]; then
    printf 'FAIL: missing-file error did not name IOS_RELEASE_KEY_PATH\n%s\n' "$OUTPUT" >&2
    exit 1
fi
if [[ "$OUTPUT" == *"MISSING123"* || "$OUTPUT" == *"99999999-8888-7777-6666-555555555555"* ]]; then
    printf 'FAIL: credential values leaked into missing-file output\n' >&2
    exit 1
fi

printf 'PASS: missing private-key file fails closed without leaking credentials\n'
