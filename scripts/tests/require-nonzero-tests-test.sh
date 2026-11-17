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

# App gates must discover both frameworks; package gates retain the default behavior.
OUTPUT="$(bash "$COUNT_GATE" --require-both-frameworks "both frameworks" bash -c \
    'printf "%s\n" "Executed 1 test, with 0 failures" "Test run with 15 tests in 1 suite passed"')" || {
    printf 'FAIL: mixed framework counts were rejected\n%s\n' "$OUTPUT" >&2; exit 1
}
printf 'PASS: both framework counts are accepted\n'

for fixture in xctest-only swift-only unrelated-count; do
    case "$fixture" in
        xctest-only) lines='printf "%s\n" "Executed 1 test, with 0 failures" "Test run with 0 tests in 0 suites passed"' ;;
        swift-only) lines='printf "%s\n" "Executed 0 tests, with 0 failures" "Test run with 15 tests in 1 suite passed"' ;;
        unrelated-count) lines='printf "%s\n" "Executed 1 test, with 0 failures" "Other output with 15 tests"' ;;
    esac
    if OUTPUT="$(bash "$COUNT_GATE" --require-both-frameworks "$fixture" bash -c "$lines" 2>&1)"; then
        printf 'FAIL: missing framework count accepted for %s\n%s\n' "$fixture" "$OUTPUT" >&2; exit 1
    fi
    printf 'PASS: missing framework count rejected for %s\n' "$fixture"
done

if OUTPUT="$(bash "$COUNT_GATE" --require-both-frameworks "failed mixed command" bash -c \
    'printf "%s\n" "Executed 1 test, with 0 failures" "Test run with 15 tests in 1 suite passed"; exit 7' 2>&1)"; then
    printf 'FAIL: failed mixed command was accepted\n%s\n' "$OUTPUT" >&2; exit 1
fi
printf 'PASS: failed mixed command is rejected\n'

OUTPUT="$(bash "$COUNT_GATE" "package Swift Testing" bash -c \
    'printf "%s\n" "Executed 0 tests, with 0 failures" "Test run with 25 tests in 4 suites passed"')" || {
    printf 'FAIL: default package count behavior changed\n%s\n' "$OUTPUT" >&2; exit 1
}
printf 'PASS: default mode accepts Swift Testing package counts\n'
