#!/usr/bin/env bash
# Assemble AnyDoor.app from the products of scripts/release/build.sh and assert
# the properties a release binary must have. Produces DIR/AnyDoor.app, unsigned.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/release/assemble.sh --out DIR [--bin-path PATH]

  --out DIR        Directory that receives AnyDoor.app (replaced if present).
  --bin-path PATH  SwiftPM release products directory. Defaults to
                   `swift build --show-bin-path -c release <release flags>`.

Prints the assembled app's path on stdout.
USAGE
}

OUT=""
BIN_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --out | --bin-path)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
      if [[ "$1" == "--out" ]]; then OUT="$2"; else BIN_PATH="$2"; fi
      shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$OUT" ]] || { usage >&2; die "--out is required"; }

release_require_darwin
release_build_flags
MIN_MACOS="$(release_conf MIN_MACOS)"
APP_NAME="$(release_conf APP_NAME)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
cd "$REPO_ROOT"

if [[ -z "$BIN_PATH" ]]; then
  BIN_PATH="$(swift build --show-bin-path -c release "${RELEASE_BUILD_FLAGS[@]}")"
fi
[[ -d "$BIN_PATH" ]] || die "release products directory does not exist: $BIN_PATH"
BIN_PATH="$(cd "$BIN_PATH" && pwd)"

APP="$OUT/$APP_NAME.app"
log "Assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

for executable in AnyDoor AnyDoorHostsHelper; do
  [[ -f "$BIN_PATH/$executable" ]] || die "missing $BIN_PATH/$executable; run scripts/release/build.sh first"
  cp "$BIN_PATH/$executable" "$APP/Contents/MacOS/$executable"
done
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp Resources/dev.bybee.AnyDoor.HostsHelper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Info.plist "$APP/Contents/Info.plist"

# SPM emits a per-target resource bundle for `.process("Resources")` (string
# catalogs etc.). Bundle.module's generated accessor looks for it next to the
# executable in Contents/Resources; without it the app fatalErrors at launch.
RESOURCE_BUNDLE="$BIN_PATH/AnyDoor_AnyDoor.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || die "missing resource bundle at $RESOURCE_BUNDLE"
ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/AnyDoor_AnyDoor.bundle"

SPARKLE_FW=""
for candidate in \
  "$BIN_PATH/Sparkle.framework" \
  "$BIN_PATH/PackageFrameworks/Sparkle.framework" \
  "$BIN_PATH/../PackageFrameworks/Sparkle.framework"; do
  if [[ -d "$candidate" ]]; then
    SPARKLE_FW="$candidate"
    break
  fi
done
[[ -n "$SPARKLE_FW" ]] || die "could not find Sparkle.framework under $BIN_PATH"
log "Sparkle.framework → $SPARKLE_FW"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"

SQLCIPHER_FW=""
for candidate in \
  "$BIN_PATH/SQLCipher.framework" \
  "$BIN_PATH/PackageFrameworks/SQLCipher.framework" \
  "$BIN_PATH/../PackageFrameworks/SQLCipher.framework" \
  ".build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework"; do
  if [[ -d "$candidate" ]]; then
    SQLCIPHER_FW="$candidate"
    break
  fi
done
[[ -n "$SQLCIPHER_FW" ]] || die "could not find SQLCipher.framework under $BIN_PATH"
log "SQLCipher.framework → $SQLCIPHER_FW"
ditto "$SQLCIPHER_FW" "$APP/Contents/Frameworks/SQLCipher.framework"

# SwiftPM doesn't know about app-bundle layout, so the built executable only
# has @loader_path on its rpath list. Add @executable_path/../Frameworks so
# dyld can resolve bundled frameworks from Contents/Frameworks at launch.
if ! otool -l "$APP/Contents/MacOS/AnyDoor" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AnyDoor"
fi

# SPM release Mach-Os still carry local and debug nlists (~half the fat
# executable). Strip the assembled copies after rpath is set and before
# codesign: strip invalidates any ad-hoc signature the linker wrote.
# -x keeps the global/undefined symbols dyld needs; -S drops debug nlists.
# Sparkle is a prebuilt release framework with nested helpers and is left
# alone.
log "Strip local and debug symbols"
for binary in \
  "$APP/Contents/MacOS/AnyDoor" \
  "$APP/Contents/MacOS/AnyDoorHostsHelper" \
  "$APP/Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher"; do
  [[ -f "$binary" ]] || die "missing $binary"
  before="$(stat -f%z "$binary")"
  strip -xS "$binary"
  after="$(stat -f%z "$binary")"
  log "$(basename "$binary"): $before → $after bytes"
done

log "Verify linkage, architectures, and LC_BUILD_VERSION"
otool -L "$APP/Contents/MacOS/AnyDoor" \
  | grep -q '@rpath/SQLCipher.framework/Versions/A/SQLCipher' \
  || die "AnyDoor is not bound to the bundled SQLCipher framework"
if otool -L "$APP/Contents/MacOS/AnyDoor" | grep -q '/usr/lib/libsqlite3'; then
  die "AnyDoor must not bind the system SQLite library"
fi
for binary in \
  "$APP/Contents/MacOS/AnyDoor" \
  "$APP/Contents/MacOS/AnyDoorHostsHelper" \
  "$APP/Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher"; do
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] \
    || die "$binary is not universal (found: $architectures)"
done

# Compare versions as X.Y.Z: otool and xcrun both drop a zero patch component.
normalize_version() {
  awk -F. '{ printf "%d.%d.%d\n", $1, $2, $3 }' <<<"$1"
}

# build_version_field BINARY ARCH FIELD: FIELD (platform, minos, sdk) of the
# arch slice's LC_BUILD_VERSION load command.
build_version_field() {
  otool -arch "$2" -l "$1" | awk -v field="$3" '
    $1 == "cmd" { in_build_version = ($2 == "LC_BUILD_VERSION") }
    in_build_version && $1 == field { print $2; exit }
  '
}

# The linker flags in release_build_flags must have landed in every slice we
# link ourselves (SQLCipher is prebuilt): minos MIN_MACOS keeps the supported
# floor honest, and the real SDK version keeps the modern macOS 26+ appearance.
expected_minos="$(normalize_version "$MIN_MACOS")"
expected_sdk="$(normalize_version "$MACOS_SDK_VERSION")"
for binary in "$APP/Contents/MacOS/AnyDoor" "$APP/Contents/MacOS/AnyDoorHostsHelper"; do
  for arch in $(lipo -archs "$binary"); do
    platform="$(build_version_field "$binary" "$arch" platform)"
    minos="$(build_version_field "$binary" "$arch" minos)"
    sdk="$(build_version_field "$binary" "$arch" sdk)"
    [[ -n "$minos" && -n "$sdk" ]] || die "$binary ($arch) has no LC_BUILD_VERSION load command"
    # platform 1 is PLATFORM_MACOS.
    [[ "$platform" == "1" || "$platform" == "MACOS" ]] \
      || die "$binary ($arch) LC_BUILD_VERSION platform is $platform, expected macOS"
    [[ "$(normalize_version "$minos")" == "$expected_minos" ]] \
      || die "$binary ($arch) LC_BUILD_VERSION minos is $minos, expected $MIN_MACOS"
    [[ "$(normalize_version "$sdk")" == "$expected_sdk" ]] \
      || die "$binary ($arch) LC_BUILD_VERSION sdk is $sdk, expected $MACOS_SDK_VERSION (xcrun --show-sdk-version)"
  done
done

log "Assembled $APP"
printf '%s\n' "$APP"
