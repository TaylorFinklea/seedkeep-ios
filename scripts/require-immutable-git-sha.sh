#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: scripts/require-immutable-git-sha.sh SHA [LABEL]" >&2
    exit 2
fi

ref="$1"
label="${2:-git ref}"

if [[ ! "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    echo "$label must be an exact 40-character lowercase commit SHA" >&2
    exit 1
fi

echo "$label is pinned to an immutable commit SHA"
