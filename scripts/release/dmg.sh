#!/usr/bin/env bash
# Build the AnyDoor DMG with dmgbuild, check its layout, and optionally sign it.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --app PATH --out PATH --volname NAME [--identity ID] [--keychain PATH]

Builds a UDZO/HFS+ disk image holding the app and an Applications symlink with
the shipped Finder layout (dmg_settings.py), without Finder or AppleScript.
Then runs check_dmg_layout.py (layout, contents, app bundle identical to PATH)
and \`hdiutil verify\`. OUT is replaced only after every step succeeded.

  --app PATH       the $(release_conf APP_NAME).app bundle to package
  --out PATH       disk image to write (must end in .dmg)
  --volname NAME   volume name, e.g. "AnyDoor 4.2.8"
  --identity ID    sign the image with this identity (SHA-1 or name);
                   "-" signs ad hoc (no timestamp, no Team ID check)
  --keychain PATH  keychain holding the identity (default: search list)
  -h, --help       show this help
EOF
}

app=""
out=""
volname=""
identity=""
keychain=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) [[ $# -ge 2 ]] || die "--app needs a value"; app="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || die "--out needs a value"; out="$2"; shift 2 ;;
    --volname) [[ $# -ge 2 ]] || die "--volname needs a value"; volname="$2"; shift 2 ;;
    --identity) [[ $# -ge 2 ]] || die "--identity needs a value"; identity="$2"; shift 2 ;;
    --keychain) [[ $# -ge 2 ]] || die "--keychain needs a value"; keychain="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$app" && -n "$out" && -n "$volname" ]] || { usage >&2; die "--app, --out and --volname are required"; }
if [[ -n "$keychain" && -z "$identity" ]]; then die "--keychain needs --identity"; fi
[[ -z "$keychain" || -f "$keychain" ]] || die "keychain not found: $keychain"

app_name="$(release_conf APP_NAME).app"
app="${app%/}"
[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || die "not an app bundle: $app"
[[ "$(basename "$app")" == "$app_name" ]] \
  || die "the app must be named $app_name (the DMG layout positions that name): $app"
[[ "$out" == *.dmg ]] || die "--out must end in .dmg: $out"
[[ "$volname" != */* ]] || die "--volname must not contain '/': $volname"
command -v uv >/dev/null 2>&1 || die "uv not found in PATH"

app="$(cd "$app" && pwd)"
mkdir -p "$(dirname "$out")"
out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

# Build next to OUT so the final mv is a same-volume rename and a failed run
# never leaves a half-made image at OUT.
work="$(mktemp -d "$(dirname "$out")/.dmg-build.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
image="$work/$(basename "$out")"

uv_run() { uv run --quiet --locked --project "$RELEASE_DIR" "$@"; }

log "dmgbuild $image ($volname)"
uv_run dmgbuild -s "$RELEASE_DIR/dmg_settings.py" -D "app=$app" "$volname" "$image"
[[ -f "$image" ]] || die "dmgbuild did not write $image"

log "Check DMG layout and contents"
uv_run python "$RELEASE_DIR/check_dmg_layout.py" --dmg "$image" --volname "$volname" --app "$app"

log "hdiutil verify"
hdiutil verify -quiet "$image" || die "hdiutil verify failed for $image"

if [[ -n "$identity" ]]; then
  sign_args=(--force --sign "$identity" --identifier "$(release_conf BUNDLE_ID).dmg")
  [[ "$identity" == "-" ]] || sign_args+=(--timestamp)
  [[ -z "$keychain" ]] || sign_args+=(--keychain "$keychain")
  log "codesign DMG (identity $identity)"
  codesign "${sign_args[@]}" "$image"
  codesign --verify --strict -vv "$image"
  if [[ "$identity" != "-" ]]; then
    team_id="$(codesign -dvv "$image" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    expected_team_id="$(release_conf APPLE_TEAM_ID)"
    [[ "$team_id" == "$expected_team_id" ]] \
      || die "DMG TeamIdentifier is '$team_id', expected $expected_team_id"
  fi
fi

mv -f "$image" "$out"
log "Wrote $out"
printf '%s\n' "$out"
