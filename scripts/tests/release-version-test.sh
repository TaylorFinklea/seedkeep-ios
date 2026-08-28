#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release.sh"
TEST_ROOT="$(mktemp -d /private/tmp/seedkeep-release-version.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo/scripts"
cp "$RELEASE_SCRIPT" "$TEST_ROOT/repo/scripts/release.sh"
chmod +x "$TEST_ROOT/repo/scripts/release.sh"

cat > "$TEST_ROOT/repo/project.yml" <<'YAML'
settings:
  base:
    MARKETING_VERSION: "0.4.0"
    CURRENT_PROJECT_VERSION: "52"
YAML

CALL_LOG="$TEST_ROOT/calls.log"
for command in security git xcodegen xcodebuild; do
    cat > "$TEST_ROOT/bin/$command" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${RELEASE_VERSION_CALL_LOG:?}"
exit 90
STUB
    chmod +x "$TEST_ROOT/bin/$command"
done

project_before="$(shasum -a 256 "$TEST_ROOT/repo/project.yml" | awk '{print $1}')"

assert_plan() {
    local bump="$1"
    local expected="$2"
    local output

    output="$({
        PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
        RELEASE_VERSION_CALL_LOG="$CALL_LOG" \
        "$TEST_ROOT/repo/scripts/release.sh" "--$bump" --plan-version
    } 2>&1)" || {
        printf 'FAIL: %s version plan failed\n%s\n' "$bump" "$output" >&2
        exit 1
    }

    if [[ "$output" != *"0.4.0 (52) -> $expected (53)"* ]]; then
        printf 'FAIL: %s version plan was unexpected\n%s\n' "$bump" "$output" >&2
        exit 1
    fi
}

assert_plan build 0.4.0
assert_plan patch 0.4.1
assert_plan minor 0.5.0
assert_plan major 1.0.0

if [[ -s "$CALL_LOG" ]]; then
    printf 'FAIL: version planning invoked a forbidden external command\n' >&2
    sed -n '1,20p' "$CALL_LOG" >&2
    exit 1
fi

project_after="$(shasum -a 256 "$TEST_ROOT/repo/project.yml" | awk '{print $1}')"
if [[ "$project_after" != "$project_before" ]]; then
    printf 'FAIL: version planning mutated project.yml\n' >&2
    exit 1
fi

if output="$({
    PATH="$TEST_ROOT/bin:/usr/bin:/bin" \
    RELEASE_VERSION_CALL_LOG="$CALL_LOG" \
    "$TEST_ROOT/repo/scripts/release.sh" --future --plan-version
} 2>&1)"; then
    printf 'FAIL: unknown release flag unexpectedly passed\n' >&2
    exit 1
fi

if [[ "$output" != *"Unknown flag: --future"* ]]; then
    printf 'FAIL: unknown release flag did not fail with a useful error\n%s\n' "$output" >&2
    exit 1
fi

printf 'PASS: release version planning is deterministic, non-mutating, and side-effect free\n'
