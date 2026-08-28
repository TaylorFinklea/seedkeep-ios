#!/usr/bin/env bash
#
# release.sh — bump build, archive, and upload Seedkeep to TestFlight.
#
# Usage:
#   ./scripts/release.sh                # default: bump build only
#   ./scripts/release.sh --patch        # also bump patch (0.1.0 → 0.1.1)
#   ./scripts/release.sh --minor        # also bump minor (0.1.0 → 0.2.0)
#   ./scripts/release.sh --major        # also bump major (0.4.0 → 1.0.0)
#   ./scripts/release.sh --build        # explicit alias for default
#   ./scripts/release.sh --major --plan-version  # print the version plan only
#   ./scripts/release.sh --check-auth   # validate ASC auth without building/uploading
#
# Build-only bumps stay under the same App Store record and are right for
# routine TestFlight iteration. --patch / --minor / --major change the marketing version
# and trigger a fresh App Store review when the next build ships to App Store
# (not just TestFlight). Only use those when you intend to ship a release
# review.
#
# App Store Connect API credentials resolve from explicit IOS_RELEASE_* env
# overrides first, then these macOS Keychain services:
#   IOS_RELEASE_KEY_ID      — the App Store Connect API key ID
#   IOS_RELEASE_ISSUER_ID   — the App Store Connect issuer UUID
# Seed or rotate them with security add-generic-password -U -a "$USER" -s
# <service-name> -w '<value>'. Legacy ASC_API_KEY_ID/ASC_API_ISSUER_ID env
# overrides remain accepted for compatibility; no key ID or issuer is hardcoded.
#
# IOS_RELEASE_KEY_PATH (legacy ASC_API_KEY_PATH also accepted) can override the
# private key location. Otherwise the resolved key ID selects Apple's standard
# ~/.appstoreconnect/private_keys/AuthKey_<ID>.p8 path. The key must have the
# Admin role or cloud-managed-distribution permission: export/upload mints
# provisioning profiles via cloud signing and fails with 403 without it.
#
# Source of truth for build/version numbers is project.yml. The script bumps
# CURRENT_PROJECT_VERSION (and optionally MARKETING_VERSION), runs xcodegen,
# archives Release for generic iOS, exports + uploads via the API key, and
# commits the bump on success.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
step() { echo -e "\n${GREEN}▸ $1${NC}"; }
fail() { echo -e "${RED}✘ $1${NC}"; exit 1; }

# ---------- flags ----------
BUMP_TYPE="build"
SKIP_TESTS=false
SKIP_CHANGELOG=false
CHECK_AUTH=false
PLAN_VERSION=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUMP_TYPE="build"; shift ;;
        --patch) BUMP_TYPE="patch"; shift ;;
        --minor) BUMP_TYPE="minor"; shift ;;
        --major) BUMP_TYPE="major"; shift ;;
        --plan-version) PLAN_VERSION=true; shift ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --skip-changelog) SKIP_CHANGELOG=true; shift ;;
        --check-auth) CHECK_AUTH=true; shift ;;
        *) fail "Unknown flag: $1. Use --build, --patch, --minor, --major, --plan-version, --skip-tests, --skip-changelog, or --check-auth." ;;
    esac
done

load_version_plan() {
    PROJECT_YML="$REPO_ROOT/project.yml"
    OLD_BUILD=$(awk '/^[[:space:]]*CURRENT_PROJECT_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$PROJECT_YML")
    [[ -n "$OLD_BUILD" ]] || fail "Could not read CURRENT_PROJECT_VERSION from project.yml"

    OLD_VERSION=$(awk '/^[[:space:]]*MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' "$PROJECT_YML")
    [[ -n "$OLD_VERSION" ]] || fail "Could not read MARKETING_VERSION from project.yml"

    NEW_BUILD=$((OLD_BUILD + 1))
    NEW_VERSION="$OLD_VERSION"

    if [[ "$BUMP_TYPE" != "build" ]]; then
        IFS='.' read -ra PARTS <<< "$OLD_VERSION"
        MAJOR="${PARTS[0]:-0}"; MINOR="${PARTS[1]:-0}"; PATCH="${PARTS[2]:-0}"
        case "$BUMP_TYPE" in
            patch) NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))" ;;
            minor) NEW_VERSION="$MAJOR.$((MINOR + 1)).0" ;;
            major) NEW_VERSION="$((MAJOR + 1)).0.0" ;;
        esac
    fi
}

if [[ "$PLAN_VERSION" == "true" ]]; then
    load_version_plan
    printf '[release] version plan: %s (%s) -> %s (%s)\n' \
        "$OLD_VERSION" "$OLD_BUILD" "$NEW_VERSION" "$NEW_BUILD"
    exit 0
fi

# ---------- App Store Connect API key ----------
keychain_value() {
    security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true
}

ENV_KEY_ID="${IOS_RELEASE_KEY_ID:-${ASC_API_KEY_ID:-}}"
ENV_ISSUER_ID="${IOS_RELEASE_ISSUER_ID:-${ASC_API_ISSUER_ID:-}}"
ASC_KEY_ID="${ENV_KEY_ID:-$(keychain_value IOS_RELEASE_KEY_ID)}"
ASC_ISSUER="${ENV_ISSUER_ID:-$(keychain_value IOS_RELEASE_ISSUER_ID)}"

if [[ -z "$ASC_KEY_ID" || -z "$ASC_ISSUER" ]]; then
    fail "Missing App Store Connect credentials. Set IOS_RELEASE_KEY_ID and IOS_RELEASE_ISSUER_ID, or store them in Keychain services IOS_RELEASE_KEY_ID and IOS_RELEASE_ISSUER_ID."
fi

DEFAULT_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
ASC_KEY_PATH="${IOS_RELEASE_KEY_PATH:-${ASC_API_KEY_PATH:-$DEFAULT_KEY_PATH}}"

# ---------- Xcode toolchain ----------
DEVELOPER_DIR="$(bash "$REPO_ROOT/scripts/resolve-xcode-developer-dir.sh" "${DEVELOPER_DIR:-}")"
export DEVELOPER_DIR

[[ -f "$ASC_KEY_PATH" ]] || fail "ASC API key file is missing. Set IOS_RELEASE_KEY_PATH (or ASC_API_KEY_PATH) to an existing .p8 file; the default uses AuthKey_<resolved-key-id>.p8 in Apple's standard private_keys directory."

if [[ "$CHECK_AUTH" == "true" ]]; then
    echo "[release] App Store Connect credentials and Xcode toolchain are configured"
    exit 0
fi

# ---------- dirty tree check (before any version mutation) ----------
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "Working tree is dirty. Commit or stash changes before releasing."
fi
if ! working_tree_status="$(git status --porcelain --untracked-files=all)"; then
    fail "Could not inspect working tree. Refusing to release."
fi
if [[ -n "$working_tree_status" ]]; then
    fail "Working tree is dirty. Commit or stash changes before releasing."
fi

# ---------- resolve version plan ----------
load_version_plan

# ---------- changelog authoring gate (fail-closed) ----------
CHANGELOG_FILE="$REPO_ROOT/Seedkeep/Core/Changelog/ChangelogData.swift"
if [[ "$SKIP_CHANGELOG" == "false" ]]; then
    [[ -f "$CHANGELOG_FILE" ]] || fail "Changelog file not found at $CHANGELOG_FILE"
    if ! grep -Eq "build:[[:space:]]*${NEW_BUILD}([^0-9]|\$)" "$CHANGELOG_FILE"; then
        fail "No changelog entry for build ${NEW_BUILD}. Add a ChangelogRelease with 'build: ${NEW_BUILD}' to ChangelogData.swift, or pass --skip-changelog for a throwaway diagnostic build."
    fi
    echo "[release] changelog entry for build ${NEW_BUILD} present"
else
    echo "[release] WARNING: skipping changelog gate (--skip-changelog)"
fi

# ---------- run tests before mutating anything ----------
if [[ "$SKIP_TESTS" == "false" ]]; then
    step "Running release-quality test gate"
    "$REPO_ROOT/scripts/test-gate.sh"
else
    echo "[release] WARNING: skipping tests (--skip-tests)"
fi

step "Bumping version ($BUMP_TYPE)"
echo "  $OLD_VERSION ($OLD_BUILD) → $NEW_VERSION ($NEW_BUILD)"

# In-place sed (BSD sed quirks: -i needs ''). Anchor on the leading whitespace
# so we don't accidentally rewrite anything else. Values are quoted in
# project.yml (e.g. CURRENT_PROJECT_VERSION: "2") — preserve the quotes.
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]+)\"${OLD_BUILD}\"\$/\\1\"${NEW_BUILD}\"/" "$PROJECT_YML"
if [[ "$NEW_VERSION" != "$OLD_VERSION" ]]; then
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]+)\"${OLD_VERSION}\"\$/\\1\"${NEW_VERSION}\"/" "$PROJECT_YML"
fi

# ---------- regenerate Xcode project ----------
step "Regenerating Xcode project"
xcodegen generate >/dev/null

# ---------- archive ----------
ARCHIVE_PATH="/tmp/Seedkeep-build${NEW_BUILD}.xcarchive"
EXPORT_PATH="/tmp/Seedkeep-build${NEW_BUILD}-export"
PROJECT="$REPO_ROOT/Seedkeep.xcodeproj"
SCHEME="Seedkeep"
EXPORT_OPTIONS="$REPO_ROOT/Seedkeep/ExportOptions.plist"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

step "Archiving Release for generic iOS"
# Auth keys let -allowProvisioningUpdates regenerate the profile without a signed-in Xcode account.
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER" \
    archive 2>&1 | grep -E "Archive Succeeded|error:|\*\*" | head -5

[[ -d "$ARCHIVE_PATH" ]] || fail "Archive failed — $ARCHIVE_PATH not created"

step "Verifying archived app identity and entitlements"
"$REPO_ROOT/scripts/verify-release-archive.sh" "$ARCHIVE_PATH" "$NEW_VERSION" "$NEW_BUILD"

# ---------- export + upload ----------
step "Exporting and uploading to TestFlight"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER" 2>&1 | tee /tmp/seedkeep-export.log | grep -E "Export Succeeded|EXPORT SUCCEEDED|error:|\*\*" | head -10

if ! grep -q "EXPORT SUCCEEDED" /tmp/seedkeep-export.log; then
    fail "Export failed — see /tmp/seedkeep-export.log"
fi

# ---------- commit version bump ----------
step "Committing version bump"
git add project.yml
git commit -m "Release $NEW_VERSION (build $NEW_BUILD) to TestFlight"

echo -e "\n${GREEN}✔ Seedkeep $NEW_VERSION (build $NEW_BUILD) uploaded to TestFlight${NC}"
echo "  Check App Store Connect for processing status."
