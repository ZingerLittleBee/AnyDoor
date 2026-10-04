#!/usr/bin/env bash
# Sign an assembled AnyDoor.app depth-first (innermost code first), then verify.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/release/codesign.sh --app PATH --identity ID [--keychain PATH]

  --app PATH       The assembled AnyDoor.app (scripts/release/assemble.sh).
  --identity ID    Signing identity: the certificate's SHA-1 in CI, or `-` for
                   an ad-hoc signature (rehearsals; no secure timestamp and no
                   Team ID assertion).
  --keychain PATH  Only search this keychain for the identity.

A real identity signs with the hardened runtime and a secure timestamp, and the
result must carry TeamIdentifier APPLE_TEAM_ID (scripts/release/release.conf).
USAGE
}

APP=""
IDENTITY=""
KEYCHAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --app | --identity | --keychain)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
      case "$1" in
        --app) APP="$2" ;;
        --identity) IDENTITY="$2" ;;
        --keychain) KEYCHAIN="$2" ;;
      esac
      shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$APP" ]] || { usage >&2; die "--app is required"; }
[[ -n "$IDENTITY" ]] || { usage >&2; die "--identity is required"; }
[[ -d "$APP/Contents/MacOS" ]] || die "not an app bundle: $APP"
[[ -z "$KEYCHAIN" || -f "$KEYCHAIN" ]] || die "keychain does not exist: $KEYCHAIN"
APP="$(cd "$APP" && pwd)"

ENTITLEMENTS="$REPO_ROOT/Resources/AnyDoor.entitlements"
[[ -f "$ENTITLEMENTS" ]] || die "missing $ENTITLEMENTS"

ADHOC=0
SIGN_FLAGS=(--force --options=runtime)
if [[ "$IDENTITY" == "-" ]]; then
  ADHOC=1
else
  # Developer ID requires a secure timestamp; ad-hoc signatures cannot carry one.
  SIGN_FLAGS+=(--timestamp)
fi
if [[ -n "$KEYCHAIN" ]]; then
  SIGN_FLAGS+=(--keychain "$KEYCHAIN")
fi

SIGNED=()
# sign_code [codesign options...] PATH
sign_code() {
  local target="${!#}"
  log "Sign ${target#"${APP%/*}/"}"
  if ! codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$@"; then
    # A timestamp-server failure is transient: retry this one signature once
    # rather than the whole job.
    [[ "$ADHOC" -eq 0 ]] || die "codesign failed: $target"
    log "codesign failed for $target; retrying once"
    codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$@" || die "codesign failed twice: $target"
  fi
  SIGNED+=("$target")
}

log "Codesign Sparkle helpers (depth-first)"
FW_ROOT="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[[ -d "$FW_ROOT" ]] || die "missing $FW_ROOT; Sparkle's framework layout changed"
# XPC services first, then helper apps, then framework, then main binary, then bundle.
while IFS= read -r -d '' xpc; do
  sign_code "$xpc"
done < <(find "$FW_ROOT/XPCServices" -type d -name '*.xpc' -print0 2>/dev/null || true)

# Sparkle 2.x ships Autoupdate as a bare Mach-O alongside Updater.app; older
# versions wrapped it in Autoupdate.app. Sign whichever form is present so the
# notary sees the helper signed with our Developer ID + secure timestamp.
for helper in "$FW_ROOT/Autoupdate" "$FW_ROOT/Autoupdate.app" "$FW_ROOT/Updater.app"; do
  if [[ -e "$helper" ]]; then
    sign_code "$helper"
  fi
done

sign_code "$APP/Contents/Frameworks/Sparkle.framework"
sign_code "$APP/Contents/Frameworks/SQLCipher.framework"
sign_code "$APP/Contents/Resources/AnyDoor_AnyDoor.bundle"
sign_code "$APP/Contents/MacOS/AnyDoorHostsHelper"
# Under the hardened runtime an app may ask the user for Automation permission
# (Finder, System Events) only when its signature carries the Apple Events
# entitlement.
sign_code --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/AnyDoor"
sign_code --entitlements "$ENTITLEMENTS" "$APP"

log "Verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP"
signed_entitlements="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
[[ "$signed_entitlements" == *com.apple.security.automation.apple-events* ]] \
  || die "$APP is missing the Apple Events entitlement"
app_details="$(codesign -d --verbose=4 "$APP" 2>&1)"
grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$app_details" \
  || die "$APP is not signed with the hardened runtime"

if [[ "$ADHOC" -eq 1 ]]; then
  log "Ad-hoc signature verified (no Team ID to assert)"
  exit 0
fi

# HostsHelperListener's caller requirement pins the team, and library
# validation under the hardened runtime only loads frameworks signed by the
# same team, so every piece of code we signed must carry it.
TEAM_ID="$(release_conf APPLE_TEAM_ID)"
for code in "${SIGNED[@]}"; do
  team="$(codesign -d --verbose=4 "$code" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team" == "$TEAM_ID" ]] \
    || die "${code#"${APP%/*}/"} has TeamIdentifier '${team:-none}', expected $TEAM_ID"
done
log "Signed ${#SIGNED[@]} code objects with TeamIdentifier $TEAM_ID"
