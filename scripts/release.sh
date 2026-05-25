#!/usr/bin/env bash
# End-to-end release driver. Mirrors §6.3 of the design spec.
# Usage:
#   scripts/release.sh                     # patch+1
#   scripts/release.sh 1.2.3               # explicit version
#   DRYRUN=1 scripts/release.sh 1.2.3      # stop after appcast generation

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DRYRUN="${DRYRUN:-0}"
REQUESTED_VERSION="${1:-}"

# Configuration knobs
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AnyDoor-Notary}"
REPO_URL="${REPO_URL:-https://github.com/ZingerLittleBee/AnyDoor}"
DOWNLOAD_URL_BASE="$REPO_URL/releases/download"

DIST="$REPO_ROOT/dist"
ARCHIVE="$REPO_ROOT/scripts/release-archive"
SPARKLE_BIN="$REPO_ROOT/scripts/sparkle-bin"

log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# Track progress for the EXIT trap so we print actionable recovery
# instructions tailored to where the script failed.
LAST_STEP=0
RECOVERY_HINT=""

on_exit() {
    local code=$?
    if [[ $code -eq 0 ]]; then
        return
    fi
    printf '\033[1;31m✗\033[0m release.sh failed at step %s (exit %s)\n' "$LAST_STEP" "$code" >&2
    if [[ -n "$RECOVERY_HINT" ]]; then
        printf '\033[1;33m→\033[0m Recovery: %s\n' "$RECOVERY_HINT" >&2
    fi
}
trap on_exit EXIT

# --- 1. Preflight ---------------------------------------------------------
LAST_STEP=1
RECOVERY_HINT="nothing to undo; preflight aborted before any mutation"
log "Preflight checks"

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"
[[ "$(git branch --show-current)" == "main" ]] || die "must release from main"

git fetch origin --tags --quiet
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "local main is not in sync with origin/main"

grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md is missing '## [Unreleased]' section"
notes_body="$(awk '/^## \[Unreleased\]/{flag=1; next} /^## \[/{flag=0} flag' CHANGELOG.md | sed '/./,$!d')"
[[ -n "$notes_body" ]] || die "'## [Unreleased]' section is empty — write release notes first"

# Detect the placeholder EdDSA key from Chunk A. release.sh must never ship a
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

# --- 2. Resolve version --------------------------------------------------
LAST_STEP=2
RECOVERY_HINT="nothing to undo; version not yet written"
log "Resolve version"
VER="$(scripts/bump-version.sh "$REQUESTED_VERSION")"
log "VERSION → $VER"

git rev-parse "v$VER" >/dev/null 2>&1 && die "tag v$VER already exists locally"
git ls-remote --tags origin "v$VER" | grep -q . && die "tag v$VER already exists on origin"

# bump-version.sh wrote Info.plist. Stage the change in the working tree but
# don't commit yet; the commit happens after all artifacts are produced.

# --- 3. Mutate CHANGELOG and emit release notes --------------------------
LAST_STEP=3
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md"
log "Update CHANGELOG"
TODAY="$(date +%Y-%m-%d)"
python3 - "$VER" "$TODAY" <<'PY'
import re, sys, pathlib
ver, today = sys.argv[1], sys.argv[2]
path = pathlib.Path("CHANGELOG.md")
text = path.read_text()
text = re.sub(r"^## \[Unreleased\]", f"## [Unreleased]\n\n## [{ver}] - {today}", text, count=1, flags=re.MULTILINE)
path.write_text(text)
PY

mkdir -p "$DIST"
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
[[ -s "$DIST/release-notes.md" ]] || die "failed to extract release notes for $VER"

# --- 4. Build ------------------------------------------------------------
LAST_STEP=4
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
# Build a Universal Binary so a single artifact runs on both Apple Silicon
# and Intel Macs. The `swiftbuild` backend is required here: the default
# `native` backend dispatches multi-arch builds to xcbuild, which (as of
# Swift 6.3) fails to resolve our `XCStringsCompilerPlugin` build-tool
# plugin with "Unable to resolve build file ... PACKAGE-TARGET" errors.
# Sparkle.framework is taken from the matching macos-arm64_x86_64 slice of
# Sparkle.xcframework.
BUILD_FLAGS=(--build-system swiftbuild --arch arm64 --arch x86_64)
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

# SwiftPM doesn't know about app-bundle layout, so the built executable only
# has @loader_path on its rpath list. Add @executable_path/../Frameworks so
# dyld can resolve Sparkle from Contents/Frameworks at launch.
if ! otool -l "$APP/Contents/MacOS/AnyDoor" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AnyDoor"
fi

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
codesign --force --options=runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP/Contents/Resources/AnyDoor_AnyDoor.bundle"
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
rm -f "$DMG"
create-dmg \
  --volname "AnyDoor $VER" \
  --window-size 540 320 \
  --icon-size 96 \
  --app-drop-link 380 170 \
  "$DMG" \
  "$APP"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

# --- 9. Sparkle EdDSA sign ----------------------------------------------
LAST_STEP=9
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Sparkle EdDSA sign"
ED_SIGNATURE_OUTPUT="$("$SPARKLE_BIN/sign_update" "$ZIP")"
log "→ $ED_SIGNATURE_OUTPUT"

# --- 10. Generate appcast -----------------------------------------------
LAST_STEP=10
RECOVERY_HINT="git checkout -- Info.plist CHANGELOG.md && rm -rf dist/"
log "Generate appcast.xml"
mkdir -p "$ARCHIVE"
cp "$ZIP" "$ARCHIVE/"
"$SPARKLE_BIN/generate_appcast" "$ARCHIVE" \
  --maximum-deltas 0 \
  --download-url-prefix "$DOWNLOAD_URL_BASE/" \
  --link "$REPO_URL"

APPCAST="$ARCHIVE/appcast.xml"
[[ -f "$APPCAST" ]] || die "generate_appcast did not produce $APPCAST"

# generate_appcast emits enclosure URLs like
#   <DOWNLOAD_URL_BASE>/<filename>
# We need <DOWNLOAD_URL_BASE>/v<version>/<filename> so each release's zip
# is fetched from its own version-tagged release page (not /latest/).
python3 - "$APPCAST" <<'PY'
import re, sys, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
def fix(m):
    url = m.group(1)
    fname = url.rsplit("/", 1)[-1]
    # AnyDoor-1.2.3.zip → v1.2.3
    ver_match = re.search(r"AnyDoor-(\d+\.\d+\.\d+)\.zip$", fname)
    if not ver_match:
        return m.group(0)
    ver = ver_match.group(1)
    base = url.rsplit("/", 1)[0]
    return f'url="{base}/v{ver}/{fname}"'
text = re.sub(r'url="([^"]+AnyDoor-\d+\.\d+\.\d+\.zip)"', fix, text)
path.write_text(text)
PY

# Inject release notes into this version's <description><![CDATA[…]]>
python3 - "$APPCAST" "$VER" "$DIST/release-notes.md" <<'PY'
import sys, pathlib, re
appcast = pathlib.Path(sys.argv[1])
ver = sys.argv[2]
notes = pathlib.Path(sys.argv[3]).read_text().strip()
text = appcast.read_text()
# Locate the item whose sparkle:shortVersionString matches ver, then either
# replace existing <description> or insert one before <enclosure>.
item_re = re.compile(
    r'(<item>.*?<sparkle:shortVersionString>' + re.escape(ver) +
    r'</sparkle:shortVersionString>.*?)(<enclosure )',
    re.DOTALL,
)
def repl(m):
    block = m.group(1)
    block = re.sub(r'<description>.*?</description>', '', block, flags=re.DOTALL)
    cdata = f'<description><![CDATA[\n{notes}\n]]></description>\n'
    return block + cdata + m.group(2)
new_text, count = item_re.subn(repl, text, count=1)
if count == 0:
    raise SystemExit(f"could not find item for version {ver} in appcast")
appcast.write_text(new_text)
PY

xmllint --noout "$APPCAST"

URL_RE='^https://github\.com/ZingerLittleBee/AnyDoor/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/AnyDoor-[0-9]+\.[0-9]+\.[0-9]+\.zip$'
while IFS= read -r url; do
  [[ "$url" =~ $URL_RE ]] || die "appcast enclosure URL fails version-pinning regex: $url"
done < <(grep -oE 'url="[^"]+AnyDoor-[^"]+\.zip"' "$APPCAST" | sed 's/^url="\(.*\)"$/\1/')

cp "$APPCAST" "$REPO_ROOT/appcast.xml"

if [[ "$DRYRUN" == "1" ]]; then
  log "Dry run: stopping before git commit / push / release."
  log "To reset working tree: git checkout -- Info.plist CHANGELOG.md && rm -f appcast.xml"
  exit 0
fi

# --- 11. Git commit + tag ------------------------------------------------
LAST_STEP=11
RECOVERY_HINT="git tag -d v\$VER (if the tag was created) && rm -rf dist/  # the commit is on main locally — keep it if you intend to retry from step 12"
log "git commit + tag"
git add Info.plist CHANGELOG.md appcast.xml
git commit -m "release: v$VER"
git tag "v$VER"

# --- 12. Push --------------------------------------------------------
LAST_STEP=12
RECOVERY_HINT="resolve git push failure (auth/conflict), then retry from step 12 (no local cleanup needed)"
log "git push (commit + tag)"
git push origin main
git push origin "v$VER"

# --- 13. Create draft release, upload assets, publish ------------------
LAST_STEP=13
RECOVERY_HINT="gh release delete v\$VER --yes  # the release was a draft, so no clients ever saw it"
log "gh release create v$VER (draft)"
gh release create "v$VER" \
  --draft \
  --title "AnyDoor $VER" \
  --notes-file "$DIST/release-notes.md" \
  "$DMG" "$ZIP" "$APPCAST"

log "Publish release"
gh release edit "v$VER" --draft=false

log "Done. v$VER published at $REPO_URL/releases/tag/v$VER"
