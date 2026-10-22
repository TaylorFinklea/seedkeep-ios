#!/usr/bin/env bash
# R2d automated accessibility audit: runs the SeedkeepAccessibilityAudit scheme (SeedkeepUITests only) on
# one iPhone simulator, serially, with its own DerivedData and a result bundle per run under ${TMPDIR}.
#
# Usage: scripts/a11y-audit.sh <simulator UDID>
#
# Skips SeedkeepUITests/R3ScreenshotTests and SeedkeepUITests/R4ScreenshotTests, which scripts/r3-screenshots.sh
# and scripts/r4-screenshots.sh run.
#
# Fails on: zero tests, any skipped test, a missing configuration, an audit execution error, a timeout,
# or any finding not in SeedkeepUITests/AuditAllowlist.swift.
#
# Budget (measured 2026-10-21, Xcode 27.1, "Seedkeep iPhone" simulator, Apple-silicon Mac): one configuration
# alone took 392 s (light-default) and 437 s (dark-axxxl); the 4-configuration run took 1776 s of testing
# (375-503 s per configuration) plus about 3 min for a clean build. Each test is allowed 900 s and the
# whole run 3600 s, about twice the measured times.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Whole-run watchdog and per-test allowance, in seconds (see the budget note above).
RUN_BUDGET_SECONDS=3600
TEST_ALLOWANCE_SECONDS=900
CONFIGS="light-default:testLightDefault dark-default:testDarkDefault light-axxxl:testLightAccessibilityXXXL dark-axxxl:testDarkAccessibilityXXXL"

fail() {
    echo "[a11y-audit] ERROR: $*" >&2
    exit 1
}

[[ $# -eq 1 && -n "$1" ]] || fail "usage: scripts/a11y-audit.sh <simulator UDID> (required; there is no default simulator)"
SIM_UDID="$1"

DEVELOPER_DIR="$(bash "$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh" "${DEVELOPER_DIR:-}")"
export DEVELOPER_DIR

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/seedkeep-a11y-audit/$RUN_ID"
mkdir -p "$WORK_DIR"
DERIVED_DATA="$WORK_DIR/DerivedData"
RESULT_BUNDLE="$WORK_DIR/SeedkeepAccessibilityAudit.xcresult"
LOG="$WORK_DIR/xcodebuild.log"

echo "[a11y-audit] Date: $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
echo "[a11y-audit] Time zone: $(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo unknown)"
echo "[a11y-audit] Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "[a11y-audit] Simulator: $SIM_UDID"
echo "[a11y-audit] Work dir: $WORK_DIR"

if ! xcrun simctl list devices available | grep -Fq "($SIM_UDID)"; then
    fail "simulator $SIM_UDID is not available"
fi
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true

cd "$REPO_ROOT"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required to generate Seedkeep.xcodeproj"
echo "[a11y-audit] Generating Xcode project"
xcodegen generate >/dev/null

START_SECONDS=$SECONDS
set +e
# Job control gives xcodebuild its own process group (its pid), so stopping the group reaches every
# descendant, including any that outlive xcodebuild itself.
set -m
xcodebuild \
    -project "$REPO_ROOT/Seedkeep.xcodeproj" \
    -scheme SeedkeepAccessibilityAudit \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -skip-testing:SeedkeepUITests/R3ScreenshotTests \
    -skip-testing:SeedkeepUITests/R4ScreenshotTests \
    -parallel-testing-enabled NO \
    -disable-concurrent-destination-testing \
    -collect-test-diagnostics never \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$TEST_ALLOWANCE_SECONDS" \
    -maximum-test-execution-time-allowance "$TEST_ALLOWANCE_SECONDS" \
    CODE_SIGNING_ALLOWED=NO \
    test >"$LOG" 2>&1 &
XCODEBUILD_PID=$!
set +m

# Stop xcodebuild's whole process group: TERM, a bounded grace period while any member remains,
# then KILL.
stop_run() {
    kill -TERM -- "-$XCODEBUILD_PID" 2>/dev/null
    local waited=0
    while pgrep -g "$XCODEBUILD_PID" >/dev/null 2>&1 && (( waited < 30 )); do
        sleep 1
        waited=$((waited + 1))
    done
    kill -KILL -- "-$XCODEBUILD_PID" 2>/dev/null
}
trap 'stop_run; exit 130' INT TERM

# The watchdog polls in this shell, so a run that finishes normally can never be reported as a
# timeout, and a run past the budget is always stopped within the grace period.
TIMED_OUT=0
DEADLINE=$((SECONDS + RUN_BUDGET_SECONDS))
while kill -0 "$XCODEBUILD_PID" 2>/dev/null; do
    if (( SECONDS >= DEADLINE )); then
        TIMED_OUT=1
        stop_run
        break
    fi
    sleep 5
done
wait "$XCODEBUILD_PID"
STATUS=$?
trap - INT TERM
set -e
ELAPSED=$((SECONDS - START_SECONDS))

PROBLEMS=()

echo
echo "[a11y-audit] Per-configuration summary"
for pair in $CONFIGS; do
    config="${pair%%:*}"
    method="${pair##*:}"
    result="$(grep -Eo "Test Case '-\[SeedkeepUITests\.AccessibilityAuditTests $method\]' (passed|failed|skipped)( \([0-9.]+ seconds\))?" "$LOG" | tail -1 || true)"
    summary="$(grep -F "[a11y-audit] SUMMARY" "$LOG" | grep -F "config=$config" | tail -1 || true)"
    check="$(grep -F "[a11y-audit] CONFIG" "$LOG" | grep -F "config=$config" | tail -1 || true)"
    findings="$(grep -F "[a11y-audit] FINDING" "$LOG" | grep -cF "config=$config" || true)"
    echo "  $config ($method)"
    echo "    result:  ${result:-MISSING}"
    echo "    check:   ${check#\[a11y-audit\] }"
    echo "    summary: ${summary#\[a11y-audit\] }"
    echo "    unallowlisted findings: $findings"
    if [[ -z "$result" || -z "$summary" ]]; then
        PROBLEMS+=("configuration $config did not run")
    elif [[ "$result" != *passed* ]]; then
        PROBLEMS+=("configuration $config: ${result##*\' }")
    fi
done

EXECUTED="$(grep -Eo 'Executed [0-9]+ tests?' "$LOG" | tail -1 | grep -Eo '[0-9]+' || true)"
[[ -n "$EXECUTED" && "$EXECUTED" -gt 0 ]] || PROBLEMS+=("zero tests executed, or no test count reported")
if grep -Eq "Test Case .* skipped|[1-9][0-9]* tests? skipped|, [1-9][0-9]* skipped" "$LOG"; then
    PROBLEMS+=("a test was skipped")
fi
grep -qF "[a11y-audit] AUDIT-ERROR" "$LOG" && PROBLEMS+=("an audit failed to execute")
grep -qF "[a11y-audit] ABORT" "$LOG" && PROBLEMS+=("a configuration or destination aborted")
grep -qF "[a11y-audit] FINDING" "$LOG" && PROBLEMS+=("unallowlisted findings")
if (( TIMED_OUT )) || grep -Eqi "exceeded .*execution time allowance" "$LOG"; then
    PROBLEMS+=("timed out")
fi
[[ "$STATUS" -eq 0 ]] || PROBLEMS+=("xcodebuild exited with status $STATUS")

UNUSED="$(grep -cF "[a11y-audit] UNUSED-ALLOWLIST" "$LOG" || true)"
SUPPRESSED="$(grep -cF "[a11y-audit] SUPPRESSED" "$LOG" || true)"

echo
echo "[a11y-audit] Tests executed: ${EXECUTED:-0}; elapsed ${ELAPSED}s (budget ${RUN_BUDGET_SECONDS}s)"
echo "[a11y-audit] Suppressed by allowlist: $SUPPRESSED; unused allowlist entries reported: $UNUSED"
echo "[a11y-audit] Log: $LOG"
echo "[a11y-audit] Result bundle: $RESULT_BUNDLE"
if grep -qF "[a11y-audit] FINDING" "$LOG"; then
    echo "[a11y-audit] Findings:"
    grep -F "[a11y-audit] FINDING" "$LOG" | sed 's/^\[a11y-audit\] FINDING /  /'
fi

if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    for problem in "${PROBLEMS[@]}"; do
        echo "[a11y-audit] FAIL: $problem" >&2
    done
    exit 1
fi
echo "[a11y-audit] PASS: all 4 configurations ran with no unallowlisted findings"
