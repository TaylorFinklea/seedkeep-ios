#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'archive verification failed: %s\n' "$1" >&2
    exit 1
}

[[ $# -eq 3 ]] || fail 'usage: verify-release-archive.sh ARCHIVE_PATH EXPECTED_VERSION EXPECTED_BUILD'

archive_path="$1"
expected_version="$2"
expected_build="$3"
[[ -n "$expected_version" && -n "$expected_build" ]] || fail 'expected version and build must be non-empty'
[[ -d "$archive_path" ]] || fail 'archive path is not a directory'

applications_path="$archive_path/Products/Applications"
[[ -d "$applications_path" ]] || fail 'archive has no Products/Applications directory'

apps=()
while IFS= read -r app; do
    apps+=("$app")
done < <(find "$applications_path" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print)
[[ ${#apps[@]} -eq 1 ]] || fail "expected exactly one archived app, found ${#apps[@]}"

app_path="${apps[0]}"
info_plist="$app_path/Info.plist"
[[ -f "$info_plist" ]] || fail 'archived app has no Info.plist'
plutil -lint "$info_plist" >/dev/null 2>&1 || fail 'archived app Info.plist is malformed'

plist_value() {
    local key="$1"
    plutil -extract "$key" raw -o - "$info_plist" 2>/dev/null
}

expect_value() {
    local key="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(plist_value "$key")" || fail "missing or malformed $label"
    [[ "$actual" == "$expected" ]] || fail "$label mismatch"
}

expect_value CFBundleShortVersionString "$expected_version" 'archive version'
expect_value CFBundleVersion "$expected_build" 'archive build'
expect_value CFBundleIdentifier app.seedkeep.ios 'bundle identifier'

codesign --verify --deep --strict "$app_path" >/dev/null 2>&1 || fail 'archived app signature verification failed'

entitlements_path="$(mktemp "${TMPDIR:-/tmp}/seedkeep-archive-entitlements.XXXXXX")"
cleanup() {
    rm -f "$entitlements_path"
}
trap cleanup EXIT

codesign -d --entitlements :- "$app_path" >"$entitlements_path" 2>/dev/null || fail 'codesign could not read archived app entitlements'
plutil -lint "$entitlements_path" >/dev/null 2>&1 || fail 'archived app entitlements are malformed'

codesign_details="$(codesign -dv "$app_path" 2>&1)" || fail 'codesign could not inspect archived app identity'
team_identifier="$(printf '%s\n' "$codesign_details" | awk -F= '$1 == "TeamIdentifier" { print $2 }')"
[[ "$team_identifier" == K7CBQW6MPG ]] || fail 'TeamIdentifier mismatch'

entitlement_value() {
    local key="$1"
    /usr/libexec/PlistBuddy -c "Print :$key" "$entitlements_path" 2>/dev/null
}

expect_entitlement() {
    local key="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(entitlement_value "$key")" || fail "missing or malformed $label"
    [[ "$actual" == "$expected" ]] || fail "$label mismatch"
}

array_contains() {
    local key="$1"
    local expected="$2"
    local label="$3"
    local index=0
    local value
    while value="$(/usr/libexec/PlistBuddy -c "Print :$key:$index" "$entitlements_path" 2>/dev/null)"; do
        [[ "$value" == "$expected" ]] && return 0
        index=$((index + 1))
    done
    fail "missing or malformed $label"
}

expect_entitlement 'com.apple.developer.team-identifier' K7CBQW6MPG 'TeamIdentifier'
array_contains 'com.apple.developer.icloud-container-identifiers' iCloud.app.seedkeep 'Production iCloud container'
expect_entitlement 'com.apple.developer.icloud-container-environment' Production 'CloudKit container environment'
array_contains 'com.apple.developer.associated-domains' applinks:seedkeep.app 'associated domain'
expect_entitlement 'com.apple.developer.usernotifications.time-sensitive' true 'time-sensitive notification entitlement'
array_contains 'com.apple.developer.icloud-services' CloudKit 'CloudKit service entitlement'
array_contains 'com.apple.developer.applesignin' Default 'Sign in with Apple capability'
expect_entitlement 'com.apple.developer.weatherkit' true 'WeatherKit capability'

if /usr/libexec/PlistBuddy -c 'Print :aps-environment' "$entitlements_path" >/dev/null 2>&1; then
    fail 'forbidden aps-environment entitlement is present'
fi

printf 'PASS: archived app matches version %s (%s), Production CloudKit, and required entitlements\n' \
    "$expected_version" "$expected_build"
