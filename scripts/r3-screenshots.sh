#!/usr/bin/env bash
# R3 Garden screenshots: runs SeedkeepUITests/R3ScreenshotTests on one iPhone simulator, serially, with its
# own DerivedData and a result bundle under ${TMPDIR}, then exports the screenshots it attached. It is not
# the accessibility audit (scripts/a11y-audit.sh skips these tests) and not the per-change gate.
#
# Usage: scripts/r3-screenshots.sh <simulator UDID>
#
# Each configuration (light-default, dark-default, light-axxxl, dark-axxxl) attaches one PNG per step, named
# <config>-<nn>-<step>; a step that could not reach its screen is suffixed "-unreached". The export runs even
# when the test run fails, so the screenshots of a partly failed walk are still there. The exit status is
# the test run's (or the export's), so a failed step is still reported as a failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Whole-run watchdog and per-test allowance, in seconds. Four short walks, so far below the audit's budget.
RUN_BUDGET_SECONDS=1800
TEST_ALLOWANCE_SECONDS=600

fail() {
    echo "[r3-screenshots] ERROR: $*" >&2
    exit 1
}

[[ $# -eq 1 && -n "$1" ]] || fail "usage: scripts/r3-screenshots.sh <simulator UDID> (required; there is no default simulator)"
SIM_UDID="$1"

DEVELOPER_DIR="$(bash "$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh" "${DEVELOPER_DIR:-}")"
export DEVELOPER_DIR

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
WORK_DIR="${TMPDIR:-/tmp}"
WORK_DIR="${WORK_DIR%/}/seedkeep-r3-screenshots/$RUN_ID"
mkdir -p "$WORK_DIR"
DERIVED_DATA="$WORK_DIR/DerivedData"
RESULT_BUNDLE="$WORK_DIR/R3Screenshots.xcresult"
EXPORT_DIR="$WORK_DIR/screenshots"
LOG="$WORK_DIR/xcodebuild.log"
EXPORT_LOG="$WORK_DIR/export.log"

echo "[r3-screenshots] Date: $(date '+%Y-%m-%d %H:%M:%S %Z (UTC%z)')"
echo "[r3-screenshots] Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "[r3-screenshots] Simulator: $SIM_UDID"
echo "[r3-screenshots] Work dir: $WORK_DIR"

if ! xcrun simctl list devices available | grep -Fq "($SIM_UDID)"; then
    fail "simulator $SIM_UDID is not available"
fi
xcrun simctl boot "$SIM_UDID" >/dev/null 2>&1 || true

cd "$REPO_ROOT"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required to generate Seedkeep.xcodeproj"
echo "[r3-screenshots] Generating Xcode project"
xcodegen generate >/dev/null

START_SECONDS=$SECONDS
set +e
# Job control gives xcodebuild its own process group (its pid), so stopping the group reaches every
# descendant, including any that outlive xcodebuild itself.
set -m
# The SeedkeepAccessibilityAudit scheme is the only one that includes the UI test bundle.
xcodebuild \
    -project "$REPO_ROOT/Seedkeep.xcodeproj" \
    -scheme SeedkeepAccessibilityAudit \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIM_UDID" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -only-testing:SeedkeepUITests/R3ScreenshotTests \
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

# The watchdog polls in this shell, so a run that finishes normally can never be reported as a timeout.
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

echo
echo "[r3-screenshots] Test run: xcodebuild status $STATUS; elapsed ${ELAPSED}s (budget ${RUN_BUDGET_SECONDS}s)"
echo "[r3-screenshots] Log: $LOG"
if (( TIMED_OUT )); then
    echo "[r3-screenshots] FAIL: timed out after ${RUN_BUDGET_SECONDS}s" >&2
fi
grep -E "Executed [0-9]+ tests?" "$LOG" | tail -1 || true

if [[ ! -d "$RESULT_BUNDLE" ]]; then
    fail "no result bundle at $RESULT_BUNDLE (see $LOG)"
fi

echo "[r3-screenshots] Exporting attachments"
EXPORT_STATUS=0
xcrun xcresulttool export attachments --path "$RESULT_BUNDLE" --output-path "$EXPORT_DIR" >"$EXPORT_LOG" 2>&1 \
    || EXPORT_STATUS=$?
if (( EXPORT_STATUS != 0 )); then
    echo "[r3-screenshots] ERROR: xcresulttool export failed with status $EXPORT_STATUS (see $EXPORT_LOG)" >&2
fi

PNG_COUNT="$(find "$EXPORT_DIR" -name '*.png' 2>/dev/null | wc -l | tr -d ' ' || true)"
echo "[r3-screenshots] Screenshots exported: $PNG_COUNT PNG file(s)"
echo "[r3-screenshots] Output directory: $EXPORT_DIR"
echo "[r3-screenshots] Result bundle: $RESULT_BUNDLE"

if (( TIMED_OUT || STATUS != 0 || EXPORT_STATUS != 0 )); then
    echo "[r3-screenshots] FINISHED WITH FAILURES: see the log and the unreached or failed steps" >&2
    exit 1
fi
echo "[r3-screenshots] PASS: all steps ran and the screenshots were exported"
