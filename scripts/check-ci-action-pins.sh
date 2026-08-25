#!/usr/bin/env bash

set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: scripts/check-ci-action-pins.sh WORKFLOW..." >&2
    exit 2
fi

status=0
external_count=0

for workflow in "$@"; do
    if [[ ! -f "$workflow" ]]; then
        echo "workflow does not exist: $workflow" >&2
        status=1
        continue
    fi

    line_number=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if [[ ! "$line" =~ ^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*(.+)$ ]]; then
            continue
        fi

        reference="${BASH_REMATCH[2]}"
        reference="${reference%%#*}"
        reference="${reference#"${reference%%[![:space:]]*}"}"
        reference="${reference%"${reference##*[![:space:]]}"}"
        if [[ ${#reference} -ge 2 ]]; then
            first_character="${reference:0:1}"
            last_character="${reference: -1}"
            if [[ "$first_character" == '"' && "$last_character" == '"' ]] ||
                [[ "$first_character" == "'" && "$last_character" == "'" ]]; then
                reference="${reference:1:${#reference}-2}"
            fi
        fi

        if [[ "$reference" == ./* || "$reference" == docker://* ]]; then
            continue
        fi

        external_count=$((external_count + 1))
        if [[ ! "$reference" =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]]; then
            echo "$workflow:$line_number external action must use a full lowercase commit SHA: $reference" >&2
            status=1
        fi
    done < "$workflow"
done

if [[ $status -ne 0 ]]; then
    exit "$status"
fi

echo "All $external_count external action reference(s) use full commit SHAs"
