#!/usr/bin/env bash
# Extend the seed appcast with one new release, sign the feed, and verify the
# result read-only. The Sparkle private key comes only from the environment
# and reaches the tools on stdin: never argv (process listings) or disk.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: SPARKLE_ED_PRIVATE_KEY=... scripts/release/appcast.sh
         --seed PATH --zip PATH --notes PATH --tools DIR --tag TAG
         --public-key B64 --out PATH [--repository OWNER/REPO]
         [--phased-rollout-interval SECONDS] [--critical-update-version V]

  --seed PATH        seed appcast from seed-feed.sh
  --zip PATH         the update archive; must be named <APP_NAME>-<version>.zip
  --notes PATH       Markdown release notes, embedded into the new item
  --tools DIR        directory with sign_update and generate_appcast
                     (from fetch-sparkle-tools.sh)
  --tag TAG          release tag vX.Y.Z or vX.Y.Z-beta.N
  --public-key B64   SUPublicEDKey the shipped app trusts; the private key
                     must match it
  --out PATH         where to write the signed appcast.xml
  --repository OWNER/REPO       Release repository (default: DEFAULT_REPOSITORY)
  --phased-rollout-interval N   seconds between Sparkle's rollout groups
  --critical-update-version V   X.Y.Z build version, or '*' for critical from
                                any version (empty values mean "not set")

Environment: SPARKLE_ED_PRIVATE_KEY, one line of base64 in Sparkle's
--ed-key-file format (generate_keys -x output).
EOF
}

SEED=""
ZIP=""
NOTES=""
TOOLS=""
TAG=""
PUBLIC_KEY=""
OUT=""
REPOSITORY=""
PHASED_ROLLOUT_INTERVAL=""
CRITICAL_UPDATE_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --seed|--zip|--notes|--tools|--tag|--public-key|--out|--repository|--phased-rollout-interval|--critical-update-version)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --seed) SEED="$2" ;;
        --zip) ZIP="$2" ;;
        --notes) NOTES="$2" ;;
        --tools) TOOLS="$2" ;;
        --tag) TAG="$2" ;;
        --public-key) PUBLIC_KEY="$2" ;;
        --out) OUT="$2" ;;
        --repository) REPOSITORY="$2" ;;
        --phased-rollout-interval) PHASED_ROLLOUT_INTERVAL="$2" ;;
        --critical-update-version) CRITICAL_UPDATE_VERSION="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

for required in SEED ZIP NOTES TOOLS TAG PUBLIC_KEY OUT; do
  [[ -n "${!required}" ]] || { usage >&2; die "missing required option for $required"; }
done
[[ -f "$SEED" ]] || die "seed not found: $SEED"
[[ -f "$ZIP" ]] || die "zip not found: $ZIP"
[[ -s "$NOTES" ]] || die "release notes missing or empty: $NOTES"
for tool in generate_appcast sign_update; do
  [[ -x "$TOOLS/$tool" ]] || die "missing $TOOLS/$tool; run scripts/release/fetch-sparkle-tools.sh"
done
TOOLS="$(cd "$TOOLS" && pwd)"
[[ -n "$REPOSITORY" ]] || REPOSITORY="$(release_conf DEFAULT_REPOSITORY)"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "--repository must be OWNER/REPO: $REPOSITORY"
[[ -z "$PHASED_ROLLOUT_INTERVAL" || "$PHASED_ROLLOUT_INTERVAL" =~ ^[1-9][0-9]*$ ]] \
  || die "--phased-rollout-interval must be a positive number of seconds: $PHASED_ROLLOUT_INTERVAL"
[[ -z "$CRITICAL_UPDATE_VERSION" || "$CRITICAL_UPDATE_VERSION" == "*" \
   || "$CRITICAL_UPDATE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || die "--critical-update-version must be X.Y.Z or '*': $CRITICAL_UPDATE_VERSION"
[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || die "SPARKLE_ED_PRIVATE_KEY is not set"
# Secrets stored from a key file keep its trailing newline; Sparkle reads one line.
PRIVATE_KEY="$SPARKLE_ED_PRIVATE_KEY"
PRIVATE_KEY="${PRIVATE_KEY#"${PRIVATE_KEY%%[![:space:]]*}"}"
PRIVATE_KEY="${PRIVATE_KEY%"${PRIVATE_KEY##*[![:space:]]}"}"
[[ -n "$PRIVATE_KEY" && "$PRIVATE_KEY" != *[[:space:]]* ]] \
  || die "SPARKLE_ED_PRIVATE_KEY must be one line of base64"

APP_NAME="$(release_conf APP_NAME)"
MAX_VERSIONS="$(release_conf APPCAST_MAX_VERSIONS)"

release_py() { uv run --quiet --locked --project "$RELEASE_DIR" python "$@"; }
sha256_of() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

# Identity: tag, version, channel, short_version, build_version, display_version.
IDENTITY="$(python3 "$RELEASE_DIR/meta.py" identity --tag "$TAG")" || die "invalid release tag: $TAG"
identity() { printf '%s\n' "$IDENTITY" | sed -n "s/^$1=//p"; }
VERSION="$(identity version)"
CHANNEL="$(identity channel)"
SHORT_VERSION="$(identity short_version)"
BUILD_VERSION="$(identity build_version)"
DISPLAY_VERSION="$(identity display_version)"
[[ -n "$VERSION" && -n "$CHANNEL" && -n "$BUILD_VERSION" && -n "$DISPLAY_VERSION" ]] \
  || die "meta.py identity returned an incomplete identity for $TAG"

ZIP_NAME="$APP_NAME-$VERSION.zip"
[[ "$(basename "$ZIP")" == "$ZIP_NAME" ]] \
  || die "zip must be named $ZIP_NAME (its Release asset name), got $(basename "$ZIP")"

# A mismatched key would make generate_appcast skip signing with only a warning.
secret_public_key="$(printf '%s\n' "$PRIVATE_KEY" | release_py "$RELEASE_DIR/sparkle_keys.py" public-key)" \
  || die "SPARKLE_ED_PRIVATE_KEY is not a valid Sparkle EdDSA private key"
[[ "$secret_public_key" == "$PUBLIC_KEY" ]] \
  || die "SPARKLE_ED_PRIVATE_KEY's public key ($secret_public_key) does not match --public-key ($PUBLIC_KEY)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anydoor-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FEED="$WORK/appcast.xml"
cp "$SEED" "$FEED"
cp "$ZIP" "$WORK/$ZIP_NAME"
# generate_appcast pairs release notes with the archive by basename.
cp "$NOTES" "$WORK/$APP_NAME-$VERSION.md"

# '--ed-key-file -' reads stdin only when no file named '-' exists in the
# working directory (sign_update/main.swift:56, generate_appcast/main.swift:295),
# so both tools run from the fresh $WORK after checking for one.
with_key_on_stdin() {
  [[ ! -e "$WORK/-" ]] || die "refusing to run $1: $WORK contains a file named '-'"
  (cd "$WORK" && printf '%s\n' "$PRIVATE_KEY" | "$@" >&2)
}

APPCAST_ARGS=(
  --ed-key-file -
  --maximum-deltas 0
  --maximum-versions "$MAX_VERSIONS"
  --versions "$BUILD_VERSION"
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/"
  --link "https://github.com/$REPOSITORY"
  --embed-release-notes
  -o "$FEED"
)
[[ "$CHANNEL" != "beta" ]] || APPCAST_ARGS+=(--channel beta)
[[ -z "$PHASED_ROLLOUT_INTERVAL" ]] || APPCAST_ARGS+=(--phased-rollout-interval "$PHASED_ROLLOUT_INTERVAL")
if [[ "$CRITICAL_UPDATE_VERSION" == "*" ]]; then
  # An empty argument marks the update critical from any version.
  APPCAST_ARGS+=(--critical-update-version "")
elif [[ -n "$CRITICAL_UPDATE_VERSION" ]]; then
  APPCAST_ARGS+=(--critical-update-version "$CRITICAL_UPDATE_VERSION")
fi

log "generate_appcast $BUILD_VERSION ($CHANNEL) from seed $SEED"
with_key_on_stdin "$TOOLS/generate_appcast" "${APPCAST_ARGS[@]}" "$WORK" \
  || die "generate_appcast failed"

# generate_appcast reads the Apple-compliant short version from the bundle.
# Give only the new item its human-facing display version.
python3 "$REPO_ROOT/scripts/set-appcast-display.py" \
  --appcast "$FEED" \
  --build-version "$BUILD_VERSION" \
  --display-version "$DISPLAY_VERSION"

# Sign the feed as the LAST write: sign_update strips any previous signature
# block, then appends a new one over the final bytes (Sparkle 2.9 signed feeds,
# common_cli/Signing.swift:85-99, sign_update/main.swift:237-251).
log "Sign appcast.xml"
with_key_on_stdin "$TOOLS/sign_update" --ed-key-file - "$FEED" \
  || die "sign_update failed to sign appcast.xml"
SIGNED_SHA256="$(sha256_of "$FEED")"

# Read-only checks from here on.
python3 "$REPO_ROOT/scripts/validate-appcast.py" \
  --appcast "$FEED" \
  --release-id "$VERSION" \
  --channel "$CHANNEL" \
  --short-version "$SHORT_VERSION" \
  --build-version "$BUILD_VERSION" \
  --display-version "$DISPLAY_VERSION" \
  --repository "$REPOSITORY" \
  || die "generated appcast failed validation"
python3 "$REPO_ROOT/scripts/verify-feed-publication.py" --live "$SEED" --candidate "$FEED" \
  || die "generated appcast would roll back a channel of the seed feed"
release_py "$RELEASE_DIR/verify_sparkle_signatures.py" \
  --appcast "$FEED" \
  --public-key "$PUBLIC_KEY" \
  --archive "$ZIP_NAME=$ZIP" \
  --require-feed-signature >&2 \
  || die "generated appcast failed Sparkle signature verification"

mkdir -p "$(dirname "$OUT")"
cp "$FEED" "$OUT"
[[ "$(sha256_of "$OUT")" == "$SIGNED_SHA256" ]] || die "appcast.xml changed after signing"
log "Signed appcast for $TAG ($DISPLAY_VERSION, build $BUILD_VERSION) → $OUT"
