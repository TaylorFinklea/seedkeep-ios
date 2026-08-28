#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_YML="$REPO_ROOT/project.yml"
ENTITLEMENTS="$REPO_ROOT/Seedkeep/Seedkeep.entitlements"
APP_SOURCE="$REPO_ROOT/Seedkeep"

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

if rg -q '^[[:space:]]*aps-environment:' "$PROJECT_YML"; then
    fail 'project.yml still declares an APNs environment'
fi

if /usr/libexec/PlistBuddy -c 'Print :aps-environment' "$ENTITLEMENTS" >/dev/null 2>&1; then
    fail 'Seedkeep.entitlements still declares an APNs environment'
fi

rg -q '^[[:space:]]*com\.apple\.developer\.usernotifications\.time-sensitive:[[:space:]]*true$' \
    "$PROJECT_YML" || fail 'project.yml lost the time-sensitive local-notification entitlement'
rg -q '^[[:space:]]*com\.apple\.developer\.icloud-container-environment:[[:space:]]*Production$' \
    "$PROJECT_YML" || fail 'project.yml no longer targets Production CloudKit'

time_sensitive="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.usernotifications.time-sensitive' "$ENTITLEMENTS")"
[[ "$time_sensitive" == "true" ]] || fail 'generated entitlements lost time-sensitive notifications'

cloudkit_environment="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.icloud-container-environment' "$ENTITLEMENTS")"
[[ "$cloudkit_environment" == "Production" ]] || fail 'generated entitlements no longer target Production CloudKit'

if rg -n --glob '*.swift' \
    'registerForRemoteNotifications|didRegisterForRemoteNotifications|didFailToRegisterForRemoteNotifications' \
    "$APP_SOURCE" >/dev/null; then
    fail 'remote-notification registration was added without revisiting the APNs entitlement decision'
fi

plutil -lint "$ENTITLEMENTS" >/dev/null
printf 'PASS: release entitlements omit unused APNs while preserving local notifications and Production CloudKit\n'
