#!/usr/bin/env bash
# Install the local test app without replacing the daily app or its identity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  source "$ROOT/.env"
  set +a
fi
: "${DEV_SIGNING_IDENTITY:?Set DEV_SIGNING_IDENTITY to a stable local signing identity (see docs/development.md)}"
if [[ "$DEV_SIGNING_IDENTITY" == "-" ]] || ! security find-identity -v -p codesigning | grep -Fq -- "$DEV_SIGNING_IDENTITY"; then
  echo 'A valid signing certificate with its private key is required; ad-hoc signing is not supported.' >&2
  exit 1
fi

DEST='/Applications/AnyDoor Dev.app'
require_stopped() {
  if pgrep -f '^/Applications/AnyDoor Dev\.app/Contents/MacOS/AnyDoor([[:space:]]|$)' >/dev/null; then
    echo 'Quit AnyDoor Dev before installing. The daily AnyDoor may remain running.' >&2
    exit 1
  fi
}
require_stopped
if [[ -e "$DEST" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")" == 'dev.bybee.AnyDoor.Dev' ]] || {
    echo 'Refusing to replace a different app at the development path.' >&2
    exit 1
  }
fi

# Reuse the local assembler in an unregistered staging directory. The original
# application path is never passed to the recursive install target.
STAGE="$(mktemp -d /Applications/.anydoor-dev.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
make -C "$ROOT" install APP_DIR="$STAGE/AnyDoor.app" SIGNING_IDENTITY="$DEV_SIGNING_IDENTITY"
APP="$STAGE/AnyDoor.app"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.bybee.AnyDoor.Dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName AnyDoor Dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string AnyDoor Dev' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :NSAppleEventsUsageDescription AnyDoor Dev uses automation for system actions.' "$PLIST"
/usr/libexec/PlistBuddy -c 'Set :SUEnableAutomaticChecks false' "$PLIST"
for key in CFBundleURLTypes SUFeedURL SUPublicEDKey; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST"
done
# Dev uses the existing administrator-prompt fallback, never the daily app's
# registered daemon. It must not register the production URL scheme either.
rm -rf "$APP/Contents/Library/LaunchDaemons"
rm "$APP/Contents/MacOS/AnyDoorHostsHelper"
codesign --force --deep --sign "$DEV_SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

require_stopped
if [[ -e "$DEST" ]]; then
  # A changed signing identity must not silently invalidate Dev's own grants.
  requirement="$(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^designated => //p')"
  [[ -n "$requirement" ]] || { echo 'Cannot read the installed development signature.' >&2; exit 1; }
  codesign --verify --strict -R="$requirement" "$APP"
  mv "$DEST" "$STAGE/previous.app"
fi
if ! mv "$APP" "$DEST"; then
  if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$DEST"; fi
  exit 1
fi
touch "$DEST"
echo "Installed $DEST (separate data and permissions; automatic updates disabled)"
