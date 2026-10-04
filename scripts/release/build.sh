#!/usr/bin/env bash
# Build the universal (arm64 + x86_64) release products with SwiftPM.
# Unsigned and secret-free: this is the only release step that runs package
# dependency code (build plugins, macros), so it never sees signing material.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/release/build.sh

Runs `swift build -c release` with the universal release flags from
release_build_flags (scripts/release/lib.sh). Uses the selected Xcode
(DEVELOPER_DIR or xcode-select); CI selects the pin first. No signing.
Follow with scripts/release/assemble.sh --out DIR.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done

release_require_darwin
cd "$REPO_ROOT"
release_build_flags
# One artifact runs on both Apple Silicon and Intel Macs; the bundled
# frameworks are taken from their matching macos-arm64_x86_64 slices.
log "swift build -c release (universal: arm64 + x86_64, minos $(release_conf MIN_MACOS), sdk $MACOS_SDK_VERSION)"
swift build -c release "${RELEASE_BUILD_FLAGS[@]}"
