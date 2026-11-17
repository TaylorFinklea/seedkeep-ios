#!/usr/bin/env bash

set -euo pipefail

REQUIRE_BOTH=false
if [[ "${1:-}" == "--require-both-frameworks" ]]; then
    REQUIRE_BOTH=true
    shift
fi

if [[ $# -lt 2 ]]; then
    echo "[test-gate] ERROR: usage: require-nonzero-tests.sh [--require-both-frameworks] <label> <command> [args...]" >&2
    exit 2
fi

LABEL="$1"
shift
LOG="$(mktemp "${TMPDIR:-/tmp}/seedkeep-test-gate.XXXXXX")"
trap 'rm -f "$LOG"' EXIT

echo "[test-gate] $LABEL"
set +e
"$@" 2>&1 | tee "$LOG"
STATUS="${PIPESTATUS[0]}"
set -e

if [[ "$STATUS" -ne 0 ]]; then
    echo "[test-gate] ERROR: $LABEL failed with exit status $STATUS" >&2
    exit 1
fi
if [[ "$REQUIRE_BOTH" == true ]]; then
    if ! grep -Eq 'Executed [1-9][0-9]* tests?' "$LOG" ||
       ! grep -Eq 'Test run with [1-9][0-9]* tests?' "$LOG"; then
        echo "[test-gate] ERROR: $LABEL must report nonzero XCTest and Swift Testing counts" >&2
        exit 1
    fi
elif ! grep -Eq 'Executed [1-9][0-9]* tests?|with [1-9][0-9]* tests?' "$LOG"; then
    echo "[test-gate] ERROR: $LABEL executed zero tests or did not report a test count" >&2
    exit 1
fi
