#!/usr/bin/env bash
# Stable release entry point. Beta identities must use beta-release.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_CHANNEL=stable exec "$SCRIPT_DIR/release-driver.sh" "$@"
