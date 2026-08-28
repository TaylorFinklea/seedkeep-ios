#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COUNT_GATE="$REPO_ROOT/scripts/require-nonzero-tests.sh"

OUTPUT="$(bash "$COUNT_GATE" "XCTest fixture" bash -c \
    'printf "%s\n" "Executed 12 tests, with 0 failures"')" || {
    printf 'FAIL: a successful XCTest command with 12 tests was rejected\n%s\n' "$OUTPUT" >&2
    exit 1
}

printf 'PASS: nonzero XCTest output is accepted\n'

OUTPUT="$(bash "$COUNT_GATE" "Swift Testing fixture" bash -c \
    'printf "%s\n" "Test run with 146 tests in 5 suites passed after 1.0 seconds"')" || {
    printf 'FAIL: a successful Swift Testing command with 146 tests was rejected\n%s\n' "$OUTPUT" >&2
    exit 1
}

printf 'PASS: nonzero Swift Testing output is accepted\n'

if OUTPUT="$(bash "$COUNT_GATE" "zero-count fixture" bash -c \
    'printf "%s\n" "Executed 0 tests, with 0 failures"' 2>&1)"; then
    printf 'FAIL: a successful command reporting zero tests was accepted\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: zero-test output is rejected\n'

if OUTPUT="$(bash "$COUNT_GATE" "missing-count fixture" bash -c \
    'printf "%s\n" "Build succeeded without a test summary"' 2>&1)"; then
    printf 'FAIL: a successful command with no test count was accepted\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: missing test-count output is rejected\n'

if OUTPUT="$(bash "$COUNT_GATE" "failing-command fixture" bash -c \
    'printf "%s\n" "Executed 12 tests, with 0 failures"; exit 7' 2>&1)"; then
    printf 'FAIL: a command exiting nonzero was accepted because it printed a test count\n%s\n' "$OUTPUT" >&2
    exit 1
fi

printf 'PASS: command failure is rejected even with a nonzero test count\n'
