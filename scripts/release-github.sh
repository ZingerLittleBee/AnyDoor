#!/usr/bin/env bash
# Bounded retries for the release driver's GitHub publication stage.

release_github_retry() {
    local label="$1"
    shift
    local attempt status delay=2
    for attempt in 1 2 3 4; do
        if "$@"; then
            return 0
        else
            status=$?
        fi
        if [[ "$attempt" -eq 4 ]]; then
            printf '%s failed after %s attempts (exit %s).\n' "$label" "$attempt" "$status" >&2
            return "$status"
        fi
        printf '%s failed (exit %s); retry %s/4 in %ss.\n' \
            "$label" "$status" "$((attempt + 1))" "$delay" >&2
        sleep "$delay" || return $?
        delay=$((delay * 2))
    done
}

release_github_create_draft() {
    local tag="$1" draft
    if gh release create "$@" --verify-tag; then
        return 0
    fi
    # A timed-out create may already have created the draft remotely.
    draft="$(gh release view "$tag" --json isDraft --jq '.isDraft')" || return $?
    [[ "$draft" == "true" ]]
}

release_github_upload_asset() {
    local tag="$1" file="$2" draft remote expected
    draft="$(gh release view "$tag" --json isDraft --jq '.isDraft')" || return $?
    if [[ "$draft" != "true" ]]; then
        printf 'Refusing to replace assets on a published release: %s\n' "$tag" >&2
        return 1
    fi
    expected="$(wc -c < "$file")" || return $?
    expected=$((expected))
    remote="$(gh release view "$tag" --json assets \
        --jq ".assets[] | select(.name == \"${file##*/}\") | \"\(.state):\(.size)\"")" || return $?
    # Preserve a completed upload whose response was lost. Replace only a missing
    # or incomplete asset, and only while the release is still a draft.
    if [[ "$remote" == "uploaded:$expected" ]]; then
        return 0
    fi
    gh release upload "$tag" "$file" --clobber
}

release_github_publish() {
    local tag="$1" draft
    draft="$(gh release view "$tag" --json isDraft --jq '.isDraft')" || return $?
    [[ "$draft" == "false" ]] && return 0
    [[ "$draft" == "true" ]] || return 1
    if ! gh release edit "$tag" --draft=false; then
        printf 'Publish request failed; checking remote state for %s.\n' "$tag" >&2
    fi
    # Inspect remote state even when edit fails: the server may have published
    # successfully before the response was lost. Do not re-create or delete it.
    draft="$(gh release view "$tag" --json isDraft --jq '.isDraft')" || return $?
    [[ "$draft" == "false" ]]
}
