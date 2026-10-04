#!/usr/bin/env bash
# Local end-to-end UNSIGNED release rehearsal on a Mac. Mirrors the
# release-build.yml `package-unsigned` job: no Developer ID, no notarization,
# no real Sparkle key, nothing published. The repository's Info.plist and
# CHANGELOG.md are only read; the rehearsal identity is written into the
# assembled app copy.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/rehearse.sh [--skip-build] [--out DIR]

Rehearse the release pipeline locally without secrets: build, assemble, ad-hoc
sign, zip, DMG, plugin packages, and a Sparkle appcast signed with a throwaway
key, using the next Beta identity (X.Y.(Z+1)-beta.1 after Info.plist and
every published release).

Options:
  --skip-build  Reuse the existing universal release build in .build/.
  --out DIR     Artifact directory (default: .build/release-rehearsal). It is
                replaced on every run; a non-empty DIR that an earlier
                rehearsal did not create is refused.
  -h, --help    Show this help.

Requires macOS, uv, gh (authenticated), pnpm, and network access for the
Sparkle tools, the published appcast seed, and the live feed comparison.
EOF
}

skip_build=0
out_dir="$REPO_ROOT/.build/release-rehearsal"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) skip_build=1 ;;
    --out)
      [[ $# -ge 2 && -n "$2" ]] || die "--out requires a directory"
      out_dir="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "the rehearsal builds a macOS app and needs macOS"
for tool in uv gh pnpm python3 ditto xcrun /usr/libexec/PlistBuddy; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# The marker keeps `rm -rf` confined to directories this script created.
marker=".anydoor-release-rehearsal"
if [[ -e "$out_dir" ]]; then
  [[ -d "$out_dir" ]] || die "--out is not a directory: $out_dir"
  if [[ ! -f "$out_dir/$marker" && -n "$(ls -A "$out_dir")" ]]; then
    die "refusing to replace $out_dir: not empty and not created by a rehearsal"
  fi
  rm -rf "$out_dir"
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
touch "$out_dir/$marker"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/anydoor-rehearsal.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

repository="$(release_conf DEFAULT_REPOSITORY)"
app_name="$(release_conf APP_NAME)"

run_uv_python() {
  uv run --locked --project "$RELEASE_DIR" python "$@"
}

# meta_output FILE KEY: print KEY from meta.py's key=value output.
meta_output() {
  local value
  value="$(sed -n "s/^$2=//p" "$1" | tail -n 1)"
  [[ -n "$value" ]] || die "meta.py output has no $2 (see $1)"
  printf '%s\n' "$value"
}

# --- Rehearsal identity -----------------------------------------------------
# The same plan as release-rehearsal.yml: the first Beta after both Info.plist
# and every published release (during a Beta cycle main's Info.plist trails
# the Betas), checked by the monotonic gate, which also names the seed source:
# the most recently published Release of any channel.
gh release list --repo "$repository" --exclude-drafts --limit 200 \
  --json tagName,isPrerelease,publishedAt >"$work_dir/published.json"
python3 "$RELEASE_DIR/meta.py" rehearsal-identity --plist "$REPO_ROOT/Info.plist" \
  --published "$work_dir/published.json" >"$work_dir/identity.env"
tag="$(meta_output "$work_dir/identity.env" tag)"
version="$(meta_output "$work_dir/identity.env" version)"
display_version="$(meta_output "$work_dir/identity.env" display_version)"
log "Rehearsing $tag ($display_version) into $out_dir"

python3 "$RELEASE_DIR/meta.py" verify-monotonic --tag "$tag" \
  --published "$work_dir/published.json" >"$work_dir/monotonic.env"
previous_tag="$(meta_output "$work_dir/monotonic.env" previous_tag)"
log "Seed source: $previous_tag"

# Right after a release [Unreleased] is legitimately empty; that must not
# block rehearsing the packaging.
notes="$out_dir/release-notes.md"
python3 "$RELEASE_DIR/meta.py" notes --tag "$tag" \
  --changelog "$REPO_ROOT/CHANGELOG.md" --out "$notes" \
  --empty-placeholder '- Release rehearsal build.'

# --- Build and assemble ------------------------------------------------------
if [[ $skip_build -eq 1 ]]; then
  log "Skipping build; assembling from the existing release build"
else
  "$RELEASE_DIR/build.sh"
fi
"$RELEASE_DIR/assemble.sh" --out "$work_dir/assemble"
app="$out_dir/$app_name.app"
ditto "$work_dir/assemble/$app_name.app" "$app"
app_plist="$app/Contents/Info.plist"

# Rehearse the cut's version bump on the app copy, never on the repository.
PLIST="$app_plist" "$REPO_ROOT/scripts/bump-version.sh" "$version" >/dev/null

# --- Throwaway Sparkle key ---------------------------------------------------
# The real public key stays in the repository; the copy trusts a key that
# exists only for this run, so the rehearsal feed can never be replayed.
run_uv_python "$RELEASE_DIR/sparkle_keys.py" generate \
  --private-out "$work_dir/sparkle-private.key" \
  --public-out "$work_dir/sparkle-public.key"
public_key="$(tr -d '[:space:]' <"$work_dir/sparkle-public.key")"
[[ -n "$public_key" ]] || die "sparkle_keys.py wrote an empty public key"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" "$app_plist"

# --- Sign and package --------------------------------------------------------
"$RELEASE_DIR/codesign.sh" --app "$app" --identity -

zip="$out_dir/$app_name-$version.zip"
log "Package $zip"
ditto -c -k --keepParent "$app" "$zip"

dmg="$out_dir/$app_name-$version.dmg"
"$RELEASE_DIR/dmg.sh" --app "$app" --out "$dmg" --volname "$app_name $version"

"$RELEASE_DIR/package-plugins.sh" --out "$out_dir/plugins"

# --- Appcast -----------------------------------------------------------------
tools="$work_dir/sparkle-tools"
"$RELEASE_DIR/fetch-sparkle-tools.sh" --dest "$tools"

seed="$out_dir/seed-appcast.xml"
"$RELEASE_DIR/seed-feed.sh" --out "$seed" --mode rehearsal \
  --previous-tag "$previous_tag" --repository "$repository"

appcast="$out_dir/appcast.xml"
SPARKLE_ED_PRIVATE_KEY="$(cat "$work_dir/sparkle-private.key")" \
  "$RELEASE_DIR/appcast.sh" --seed "$seed" --zip "$zip" --notes "$notes" \
  --tools "$tools" --tag "$tag" --public-key "$public_key" --out "$appcast" \
  --repository "$repository"

printf '%s\n' "$public_key" >"$out_dir/rehearsal-public-key.txt"

log "Rehearsal $tag complete (unsigned, nothing published)"
printf '  %-14s %s\n' \
  "App" "$app" \
  "Sparkle zip" "$zip" \
  "DMG" "$dmg" \
  "Plugins" "$out_dir/plugins" \
  "Release notes" "$notes" \
  "Seed feed" "$seed" \
  "Appcast" "$appcast" \
  "Rehearsal key" "$out_dir/rehearsal-public-key.txt"
