#!/usr/bin/env bash
# Beta release entry point. Requires an explicit X.Y.Z-beta.N identity.

set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: scripts/beta-release.sh X.Y.Z-beta.N" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_CHANNEL=beta exec "$SCRIPT_DIR/release-driver.sh" "$1"
