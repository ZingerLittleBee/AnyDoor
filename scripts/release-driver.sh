#!/usr/bin/env bash
# Internal end-to-end release driver. Invoke via release.sh or beta-release.sh.
# Usage:
#   RELEASE_CHANNEL=stable scripts/release-driver.sh [1.2.3]
#   RELEASE_CHANNEL=beta scripts/release-driver.sh 4.2.0-beta.1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/scripts/release-dryrun-state.sh"

DRYRUN="${DRYRUN:-0}"
REQUESTED_VERSION="${1:-}"
EXPECTED_CHANNEL="${RELEASE_CHANNEL:?release driver requires RELEASE_CHANNEL}"

# Configuration knobs
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AnyDoor-Notary}"
REPO_URL="${REPO_URL:-https://github.com/ZingerLittleBee/AnyDoor}"
DOWNLOAD_URL_BASE="$REPO_URL/releases/download"
CANONICAL_FEED_URL="${CANONICAL_FEED_URL:-https://anydoor.dev/appcast.xml}"

DIST="$REPO_ROOT/dist"
SPARKLE_BIN="$REPO_ROOT/scripts/sparkle-bin"

# Minimum macOS version stamped into the binary's LC_BUILD_VERSION `minos`
# field via the platform_version override in the build step. Must stay in sync
# with Package.swift's `.macOS` platform and Info.plist's LSMinimumSystemVersion;
# the preflight asserts all three agree.
MIN_MACOS="14.0"

log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

case "$EXPECTED_CHANNEL" in
  stable | beta) ;;
  *) die "unsupported release channel: $EXPECTED_CHANNEL" ;;
esac

# Track progress for the EXIT trap so we print actionable recovery
# instructions tailored to where the script failed.
LAST_STEP=0
RECOVERY_HINT=""
BASE_APPCAST=""
ARCHIVE=""
RELEASE_LOCK=""

on_exit() {
    local code=$?
    trap - EXIT
    set +e
    if [[ -n "$BASE_APPCAST" ]]; then
        rm -f "$BASE_APPCAST"
    fi
    if [[ -n "$ARCHIVE" && -d "$ARCHIVE" ]]; then
        rm -rf "$ARCHIVE"
    fi
    if [[ -n "$RELEASE_LOCK" && -d "$RELEASE_LOCK" ]]; then
        rmdir "$RELEASE_LOCK"
    fi
    if [[ -n "$RELEASE_DRYRUN_STATE" ]]; then
        if release_dryrun_restore "$REPO_ROOT"; then
            log "Dry-run working tree and release artifacts restored."
        else
            code=1
        fi
    fi
    if [[ $code -eq 0 ]]; then
        exit 0
    fi
    printf '\033[1;31m✗\033[0m release driver failed at step %s (exit %s)\n' "$LAST_STEP" "$code" >&2
    if [[ -n "$RECOVERY_HINT" ]]; then
        printf '\033[1;33m→\033[0m Recovery: %s\n' "$RECOVERY_HINT" >&2
    fi
    exit "$code"
}
trap on_exit EXIT

# Resolve the identity before preflight so branch policy is channel-aware.
if [[ -z "$REQUESTED_VERSION" ]]; then
    [[ "$EXPECTED_CHANNEL" == "stable" ]] \
      || die "Beta releases require an explicit X.Y.Z-beta.N version"
    current_short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
    IFS='.' read -r current_major current_minor current_patch <<<"$current_short"
    [[ -n "${current_patch:-}" ]] || die "current short version is not X.Y.Z: $current_short"
    REQUESTED_VERSION="$current_major.$current_minor.$((10#$current_patch + 1))"
fi
IFS=$'\t' read -r VER CHANNEL SHORT_VERSION BUILD_VERSION DISPLAY_VERSION \
    < <(scripts/resolve-release-version.sh "$REQUESTED_VERSION")
if [[ "$CHANNEL" != "$EXPECTED_CHANNEL" ]]; then
  if [[ "$EXPECTED_CHANNEL" == "stable" ]]; then
    die "$VER is a Beta identity; use 'make beta-release $VER'"
  fi
  die "$VER is a Stable identity; use 'make release $VER'"
fi
IFS='.' read -r RELEASE_MAJOR RELEASE_MINOR _ <<<"$SHORT_VERSION"
lock_path="$(git rev-parse --git-path anydoor-release.lock)"
mkdir "$lock_path" 2>/dev/null || die "another release process holds $lock_path"
RELEASE_LOCK="$lock_path"

# --- 1. Preflight ---------------------------------------------------------
LAST_STEP=1
RECOVERY_HINT="nothing to undo; preflight aborted before any mutation"
log "Preflight checks"

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
git fetch origin --tags --quiet
CURRENT_BRANCH="$(git branch --show-current)"
if [[ "$CHANNEL" == "stable" ]]; then
  [[ "$CURRENT_BRANCH" == "main" ]] || die "Stable releases must run from main"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "local main is not in sync with origin/main"
else
  EXPECTED_BRANCH="release/$RELEASE_MAJOR.$RELEASE_MINOR-beta"
  [[ "$CURRENT_BRANCH" == "$EXPECTED_BRANCH" ]] \
    || die "Beta $VER must run from $EXPECTED_BRANCH"
  git rev-parse "origin/$CURRENT_BRANCH" >/dev/null 2>&1 \
    || die "Beta branch has no remote tracking ref: origin/$CURRENT_BRANCH"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "origin/$CURRENT_BRANCH")" ]] \
    || die "local Beta branch is not in sync with origin/$CURRENT_BRANCH"
  latest_stable_tag="$(git tag --list 'v[0-9]*' --sort=-version:refname \
    | grep -Ev -- '-(beta|rc|alpha)\.' | head -n 1)"
  [[ -n "$latest_stable_tag" ]] || die "no Stable release tag found"
  git merge-base --is-ancestor "$latest_stable_tag" HEAD \
    || die "$CURRENT_BRANCH must contain latest Stable $latest_stable_tag before releasing Beta"
fi

grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md is missing '## [Unreleased]' section"
notes_body="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md | sed '/./,$!d')"
[[ -n "$notes_body" ]] || die "'## [Unreleased]' section is empty — write release notes first"

# Detect the placeholder EdDSA key from Chunk A. The release driver must never ship a
# build with the placeholder still in Info.plist; Sparkle would refuse every
# update on the client side.
pubkey="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Info.plist 2>/dev/null || true)"
[[ "$pubkey" != "PLACEHOLDER_REPLACE_WITH_GENERATE_KEYS_OUTPUT" ]] \
  || die "Info.plist SUPublicEDKey is still the placeholder — run scripts/sparkle-bin/generate_keys and paste the public key first"
[[ -n "$pubkey" ]] || die "Info.plist SUPublicEDKey is empty"

security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY" \
  || die "no codesigning identity matching '$SIGNING_IDENTITY' in login keychain"

for bin in sign_update generate_appcast; do
  [[ -x "$SPARKLE_BIN/$bin" ]] || die "missing $SPARKLE_BIN/$bin — run 'make sparkle-tools'"
done

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool keychain profile '$NOTARY_PROFILE' not configured"

gh auth status -h github.com >/dev/null 2>&1 || die "gh CLI is not authenticated"

command -v create-dmg >/dev/null 2>&1 \
  || die "create-dmg not found in PATH — run: brew install create-dmg"

command -v pnpm >/dev/null 2>&1 \
  || die "pnpm not found in PATH — required to build the example Script Plugin packages"

BASE_APPCAST="$(mktemp "${TMPDIR:-/tmp}/anydoor-appcast-base.XXXXXX")"
curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
  "$CANONICAL_FEED_URL" -o "$BASE_APPCAST" \
  || die "canonical feed is unavailable: $CANONICAL_FEED_URL"
xmllint --noout "$BASE_APPCAST"

# The build step force-overrides LC_BUILD_VERSION `minos` to MIN_MACOS via
# `-platform_version`. The linker applies that value unconditionally (only a
# warning if the compiled objects target a newer min), so a Package.swift
# platform bump would otherwise silently ship a binary claiming to support an
# older macOS than the code was built for. Assert the three min-OS declarations
# stay in lockstep so any bump must touch all of them together.
MIN_MACOS_MAJOR="${MIN_MACOS%%.*}"
grep -q "\.macOS(\.v${MIN_MACOS_MAJOR})" Package.swift \
  || die "Package.swift platform does not match MIN_MACOS ($MIN_MACOS) — update MIN_MACOS in scripts/release-driver.sh, Package.swift's .macOS(...), and Info.plist LSMinimumSystemVersion together"
plist_min="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist 2>/dev/null || true)"
[[ "$plist_min" == "$MIN_MACOS" ]] \
  || die "Info.plist LSMinimumSystemVersion ($plist_min) does not match MIN_MACOS ($MIN_MACOS) — update MIN_MACOS in scripts/release-driver.sh, Package.swift's .macOS(...), and Info.plist LSMinimumSystemVersion together"

if [[ "$DRYRUN" == "1" ]]; then
  release_dryrun_prepare "$REPO_ROOT" || die "could not prepare isolated dry-run state"
  DIST="$RELEASE_DRYRUN_DIST"
fi

# --- 2. Resolve version --------------------------------------------------
LAST_STEP=2
RECOVERY_HINT="nothing to undo; version not yet written"
log "Resolve version"
resolved="$(scripts/bump-version.sh "$VER")"
[[ "$resolved" == "$VER" ]] || die "version resolver drifted: expected $VER, got $resolved"
plist_short="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
plist_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)"
[[ "$plist_short" == "$SHORT_VERSION" && "$plist_build" == "$BUILD_VERSION" ]] \
  || die "Info.plist version mismatch after bump"
log "RELEASE → $VER ($CHANNEL, short $SHORT_VERSION, build $BUILD_VERSION)"

git rev-parse "v$VER" >/dev/null 2>&1 && die "tag v$VER already exists locally"
git ls-remote --tags origin "v$VER" | grep -q . && die "tag v$VER already exists on origin"

# bump-version.sh wrote Info.plist. Stage the change in the working tree but
# don't commit yet; the commit happens after all artifacts are produced.

# --- 3. Mutate CHANGELOG and emit release notes --------------------------
LAST_STEP=3
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md"
mkdir -p "$DIST"
if [[ "$CHANNEL" == "stable" ]]; then
  log "Cut CHANGELOG"
  TODAY="$(date +%Y-%m-%d)"
  python3 - "$VER" "$TODAY" <<'PY'
import re, sys, pathlib
ver, today = sys.argv[1], sys.argv[2]
path = pathlib.Path("CHANGELOG.md")
text = path.read_text()
text = re.sub(r"^## \[Unreleased\]", f"## [Unreleased]\n\n## [{ver}] - {today}", text, count=1, flags=re.MULTILINE)
path.write_text(text)
PY

  python3 - "$VER" <<'PY' > "$DIST/release-notes.md"
import re, sys, pathlib
ver = sys.argv[1]
text = pathlib.Path("CHANGELOG.md").read_text()
# Match the section header for the new version and capture body up to the next "## [".
pattern = r"^## \[" + re.escape(ver) + r"\] - \d{4}-\d{2}-\d{2}\s*\n(.*?)(?=^## \[|\Z)"
m = re.search(pattern, text, flags=re.MULTILINE | re.DOTALL)
if m is None:
    raise SystemExit(f"could not find section for {ver} in CHANGELOG.md")
print(m.group(1).strip())
PY
else
  log "Snapshot [Unreleased] notes without cutting CHANGELOG"
  printf '%s\n' "$notes_body" > "$DIST/release-notes.md"
fi
[[ -s "$DIST/release-notes.md" ]] || die "failed to extract release notes for $VER"

# --- 4. Build ------------------------------------------------------------
LAST_STEP=4
RECOVERY_HINT="git restore Info.plist CHANGELOG.md appcast.xml && rm -rf dist/"
# Build a Universal Binary so a single artifact runs on both Apple Silicon
# and Intel Macs. The `swiftbuild` backend is required here: the default
# `native` backend dispatches multi-arch builds to xcbuild, which (as of
# Swift 6.3) fails to resolve our `XCStringsCompilerPlugin` build-tool
# plugin with "Unable to resolve build file ... PACKAGE-TARGET" errors.
# Bundled frameworks are taken from their matching macos-arm64_x86_64 slices.
#
# The `swiftbuild` backend writes the deployment-target version (14.0) into
# the binary's LC_BUILD_VERSION `sdk` field instead of the real SDK version
# (the `native` backend writes the real SDK). On macOS 26 (Tahoe) the system
# gates the modern window appearance on the linked SDK version (>= 26): a
# 14.0 `sdk` field forces the app into the legacy, washed-out appearance.
# Override `platform_version` so the binary records minos MIN_MACOS (still runs
# on that macOS and later) but the real SDK version, restoring the intended
# appearance. The preflight guarantees MIN_MACOS matches Package.swift and
# Info.plist, so this override can't understate the supported minimum.
MACOS_SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx)"
BUILD_FLAGS=(--build-system swiftbuild --arch arm64 --arch x86_64
    -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$MACOS_SDK_VERSION")
log "swift build -c release (universal: arm64 + x86_64)"
swift build -c release "${BUILD_FLAGS[@]}"

# --- 5. Assemble .app ----------------------------------------------------
LAST_STEP=5
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Assemble dist/AnyDoor.app"
APP="$DIST/AnyDoor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

BIN_PATH="$(swift build --show-bin-path -c release "${BUILD_FLAGS[@]}")"
cp "$BIN_PATH/AnyDoor" "$APP/Contents/MacOS/AnyDoor"
cp "$BIN_PATH/AnyDoorHostsHelper" "$APP/Contents/MacOS/AnyDoorHostsHelper"
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

otool -L "$APP/Contents/MacOS/AnyDoor" \
  | grep -q '@rpath/SQLCipher.framework/Versions/A/SQLCipher' \
  || die "AnyDoor is not bound to the bundled SQLCipher framework"
if otool -L "$APP/Contents/MacOS/AnyDoor" | grep -q '/usr/lib/libsqlite3'; then
  die "AnyDoor must not bind the system SQLite library"
fi
for binary in \
  "$APP/Contents/MacOS/AnyDoor" \
  "$APP/Contents/Frameworks/SQLCipher.framework/Versions/A/SQLCipher"; do
  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] \
    || die "$binary is not universal (found: $architectures)"
done

# --- 6. Codesign (depth-first) -------------------------------------------
LAST_STEP=6
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Codesign Sparkle helpers (depth-first)"
FW_ROOT="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# XPC services first, then helper apps, then framework, then main binary, then bundle.
while IFS= read -r -d '' xpc; do
  codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$xpc"
done < <(find "$FW_ROOT/XPCServices" -type d -name '*.xpc' -print0 2>/dev/null || true)

# Sparkle 2.x ships Autoupdate as a bare Mach-O alongside Updater.app; older
# versions wrapped it in Autoupdate.app. Sign whichever form is present so the
# notary sees the helper signed with our Developer ID + secure timestamp.
for helper in "$FW_ROOT/Autoupdate" "$FW_ROOT/Autoupdate.app" "$FW_ROOT/Updater.app"; do
  [[ -e "$helper" ]] && codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$helper"
done

codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Frameworks/SQLCipher.framework"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/AnyDoor_AnyDoor.bundle"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/AnyDoorHostsHelper"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/MacOS/AnyDoor"
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"

log "Verify codesign"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- 7. Notarize .app ----------------------------------------------------
LAST_STEP=7
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Notarize .app"
ditto -c -k --keepParent "$APP" "$DIST/_notary.zip"
xcrun notarytool submit "$DIST/_notary.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/_notary.zip"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP"

# --- 8. Package final assets --------------------------------------------
LAST_STEP=8
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
ZIP="$DIST/AnyDoor-$VER.zip"
DMG="$DIST/AnyDoor-$VER.dmg"
log "Package $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "Package $DMG"
package_dmg() {
  rm -f "$DMG"
  create-dmg "$@" \
    --volname "AnyDoor $VER" \
    --window-size 540 320 \
    --icon-size 96 \
    --app-drop-link 380 170 \
    "$DMG" \
    "$APP"
}
# create-dmg's Finder-styling AppleScript fails intermittently (Finder error
# -10006). Retry once; if it still fails, drop the styling pass
# (--skip-jenkins) rather than kill the release after the .app has already
# been notarized — the DMG is merely less pretty.
package_dmg || package_dmg || package_dmg --skip-jenkins
codesign --force --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# Example Script Plugin packages. `pnpm verify` is the tooling gate and builds
# every example's dist/ in place as a side effect; each zip holds the package
# contents at its root (manifest.json + bundle.js), the layout Settings →
# Plugins expects after unzipping.
log "Package example Script Plugins (pnpm verify)"
(cd "$REPO_ROOT/tooling" && pnpm install --frozen-lockfile && pnpm verify)
PLUGIN_ZIPS=()
for example_dist in "$REPO_ROOT"/tooling/examples/*/dist; do
  [[ -f "$example_dist/manifest.json" ]] \
    || die "no manifest.json in $example_dist — pnpm verify should have built it"
  plugin_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$example_dist/manifest.json")"
  plugin_zip="$DIST/plugin-$plugin_id.zip"
  log "Package $plugin_zip"
  rm -f "$plugin_zip"
  # --norsrc/--noextattr keep AppleDouble (._*) sidecars out of the archive so
  # an unzipped package holds exactly manifest.json + bundle.js.
  ditto -c -k --norsrc --noextattr "$example_dist" "$plugin_zip"
  PLUGIN_ZIPS+=("$plugin_zip")
done
[[ ${#PLUGIN_ZIPS[@]} -gt 0 ]] || die "no example Script Plugins found under tooling/examples/"

# --- 9. Sparkle EdDSA sign ----------------------------------------------
LAST_STEP=9
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Sparkle EdDSA sign"
ED_SIGNATURE_OUTPUT="$("$SPARKLE_BIN/sign_update" "$ZIP")"
log "→ $ED_SIGNATURE_OUTPUT"

# --- 10. Generate appcast -----------------------------------------------
LAST_STEP=10
RECOVERY_HINT="git restore Info.plist CHANGELOG.md appcast.xml && rm -rf dist/"
log "Generate appcast.xml"
ARCHIVE="$(mktemp -d "${TMPDIR:-/tmp}/anydoor-appcast.XXXXXX")"
curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
  "$CANONICAL_FEED_URL" -o "$BASE_APPCAST" \
  || die "canonical feed is unavailable: $CANONICAL_FEED_URL"
xmllint --noout "$BASE_APPCAST"
cp "$BASE_APPCAST" "$ARCHIVE/appcast.xml"
cp "$ZIP" "$ARCHIVE/"
cp "$DIST/release-notes.md" "$ARCHIVE/AnyDoor-$VER.md"
APPCAST_ARGS=(
  --maximum-deltas 0
  --download-url-prefix "$DOWNLOAD_URL_BASE/v$VER/"
  --link "$REPO_URL"
  --versions "$BUILD_VERSION"
  --embed-release-notes
)
if [[ "$CHANNEL" == "beta" ]]; then
  APPCAST_ARGS+=(--channel beta)
fi
"$SPARKLE_BIN/generate_appcast" "$ARCHIVE" \
  "${APPCAST_ARGS[@]}"

APPCAST="$ARCHIVE/appcast.xml"
[[ -f "$APPCAST" ]] || die "generate_appcast did not produce $APPCAST"

# generate_appcast reads the Apple-compliant short version from the bundle.
# Give only the new item its human-facing Beta label.
scripts/set-appcast-display.py \
  --appcast "$APPCAST" \
  --build-version "$BUILD_VERSION" \
  --display-version "$DISPLAY_VERSION"

scripts/validate-appcast.py \
  --appcast "$APPCAST" \
  --release-id "$VER" \
  --channel "$CHANNEL" \
  --short-version "$SHORT_VERSION" \
  --build-version "$BUILD_VERSION" \
  --display-version "$DISPLAY_VERSION"

cp "$APPCAST" "$REPO_ROOT/appcast.xml"
rm -rf "$ARCHIVE"
ARCHIVE=""
APPCAST="$REPO_ROOT/appcast.xml"

if [[ "$DRYRUN" == "1" ]]; then
  log "Dry run: stopping before git commit / push / release."
  exit 0
fi

# --- 11. Git commit + tag ------------------------------------------------
LAST_STEP=11
RECOVERY_HINT="git tag -d v$VER (if the tag was created) && rm -rf dist/  # the commit is on $CURRENT_BRANCH locally — keep it if you intend to retry from step 12"
log "git commit + tag"
git add Info.plist appcast.xml
if [[ "$CHANNEL" == "stable" ]]; then
  git add CHANGELOG.md
fi
git commit -m "chore: release v$VER"
git tag "v$VER"

# --- 12. Push --------------------------------------------------------
LAST_STEP=12
RECOVERY_HINT="resolve git push failure (auth/conflict), then retry from step 12 (no local cleanup needed)"
log "git push (commit + tag)"
git push origin "$CURRENT_BRANCH"
git push origin "v$VER"

# --- 13. Create draft release, upload assets, publish ------------------
LAST_STEP=13
RECOVERY_HINT="gh release delete v$VER --yes  # the release was a draft, so no clients ever saw it"
log "gh release create v$VER (draft $CHANNEL)"
RELEASE_ARGS=(--draft --title "AnyDoor $DISPLAY_VERSION" --notes-file "$DIST/release-notes.md")
if [[ "$CHANNEL" == "beta" ]]; then
  RELEASE_ARGS+=(--prerelease)
fi
gh release create "v$VER" \
  "${RELEASE_ARGS[@]}" \
  "$DMG" "$ZIP" "$APPCAST" "${PLUGIN_ZIPS[@]}"

log "Publish release"
gh release edit "v$VER" --draft=false

log "Done. v$VER published at $REPO_URL/releases/tag/v$VER"
