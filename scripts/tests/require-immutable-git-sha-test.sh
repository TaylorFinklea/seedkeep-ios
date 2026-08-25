#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
validator="$script_dir/../require-immutable-git-sha.sh"

valid_sha="0123456789abcdef0123456789abcdef01234567"
bash "$validator" "$valid_sha" "SEEDKEEP_SCHEMA_REF"

for invalid_ref in main refs/heads/main 0123456789abcdef0123456789abcdef0123456 0123456789abcdef0123456789abcdef012345678; do
    if bash "$validator" "$invalid_ref" "SEEDKEEP_SCHEMA_REF" >/dev/null 2>&1; then
        echo "expected mutable or malformed ref to fail: $invalid_ref" >&2
        exit 1
    fi
done

if bash "$validator" >/dev/null 2>&1; then
    echo "expected missing ref to fail" >&2
    exit 1
fi
