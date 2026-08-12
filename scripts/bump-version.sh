#!/usr/bin/env bash
# Resolve the next release identity and write Apple-compliant versions into Info.plist.
# Usage:
#   scripts/bump-version.sh            # patch+1
#   scripts/bump-version.sh 1.2.3      # explicit
# Prints the resolved version to stdout (everything else goes to stderr).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="${PLIST:-$REPO_ROOT/Info.plist}"

requested="${1:-}"

current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if [[ -z "$requested" ]]; then
  # patch+1
  IFS='.' read -r major minor patch <<<"$current"
  if [[ -z "${patch:-}" ]]; then
    echo "current CFBundleShortVersionString '$current' is not MAJOR.MINOR.PATCH" >&2
    exit 1
  fi
  release_id="${major}.${minor}.$((patch + 1))"
else
  release_id="$requested"
fi

IFS=$'\t' read -r resolved _ short_version build_version _ \
  < <("$REPO_ROOT/scripts/resolve-release-version.sh" "$release_id")

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $short_version" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$PLIST"

echo "$resolved"
