#!/usr/bin/env bash
# Download Sparkle's release tarball and extract sign_update + generate_appcast
# into scripts/sparkle-bin/. Idempotent: skips when the pinned version is already present.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <sparkle-version>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$REPO_ROOT/scripts/sparkle-bin"
STAMP_FILE="$BIN_DIR/.version"

if [[ -f "$STAMP_FILE" ]] && [[ "$(cat "$STAMP_FILE")" == "$VERSION" ]]; then
  echo "sparkle tools already installed at $VERSION"
  exit 0
fi

mkdir -p "$BIN_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz"
echo "Downloading $URL"
curl -fL "$URL" -o "$TMP_DIR/sparkle.tar.xz"
tar -xf "$TMP_DIR/sparkle.tar.xz" -C "$TMP_DIR"

# Sparkle distributes its CLI tools under bin/.
cp "$TMP_DIR/bin/sign_update" "$BIN_DIR/sign_update"
cp "$TMP_DIR/bin/generate_appcast" "$BIN_DIR/generate_appcast"
cp "$TMP_DIR/bin/generate_keys" "$BIN_DIR/generate_keys" 2>/dev/null || true
chmod +x "$BIN_DIR"/*

echo "$VERSION" > "$STAMP_FILE"
echo "Installed sparkle tools $VERSION → $BIN_DIR"
