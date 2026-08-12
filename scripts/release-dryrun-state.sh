#!/usr/bin/env bash
# Snapshot and restore release files so a dry run leaves no candidate state behind.

export RELEASE_DRYRUN_STATE=""
export RELEASE_DRYRUN_DIST=""
RELEASE_DRYRUN_TRACKED_FILES=(Info.plist CHANGELOG.md appcast.xml)

release_dryrun_prepare() {
    local repo_root="$1"
    local state_root
    state_root="$(mktemp -d "${TMPDIR:-/tmp}/anydoor-release-dryrun.XXXXXX")"
    mkdir -p "$state_root/original"

    local relative_path
    for relative_path in "${RELEASE_DRYRUN_TRACKED_FILES[@]}"; do
        if ! cp -p "$repo_root/$relative_path" "$state_root/original/$relative_path"; then
            rm -rf -- "$state_root"
            return 1
        fi
    done

    RELEASE_DRYRUN_STATE="$state_root"
    RELEASE_DRYRUN_DIST="$state_root/dist"
}

release_dryrun_restore() {
    local repo_root="$1"
    [[ -n "$RELEASE_DRYRUN_STATE" && -d "$RELEASE_DRYRUN_STATE/original" ]] || return 0

    local relative_path
    for relative_path in "${RELEASE_DRYRUN_TRACKED_FILES[@]}"; do
        if ! cp -p "$RELEASE_DRYRUN_STATE/original/$relative_path" "$repo_root/$relative_path"; then
            printf 'Dry-run recovery files preserved at %s\n' "$RELEASE_DRYRUN_STATE" >&2
            return 1
        fi
    done

    rm -rf -- "$RELEASE_DRYRUN_STATE"
    RELEASE_DRYRUN_STATE=""
    RELEASE_DRYRUN_DIST=""
}
