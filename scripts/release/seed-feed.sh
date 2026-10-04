#!/usr/bin/env bash
# Produce the seed appcast that generate_appcast extends. The seed is the
# previous published Release's appcast.xml asset (or, for the first migrated
# release, appcast.xml at a git revision), and in release mode it must
# byte-equal the live feed: anything else would publish a feed that silently
# drops or resurrects items.
#
# Equality alone does not authenticate the seed: a mutable Release asset and
# the live feed can both be replaced by anyone with repository write access,
# and appcast.sh re-signs every carried-over item with the real key. So the
# seed's own Sparkle feed signature must verify with the pinned public key.
# Only the old local flow's last feed (LEGACY_UNSIGNED_FEED_TAG, or --from-git)
# may be unsigned, and then every enclosure it lists is downloaded and its
# EdDSA signature and length verified instead.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/seed-feed.sh --out PATH --mode release|rehearsal
         [--previous-tag TAG | --from-git REV] [--public-key B64]
         [--repository OWNER/REPO]

Sources (pick one):
  --previous-tag TAG   the appcast.xml asset of published Release TAG
                       (gh release download; gh release verify-asset when the
                       Release is immutable)
  --from-git REV       appcast.xml at git revision REV (first migration only)

Modes:
  release     the seed must byte-equal the live feed (FEED_URL in release.conf)
              and be authenticated with --public-key (see below)
  rehearsal   a live mismatch or failed authentication is only a warning; with
              no source, or when TAG has no appcast.xml asset, the live feed
              itself becomes the seed

Authentication: the seed's Sparkle feed signature must verify with the public
key. An unsigned seed is accepted only from --from-git or from the Release
named by LEGACY_UNSIGNED_FEED_TAG in release.conf, after every enclosure is
downloaded and its sparkle:edSignature and length verify.

  --public-key B64          pinned SUPublicEDKey; required in release mode,
                            defaults to Info.plist's in rehearsal mode
  --repository OWNER/REPO   Release repository (default: DEFAULT_REPOSITORY)
EOF
}

OUT=""
MODE=""
PREVIOUS_TAG=""
FROM_GIT=""
PUBLIC_KEY=""
REPOSITORY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out|--mode|--previous-tag|--from-git|--public-key|--repository)
      [[ $# -ge 2 ]] || die "$1 needs a value"
      case "$1" in
        --out) OUT="$2" ;;
        --mode) MODE="$2" ;;
        --previous-tag) PREVIOUS_TAG="$2" ;;
        --from-git) FROM_GIT="$2" ;;
        --public-key) PUBLIC_KEY="$2" ;;
        --repository) REPOSITORY="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ -n "$OUT" ]] || { usage >&2; die "--out is required"; }
[[ "$MODE" == "release" || "$MODE" == "rehearsal" ]] || { usage >&2; die "--mode must be release or rehearsal"; }
[[ -z "$PREVIOUS_TAG" || -z "$FROM_GIT" ]] || die "--previous-tag and --from-git are mutually exclusive"
if [[ "$MODE" == "release" && -z "$PREVIOUS_TAG" && -z "$FROM_GIT" ]]; then
  die "release mode needs --previous-tag or --from-git"
fi
[[ -z "$PREVIOUS_TAG" || "$PREVIOUS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] \
  || die "--previous-tag is not a release tag: $PREVIOUS_TAG"
[[ "$FROM_GIT" != -* ]] || die "--from-git must be a revision, not an option: $FROM_GIT"
[[ -n "$REPOSITORY" ]] || REPOSITORY="$(release_conf DEFAULT_REPOSITORY)"
[[ "$REPOSITORY" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || die "--repository must be OWNER/REPO: $REPOSITORY"
if [[ -z "$PUBLIC_KEY" ]]; then
  [[ "$MODE" == "rehearsal" ]] || die "release mode needs --public-key"
  PUBLIC_KEY="$(python3 -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb")).get("SUPublicEDKey", ""))' \
    "$REPO_ROOT/Info.plist" 2>/dev/null)" || PUBLIC_KEY=""
fi
FEED_URL="$(release_conf FEED_URL)"
LEGACY_UNSIGNED_FEED_TAG="$(release_conf_optional LEGACY_UNSIGNED_FEED_TAG)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/anydoor-seed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SEED="$WORK/seed/appcast.xml"
LIVE="$WORK/live.xml"
mkdir -p "$WORK/seed"

fetch_live() {
  # no-cache: the edge must revalidate so we compare against what clients get.
  curl --fail --silent --show-error --location --connect-timeout 10 --max-time 60 \
    -H 'Cache-Control: no-cache' "$FEED_URL" -o "$LIVE"
}

# release_json FIELD: one field of the previous Release.
release_json() {
  gh release view "$PREVIOUS_TAG" --repo "$REPOSITORY" --json "$1" --jq ".$1"
}

seed_from_release() {
  local is_draft is_immutable
  is_draft="$(release_json isDraft)" || return 1
  [[ "$is_draft" == "false" ]] || die "Release $PREVIOUS_TAG is not published (isDraft=$is_draft)"
  if ! gh release download "$PREVIOUS_TAG" --repo "$REPOSITORY" --pattern appcast.xml \
       --dir "$WORK/seed" >/dev/null; then
    return 1
  fi
  [[ -f "$SEED" ]] || return 1
  is_immutable="$(release_json isImmutable)" || die "cannot read isImmutable of Release $PREVIOUS_TAG"
  if [[ "$is_immutable" == "true" ]]; then
    gh release verify-asset "$PREVIOUS_TAG" "$SEED" --repo "$REPOSITORY" >&2 \
      || die "appcast.xml of $PREVIOUS_TAG fails release attestation verification"
    log "appcast.xml of immutable Release $PREVIOUS_TAG matches its attestation"
  fi
}

SOURCE=""
if [[ -n "$FROM_GIT" ]]; then
  git -C "$REPO_ROOT" show "$FROM_GIT:appcast.xml" >"$SEED" 2>/dev/null \
    || die "git revision $FROM_GIT has no appcast.xml"
  SOURCE="git $FROM_GIT:appcast.xml"
elif [[ -n "$PREVIOUS_TAG" ]]; then
  if seed_from_release; then
    SOURCE="Release $PREVIOUS_TAG appcast.xml asset"
  elif [[ "$MODE" == "release" ]]; then
    die "cannot download appcast.xml from Release $PREVIOUS_TAG in $REPOSITORY"
  else
    log "warning: Release $PREVIOUS_TAG has no appcast.xml asset; rehearsing with the live feed as seed"
  fi
fi

if fetch_live; then
  if [[ -z "$SOURCE" ]]; then
    cp "$LIVE" "$SEED"
    SOURCE="live feed $FEED_URL"
  elif ! cmp -s "$SEED" "$LIVE"; then
    message="seed ($SOURCE, $(wc -c <"$SEED" | tr -d ' ') bytes) differs from the live feed $FEED_URL ($(wc -c <"$LIVE" | tr -d ' ') bytes)"
    [[ "$MODE" == "rehearsal" ]] || die "$message; the feed was changed outside the release pipeline or the previous release's feed deploy did not finish"
    log "warning: $message"
  fi
elif [[ "$MODE" == "release" ]]; then
  die "cannot fetch the live feed $FEED_URL to compare with the seed"
elif [[ -z "$SOURCE" ]]; then
  die "no seed: the live feed $FEED_URL is unavailable and no other source applies"
else
  log "warning: cannot fetch the live feed $FEED_URL; seed is not compared"
fi

python3 - "$SEED" <<'PY' || die "seed ($SOURCE) is not a usable appcast"
import sys
import xml.etree.ElementTree as ET

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("./channel/item")
if root.tag != "rss" or not items:
    sys.exit("seed: expected <rss><channel> with at least one <item>")
if any(item.find(f"{SPARKLE}version") is None for item in items):
    sys.exit("seed: an item has no sparkle:version")
PY

# auth_failure MESSAGE: fatal in release mode, a warning in rehearsal mode.
auth_failure() {
  [[ "$MODE" == "rehearsal" ]] || die "$1"
  log "warning: $1"
}

verify_signatures() {
  uv run --quiet --locked --project "$RELEASE_DIR" python "$RELEASE_DIR/verify_sparkle_signatures.py" \
    --appcast "$SEED" --public-key "$PUBLIC_KEY" "$@" >&2
}

# The migration path: no feed signature, so authenticate what the seed points
# at. Each enclosure must be one of this repository's Release downloads and
# carry an EdDSA signature over exactly those bytes.
verify_unsigned_seed() {
  local name url
  local -a archives=()
  python3 - "$SEED" "$REPOSITORY" >"$WORK/enclosures.tsv" <<'PY' || return 1
import re
import sys
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
seed, repository = sys.argv[1], sys.argv[2]
prefix = f"https://github.com/{repository}/releases/download/"
root = ET.parse(seed).getroot()
for item in root.findall("./channel/item"):
    if item.find("enclosure") is None:
        sys.exit("seed: an unsigned seed item has no enclosure to authenticate")
seen = set()
for enclosure in root.iter("enclosure"):
    url = enclosure.get("url", "")
    name = unquote(urlparse(url).path.rsplit("/", 1)[-1])
    if not url.startswith(prefix) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
        sys.exit(f"seed: enclosure {url!r} is not a {repository} Release download")
    if not enclosure.get(f"{SPARKLE}edSignature"):
        sys.exit(f"seed: enclosure {name} has no sparkle:edSignature")
    if name in seen:
        sys.exit(f"seed: enclosure {name} appears twice")
    seen.add(name)
    print(f"{name}\t{url}")
PY
  mkdir -p "$WORK/enclosures"
  while IFS=$'\t' read -r name url; do
    log "Download $url to verify its signature"
    curl --fail --silent --show-error --location --connect-timeout 10 --max-time 600 \
      -o "$WORK/enclosures/$name" "$url" || return 1
    archives+=(--archive "$name=$WORK/enclosures/$name")
  done <"$WORK/enclosures.tsv"
  verify_signatures ${archives[@]+"${archives[@]}"}
}

if [[ -z "$PUBLIC_KEY" ]]; then
  auth_failure "no public key to authenticate the seed ($SOURCE)"
elif grep -qF '<!-- sparkle-signatures:' "$SEED"; then
  if verify_signatures --require-feed-signature; then
    log "Seed feed signature verifies with the pinned public key"
  else
    auth_failure "the seed's ($SOURCE) feed signature does not verify with the pinned public key"
  fi
elif [[ -n "$FROM_GIT" || ( -n "$PREVIOUS_TAG" && "$PREVIOUS_TAG" == "$LEGACY_UNSIGNED_FEED_TAG" ) ]]; then
  log "Seed ($SOURCE) is the unsigned legacy feed; verifying every enclosure instead"
  if verify_unsigned_seed; then
    log "Every enclosure of the unsigned seed verifies with the pinned public key"
  else
    auth_failure "an enclosure of the unsigned seed ($SOURCE) failed verification"
  fi
else
  auth_failure "the seed ($SOURCE) has no Sparkle feed signature; only --from-git or LEGACY_UNSIGNED_FEED_TAG (${LEGACY_UNSIGNED_FEED_TAG:-unset}) may seed unsigned"
fi

mkdir -p "$(dirname "$OUT")"
cp "$SEED" "$OUT"
log "Seed feed from $SOURCE → $OUT"
