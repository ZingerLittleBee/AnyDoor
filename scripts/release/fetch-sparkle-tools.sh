#!/usr/bin/env bash
# Fetch Sparkle's sign_update and generate_appcast from the pinned official
# release tarball, verified by SHA-256 against release.conf. The tools sign
# what users install, so they never come from .build/ or another job's
# artifact, only from this checked download.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'EOF'
Usage: scripts/release/fetch-sparkle-tools.sh --dest DIR [--tarball PATH]

Download Sparkle-<SPARKLE_VERSION>.tar.xz from the sparkle-project GitHub
release, verify its SHA-256 against release.conf, and install bin/sign_update
and bin/generate_appcast into DIR. Also asserts that SPARKLE_VERSION matches
the Sparkle pin in Package.resolved.

  --dest DIR       directory to receive sign_update and generate_appcast
  --tarball PATH   use an already downloaded tarball instead of downloading
                   (it is still SHA-256 verified)
EOF
}

DEST=""
TARBALL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest) [[ $# -ge 2 ]] || die "--dest needs a value"; DEST="$2"; shift 2 ;;
    --tarball) [[ $# -ge 2 ]] || die "--tarball needs a value"; TARBALL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$DEST" ]] || { usage >&2; die "--dest is required"; }

VERSION="$(release_conf SPARKLE_VERSION)"
EXPECTED_SHA256="$(release_conf SPARKLE_TARBALL_SHA256)"

resolved_version="$(python3 - "$REPO_ROOT/Package.resolved" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    pins = json.load(handle)["pins"]
print(next(pin["state"].get("version", "") for pin in pins if pin["identity"] == "sparkle"))
PY
)" || die "cannot read the Sparkle pin from Package.resolved"
[[ "$resolved_version" == "$VERSION" ]] \
  || die "release.conf SPARKLE_VERSION ($VERSION) does not match Package.resolved's Sparkle pin ($resolved_version)"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-tools.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [[ -n "$TARBALL" ]]; then
  [[ -f "$TARBALL" ]] || die "tarball not found: $TARBALL"
  cp "$TARBALL" "$WORK/sparkle.tar.xz"
else
  url="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
  log "Download $url"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 300 \
    "$url" -o "$WORK/sparkle.tar.xz" \
    || die "cannot download $url"
fi

actual_sha256="$(sha256_of "$WORK/sparkle.tar.xz")"
[[ "$actual_sha256" == "$EXPECTED_SHA256" ]] \
  || die "Sparkle $VERSION tarball SHA-256 is $actual_sha256, expected $EXPECTED_SHA256"

tar -xJf "$WORK/sparkle.tar.xz" -C "$WORK" ./bin/sign_update ./bin/generate_appcast \
  || die "Sparkle $VERSION tarball lacks bin/sign_update or bin/generate_appcast"

mkdir -p "$DEST"
for tool in sign_update generate_appcast; do
  [[ -f "$WORK/bin/$tool" && ! -L "$WORK/bin/$tool" ]] || die "bin/$tool is not a regular file"
  rm -f "$DEST/$tool"
  cp "$WORK/bin/$tool" "$DEST/$tool"
  chmod 755 "$DEST/$tool"
done
log "Sparkle $VERSION tools (tarball sha256 $actual_sha256) → $DEST"
