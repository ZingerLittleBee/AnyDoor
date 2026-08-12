#!/usr/bin/env bash
# Resolve a release identity into channel, Apple bundle versions, and display text.
# Output is a single tab-separated row:
# release-id, channel, short-version, build-version, display-version

set -euo pipefail

release_id="${1:-}"

is_canonical_integer() {
    [[ "$1" == "0" || "$1" =~ ^[1-9][0-9]*$ ]]
}

if [[ "$release_id" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    channel="stable"
    slot=99
    display_version="$release_id"
elif [[ "$release_id" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)-beta\.([0-9]+)$ ]]; then
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    beta_number="${BASH_REMATCH[4]}"
    if [[ ! "$beta_number" =~ ^[1-9][0-9]*$ ]] \
        || (( 10#$beta_number > 98 )); then
        echo "Beta number must be between 1 and 98: $release_id" >&2
        exit 1
    fi
    channel="beta"
    slot="$((10#$beta_number))"
    display_version="$major.$minor.$patch Beta $((10#$beta_number))"
else
    echo "Release version must be X.Y.Z or X.Y.Z-beta.N: $release_id" >&2
    exit 1
fi

for component in "$major" "$minor" "$patch"; do
    if ! is_canonical_integer "$component"; then
        echo "Release version components must not contain leading zeros: $release_id" >&2
        exit 1
    fi
done

short_version="$major.$minor.$patch"
build_version="$major.$minor.$((10#$patch * 100 + slot))"

printf '%s\t%s\t%s\t%s\t%s\n' \
    "$release_id" "$channel" "$short_version" "$build_version" "$display_version"
