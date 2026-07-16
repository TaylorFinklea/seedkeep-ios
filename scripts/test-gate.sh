#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_UDID="${SIM_UDID:-}"

fail() {
    echo "[test-gate] ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulator-udid)
            [[ $# -ge 2 ]] || fail "--simulator-udid requires a UDID"
            SIM_UDID="$2"
            shift 2
            ;;
        *)
            fail "Unknown flag: $1. Use --simulator-udid <UDID>."
            ;;
    esac
done

cd "$REPO_ROOT"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required to generate Seedkeep.xcodeproj"
echo "[test-gate] Generating Xcode project"
xcodegen generate >/dev/null

DEVICE_LIST="$(xcrun simctl list devices available)"
if [[ -z "$SIM_UDID" ]]; then
    SIM_LINE="$(awk '/iPhone/ { print; exit }' <<< "$DEVICE_LIST")"
    SIM_UDID="$(printf '%s\n' "$SIM_LINE" | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}' || true)"
fi
[[ -n "$SIM_UDID" ]] || fail "no available iPhone simulator found"
if ! grep -Fq "$SIM_UDID" <<< "$DEVICE_LIST"; then
    fail "simulator $SIM_UDID is not available"
fi
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true

run_counted() {
    local label="$1"
    shift
    local log
    log="$(mktemp "${TMPDIR:-/tmp}/seedkeep-test-gate.XXXXXX")"
    echo "[test-gate] $label"
    set +e
    "$@" 2>&1 | tee "$log"
    local status="${PIPESTATUS[0]}"
    set -e
    if [[ "$status" -ne 0 ]]; then
        rm -f "$log"
        fail "$label failed with exit status $status"
    fi
    if ! grep -Eq 'Executed [1-9][0-9]* tests?|with [1-9][0-9]* tests?' "$log"; then
        rm -f "$log"
        fail "$label executed zero tests or did not report a test count"
    fi
    rm -f "$log"
}

run_counted "SeedkeepKit package tests" swift test --package-path "$REPO_ROOT/SeedkeepKit"
run_counted "SeedkeepCloudKit package tests" swift test --package-path "$REPO_ROOT/SeedkeepCloudKit"

XCODEBUILD_ARGS=(
    -project "$REPO_ROOT/Seedkeep.xcodeproj"
    -scheme Seedkeep
    -destination "platform=iOS Simulator,id=$SIM_UDID"
    -parallel-testing-enabled NO
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
)

run_counted "legacy CloudKit-OFF app tests" xcodebuild "${XCODEBUILD_ARGS[@]}" \
    -skip-testing:SeedkeepTests/ProductionDefaultCloudKitGateTests \
    test

run_counted "production-default CloudKit-ON contract" xcodebuild "${XCODEBUILD_ARGS[@]}" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG SEEDKEEP_TEST_CLOUDKIT_ON' \
    -only-testing:SeedkeepTests/ProductionDefaultCloudKitGateTests \
    test

echo "[test-gate] all required tests passed"
