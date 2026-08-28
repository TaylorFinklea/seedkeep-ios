#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFIER="$REPO_ROOT/scripts/verify-release-archive.sh"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release.sh"
TEST_ROOT="$(mktemp -d /private/tmp/seedkeep-archive-validation.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_fixture() {
    local name="$1"
    local version="${2:-1.0.0}"
    local build="${3:-53}"
    local bundle_id="${4:-app.seedkeep.ios}"
    local team="${5:-K7CBQW6MPG}"
    local container="${6:-iCloud.app.seedkeep}"
    local domain="${7:-applinks:seedkeep.app}"
    local time_sensitive="${8:-true}"
    local services="${9:-CloudKit}"
    local apns="${10:-}"
    local environment="${11:-Production}"
    local sign_in="${12:-Default}"
    local weatherkit="${13:-true}"
    local archive="$TEST_ROOT/$name.xcarchive"
    local app="$archive/Products/Applications/Seedkeep.app"

    mkdir -p "$app"
    cat > "$app/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
</dict></plist>
PLIST
    cat > "$app/fixture-entitlements" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>$container</string></array>
<key>com.apple.developer.associated-domains</key><array><string>$domain</string></array>
<key>com.apple.developer.usernotifications.time-sensitive</key><$time_sensitive/>
<key>com.apple.developer.icloud-services</key><array><string>$services</string></array>
<key>com.apple.developer.icloud-container-environment</key><string>$environment</string>
<key>com.apple.developer.applesignin</key><array><string>$sign_in</string></array>
<key>com.apple.developer.weatherkit</key><$weatherkit/>
$(if [[ -n "$apns" ]]; then printf '<key>aps-environment</key><string>%s</string>\n' "$apns"; fi)
</dict></plist>
ENTITLEMENTS
    printf '%s\n' "$archive"
}

mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/codesign" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
app="${@: -1}"
printf '%s\n' "$*" >> "${CODESIGN_CALL_LOG:-/dev/null}"
if [[ "$1" == "--verify" ]]; then
    [[ "${CODESIGN_VERIFY_FAIL:-}" != "1" ]] || exit 1
    exit 0
fi
if [[ "$1" == "-dv" ]]; then
    printf 'TeamIdentifier=%s\n' "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$app/fixture-entitlements")"
    exit 0
fi
cat "$app/fixture-entitlements"
STUB
chmod +x "$TEST_ROOT/bin/codesign"

valid_archive="$(make_fixture valid)"
if ! PATH="$TEST_ROOT/bin:$PATH" bash "$VERIFIER" "$valid_archive" 1.0.0 53 >/dev/null 2>&1; then
    fail 'fully valid archive was rejected'
fi

verify_failure_calls="$TEST_ROOT/verify-failure-calls.log"
: > "$verify_failure_calls"
if CODESIGN_VERIFY_FAIL=1 CODESIGN_CALL_LOG="$verify_failure_calls" PATH="$TEST_ROOT/bin:$PATH" bash "$VERIFIER" "$valid_archive" 1.0.0 53 >/dev/null 2>&1; then
    fail 'archive with an invalid nested signature was accepted'
fi
grep -q -- '--verify --deep --strict' "$verify_failure_calls" || fail 'archive signature was not verified with nested strict verification'
if grep -Eq -- '(^| )(-d|-dv)( |$)' "$verify_failure_calls"; then
    fail 'entitlement or identity inspection ran after signature verification failed'
fi

assert_rejected() {
    local label="$1"
    local archive="$2"
    if PATH="$TEST_ROOT/bin:$PATH" bash "$VERIFIER" "$archive" 1.0.0 53 >/dev/null 2>&1; then
        fail "$label archive was accepted"
    fi
}

assert_rejected 'version mismatch' "$(make_fixture bad-version 0.9.0)"
assert_rejected 'build mismatch' "$(make_fixture bad-build 1.0.0 52)"
assert_rejected 'bundle identifier mismatch' "$(make_fixture bad-bundle 1.0.0 53 com.example.other)"
assert_rejected 'team mismatch' "$(make_fixture bad-team 1.0.0 53 app.seedkeep.ios BADTEAM1234)"
assert_rejected 'container mismatch' "$(make_fixture bad-container 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.other)"
assert_rejected 'associated domain mismatch' "$(make_fixture bad-domain 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:other.app)"
assert_rejected 'time-sensitive mismatch' "$(make_fixture bad-time 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app false)"
assert_rejected 'CloudKit service mismatch' "$(make_fixture bad-services 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app true iCloudServices)"
assert_rejected 'APNs entitlement' "$(make_fixture bad-apns 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app true CloudKit aps-environment)"
assert_rejected 'CloudKit environment mismatch' "$(make_fixture bad-environment 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app true CloudKit '' Development)"
assert_rejected 'Sign in with Apple capability mismatch' "$(make_fixture bad-signin 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app true CloudKit '' Production Wrong)"
assert_rejected 'WeatherKit capability mismatch' "$(make_fixture bad-weatherkit 1.0.0 53 app.seedkeep.ios K7CBQW6MPG iCloud.app.seedkeep applinks:seedkeep.app true CloudKit '' Production Default false)"

mkdir -p "$TEST_ROOT/missing.xcarchive/Products/Applications"
assert_rejected 'missing-app' "$TEST_ROOT/missing.xcarchive"
mkdir -p "$TEST_ROOT/multiple.xcarchive/Products/Applications/Seedkeep.app"
mkdir -p "$TEST_ROOT/multiple.xcarchive/Products/Applications/Other.app"
assert_rejected 'multiple-app' "$TEST_ROOT/multiple.xcarchive"

release_root="$TEST_ROOT/release"
mkdir -p "$release_root/scripts" "$release_root/Seedkeep"
cp "$RELEASE_SCRIPT" "$release_root/scripts/release.sh"
cp "$REPO_ROOT/scripts/verify-release-archive.sh" "$release_root/scripts/verify-release-archive.sh"
cp "$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh" "$release_root/scripts/resolve-xcode-developer-dir.sh"
cp "$REPO_ROOT/scripts/test-gate.sh" "$release_root/scripts/test-gate.sh"
cp "$REPO_ROOT/Seedkeep/ExportOptions.plist" "$release_root/Seedkeep/ExportOptions.plist"
sed -i '' "s|/tmp/Seedkeep-build|$TEST_ROOT/Seedkeep-build|g" "$release_root/scripts/release.sh"
cat > "$release_root/project.yml" <<'YAML'
settings:
  MARKETING_VERSION: "1.0.0"
  CURRENT_PROJECT_VERSION: "52"
YAML
mkdir -p "$release_root/Seedkeep/Core/Changelog"
printf 'build: 53\n' > "$release_root/Seedkeep/Core/Changelog/ChangelogData.swift"

call_log="$TEST_ROOT/release-calls.log"
for command in security git xcodegen xcodebuild; do
    cat > "$TEST_ROOT/bin/$command" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0") $*" >> "${ARCHIVE_GATE_CALL_LOG:?}"
case "$(basename "$0")" in
    security) printf 'fixture\n' ;;
    git) exit 0 ;;
    xcodegen) exit 0 ;;
    xcodebuild)
        if [[ "$*" == *" archive" ]]; then
            mkdir -p "$ARCHIVE_GATE_ARCHIVE/Products/Applications/Seedkeep.app"
            : > "$ARCHIVE_GATE_ARCHIVE/Products/Applications/Seedkeep.app/Info.plist"
            printf 'Archive Succeeded\n'
        elif [[ "$*" == *"-exportArchive" ]]; then
            printf 'export reached\n' >> "$ARCHIVE_GATE_EXPORT_MARKER"
            exit 99
        fi
        ;;
esac
STUB
    chmod +x "$TEST_ROOT/bin/$command"
done

mkdir -p "$release_root/Seedkeep"
printf 'not-a-plist\n' > "$release_root/Seedkeep/ExportOptions.plist"
archive_gate_archive="$TEST_ROOT/Seedkeep-build53.xcarchive"
export_marker="$TEST_ROOT/export-reached"
touch "$TEST_ROOT/key.p8"
if release_output="$(PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    ARCHIVE_GATE_CALL_LOG="$call_log" \
    ARCHIVE_GATE_ARCHIVE="$archive_gate_archive" \
    ARCHIVE_GATE_EXPORT_MARKER="$export_marker" \
    HOME="$TEST_ROOT" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    IOS_RELEASE_KEY_ID=fixture IOS_RELEASE_ISSUER_ID=fixture IOS_RELEASE_KEY_PATH="$TEST_ROOT/key.p8" \
    bash "$release_root/scripts/release.sh" --skip-tests --skip-changelog --build 2>&1)"; then
    fail 'release script accepted a malformed archived app'
fi
if [[ "$release_output" != *'archive verification failed'* ]]; then
    fail "release script did not fail at archive verification: $release_output"
fi
grep -q 'xcodebuild .* archive' "$call_log" || fail 'release script did not reach archive creation'
if [[ -e "$export_marker" ]]; then
    fail 'release script reached export after archive verification failure'
fi

printf 'PASS: signed archive validation rejects required mismatches and gates export\n'
