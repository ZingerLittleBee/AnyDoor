#!/usr/bin/env bash
# Resolve the next version and write it into Info.plist.
# Usage:
#   scripts/bump-version.sh            # patch+1
#   scripts/bump-version.sh 1.2.3      # explicit
# Prints the resolved version to stdout (everything else goes to stderr).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$REPO_ROOT/Info.plist"

requested="${1:-}"

current="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"

if [[ -z "$requested" ]]; then
  # patch+1
  IFS='.' read -r major minor patch <<<"$current"
  if [[ -z "${patch:-}" ]]; then
    echo "current CFBundleShortVersionString '$current' is not MAJOR.MINOR.PATCH" >&2
    exit 1
  fi
  next="${major}.${minor}.$((patch + 1))"
else
  if ! [[ "$requested" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION '$requested' must be strict semver MAJOR.MINOR.PATCH (no pre-release suffixes)" >&2
    exit 1
  fi
  next="$requested"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next" "$PLIST"

echo "$next"
