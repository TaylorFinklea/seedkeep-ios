#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
checker="$repo_root/scripts/check-ci-action-pins.sh"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/seedkeep-ci-action-pins-test.XXXXXX")"
trap 'rm -rf "$workspace"' EXIT

if [[ ! -f "$checker" ]]; then
    echo "CI action pin checker is missing: $checker" >&2
    exit 1
fi

safe_workflow="$workspace/safe.yml"
printf '%s\n' \
    'jobs:' \
    '  test:' \
    '    steps:' \
    '      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567 # v5' \
    '      - uses: "maxim-lobanov/setup-xcode@fedcba9876543210fedcba9876543210fedcba98"' \
    '      - uses: ./.github/actions/local' > "$safe_workflow"
bash "$checker" "$safe_workflow"

mutable_workflow="$workspace/mutable.yml"
printf '%s\n' \
    'jobs:' \
    '  test:' \
    '    steps:' \
    '      - uses: actions/checkout@v5' > "$mutable_workflow"
if mutable_output="$(bash "$checker" "$mutable_workflow" 2>&1)"; then
    echo "expected a mutable action tag to fail validation" >&2
    exit 1
fi
if [[ "$mutable_output" != *"actions/checkout@v5"* ]]; then
    echo "mutable action failure did not identify the rejected reference" >&2
    printf '%s\n' "$mutable_output" >&2
    exit 1
fi

short_sha_workflow="$workspace/short-sha.yml"
printf '%s\n' \
    'jobs:' \
    '  test:' \
    '    steps:' \
    '      - uses: actions/checkout@0123456' > "$short_sha_workflow"
if bash "$checker" "$short_sha_workflow" >/dev/null 2>&1; then
    echo "expected a short action SHA to fail validation" >&2
    exit 1
fi

bash "$checker" "$repo_root/.github/workflows/ci.yml"
