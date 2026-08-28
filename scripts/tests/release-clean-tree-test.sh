#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_SCRIPT="$REPO_ROOT/scripts/release.sh"
TEST_ROOT="$(mktemp -d /private/tmp/seedkeep-release-clean-tree.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_repo() {
    local repo="$1"
    mkdir -p "$repo/scripts" "$repo/Seedkeep/Core/Changelog" "$repo/bin"
    cp "$RELEASE_SCRIPT" "$repo/scripts/release.sh"
    cp "$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh" "$repo/scripts/resolve-xcode-developer-dir.sh"
    cp "$REPO_ROOT/scripts/verify-release-archive.sh" "$repo/scripts/verify-release-archive.sh"
    chmod +x "$repo/scripts/release.sh" "$repo/scripts/resolve-xcode-developer-dir.sh" "$repo/scripts/verify-release-archive.sh"
    cat > "$repo/scripts/test-gate.sh" <<'TEST_GATE'
#!/usr/bin/env bash
set -euo pipefail
: > "${RELEASE_CLEAN_TREE_TEST_MARKER:?}"
TEST_GATE
    chmod +x "$repo/scripts/test-gate.sh"
    cat > "$repo/project.yml" <<'YAML'
settings:
  MARKETING_VERSION: "1.0.0"
  CURRENT_PROJECT_VERSION: "52"
YAML
    printf 'build: 53\n' > "$repo/Seedkeep/Core/Changelog/ChangelogData.swift"
    printf 'ignored.swift\nbin/\n' > "$repo/.gitignore"
    git -C "$repo" init -q
    git -C "$repo" config user.email fixture@example.com
    git -C "$repo" config user.name fixture
    git -C "$repo" add .
    git -C "$repo" commit -q -m baseline

}

repo="$TEST_ROOT/repo"
make_repo "$repo"

calls="$TEST_ROOT/calls.log"
touch "$TEST_ROOT/key.p8"
for command in xcodegen xcodebuild; do
    cat > "$repo/bin/$command" <<'COMMAND'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0")" >> "${RELEASE_CLEAN_TREE_TEST_CALLS:?}"
exit 91
COMMAND
    chmod +x "$repo/bin/$command"
done

before_version="$(shasum -a 256 "$repo/project.yml" | awk '{print $1}')"
printf 'untracked source\n' > "$repo/Untracked.swift"
if output="$({
    PATH="$repo/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    IOS_RELEASE_KEY_ID=fixture IOS_RELEASE_ISSUER_ID=fixture IOS_RELEASE_KEY_PATH="$TEST_ROOT/key.p8" \
    RELEASE_CLEAN_TREE_TEST_CALLS="$calls" \
    RELEASE_CLEAN_TREE_TEST_MARKER="$TEST_ROOT/test-gate-ran" \
    bash "$repo/scripts/release.sh" --skip-changelog --build
} 2>&1)"; then
    fail 'release accepted an untracked source file'
fi
if [[ "$output" != *'Working tree is dirty'* ]]; then
    fail "untracked source did not fail at the clean-tree gate: $output"
fi
[[ ! -e "$TEST_ROOT/test-gate-ran" ]] || fail 'untracked source reached the test gate'
[[ ! -s "$calls" ]] || fail 'untracked source reached archive or upload tooling'
after_version="$(shasum -a 256 "$repo/project.yml" | awk '{print $1}')"
[[ "$after_version" == "$before_version" ]] || fail 'untracked source mutated project.yml'

rm "$repo/Untracked.swift"
printf 'ignored source\n' > "$repo/ignored.swift"
if output="$({
    PATH="$repo/bin:/usr/bin:/bin" \
    HOME="$TEST_ROOT/home" \
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    IOS_RELEASE_KEY_ID=fixture IOS_RELEASE_ISSUER_ID=fixture IOS_RELEASE_KEY_PATH="$TEST_ROOT/key.p8" \
    RELEASE_CLEAN_TREE_TEST_CALLS="$calls" \
    RELEASE_CLEAN_TREE_TEST_MARKER="$TEST_ROOT/ignored-test-gate-ran" \
    bash "$repo/scripts/release.sh" --skip-tests --skip-changelog --build
} 2>&1)"; then
    fail 'release unexpectedly completed ignored-file fixture'
fi
if [[ "$output" == *'Working tree is dirty'* ]]; then
    fail "ignored file blocked the clean-tree gate: $output"
fi
grep -q '^xcodegen$' "$calls" || fail 'ignored file did not pass the clean-tree gate'

printf 'PASS: clean-tree gate blocks untracked source and permits ignored files\n'
