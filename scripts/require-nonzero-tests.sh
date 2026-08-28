#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "[test-gate] ERROR: usage: require-nonzero-tests.sh <label> <command> [args...]" >&2
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
if ! grep -Eq 'Executed [1-9][0-9]* tests?|with [1-9][0-9]* tests?' "$LOG"; then
    echo "[test-gate] ERROR: $LABEL executed zero tests or did not report a test count" >&2
    exit 1
fi
