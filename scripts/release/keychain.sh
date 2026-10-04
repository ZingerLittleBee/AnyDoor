#!/usr/bin/env bash
# Temporary signing keychain for the release workflow's signing job. CI-only:
# it rewrites the user keychain search list, which a maintainer's Mac must keep.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/release/keychain.sh create|delete [--keychain PATH]

  create  Create and unlock a keychain, import the Developer ID identity, put
          the keychain first in the user search list, and assert the identity.
          Env: DEVELOPER_ID_P12_BASE64, DEVELOPER_ID_P12_PASSWORD,
          DEVELOPER_ID_SHA1. Writes keychain_path to $GITHUB_OUTPUT.
  delete  Delete the keychain and restore the original search list.

  --keychain PATH  Defaults to $RUNNER_TEMP/anydoor-signing.keychain-db.

Runs only on GitHub-hosted runners (GITHUB_ACTIONS=true and
RUNNER_ENVIRONMENT=github-hosted).
USAGE
}

COMMAND=""
KEYCHAIN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    create | delete)
      [[ -z "$COMMAND" ]] || die "only one subcommand is allowed"
      COMMAND="$1"
      shift ;;
    --keychain)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
      KEYCHAIN="$2"
      shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$COMMAND" ]] || { usage >&2; die "a subcommand is required"; }

[[ "${GITHUB_ACTIONS:-}" == "true" && "${RUNNER_ENVIRONMENT:-}" == "github-hosted" ]] \
  || die "keychain.sh only runs on GitHub-hosted runners; it would rewrite this machine's keychain search list"
[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] || die "RUNNER_TEMP is not a directory"
release_require_darwin

KEYCHAIN="${KEYCHAIN:-$RUNNER_TEMP/anydoor-signing.keychain-db}"
STATE_BASE="${KEYCHAIN%.keychain-db}"
SEARCH_LIST_FILE="$STATE_BASE.search-list"
umask 077

# Print the user keychain search list, one path per line.
search_list() {
  security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
}

create() {
  : "${DEVELOPER_ID_P12_BASE64:?DEVELOPER_ID_P12_BASE64 is required}"
  : "${DEVELOPER_ID_P12_PASSWORD:?DEVELOPER_ID_P12_PASSWORD is required}"
  : "${DEVELOPER_ID_SHA1:?DEVELOPER_ID_SHA1 is required}"
  local expected_sha1 password p12 identities
  local -a previous=()
  expected_sha1="$(printf '%s' "$DEVELOPER_ID_SHA1" | tr '[:lower:]' '[:upper:]')"
  [[ "$expected_sha1" =~ ^[0-9A-F]{40}$ ]] || die "DEVELOPER_ID_SHA1 is not a SHA-1 fingerprint"
  [[ ! -e "$KEYCHAIN" ]] || die "$KEYCHAIN already exists"

  # Generated per run and never written to disk: the keychain stays unlocked
  # for the rest of the job, so nothing needs the password after this step.
  password="$(openssl rand -base64 32)"
  [[ -n "$password" ]] || die "openssl produced no keychain password"

  log "Create $KEYCHAIN"
  security create-keychain -p "$password" "$KEYCHAIN"
  # Lock on sleep and after 6 hours, longer than any signing job.
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$password" "$KEYCHAIN"

  p12="$(mktemp "$RUNNER_TEMP/anydoor-developer-id.XXXXXX")"
  # shellcheck disable=SC2064 # expand now: the path is fixed at this point
  trap "rm -f '$p12'" EXIT
  chmod 600 "$p12"
  printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode >"$p12" \
    || die "DEVELOPER_ID_P12_BASE64 is not valid base64"
  # -x makes the private key non-extractable, and only codesign is trusted to
  # use it. Neither `-A` nor `-T /usr/bin/security` is passed: either would let
  # any process in the job export or use the Developer ID key.
  log "Import the Developer ID identity"
  security import "$p12" -k "$KEYCHAIN" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" -x -T /usr/bin/codesign
  rm -f "$p12"
  trap - EXIT
  # Without the partition list codesign would raise a UI prompt, which hangs a
  # headless runner.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null

  while IFS= read -r entry; do
    if [[ -n "$entry" && "$entry" != "$KEYCHAIN" ]]; then
      previous+=("$entry")
    fi
  done < <(search_list)
  if [[ ! -e "$SEARCH_LIST_FILE" ]]; then
    printf '%s\n' ${previous[@]+"${previous[@]}"} >"$SEARCH_LIST_FILE"
  fi
  security list-keychains -d user -s "$KEYCHAIN" ${previous[@]+"${previous[@]}"}

  identities="$(security find-identity -v -p codesigning "$KEYCHAIN")"
  grep -Eq "^[[:space:]]*[0-9]+\) $expected_sha1 " <<<"$(tr '[:lower:]' '[:upper:]' <<<"$identities")" \
    || die "the imported keychain has no valid codesigning identity $expected_sha1"
  log "Identity $expected_sha1 is ready in $KEYCHAIN"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'keychain_path=%s\n' "$KEYCHAIN" >>"$GITHUB_OUTPUT"
  else
    printf 'keychain_path=%s\n' "$KEYCHAIN"
  fi
}

delete() {
  local -a restore=()
  if [[ -f "$SEARCH_LIST_FILE" ]]; then
    while IFS= read -r entry; do
      if [[ -n "$entry" ]]; then
        restore+=("$entry")
      fi
    done <"$SEARCH_LIST_FILE"
    if [[ ${#restore[@]} -gt 0 ]]; then
      security list-keychains -d user -s "${restore[@]}"
    fi
  fi
  if [[ -e "$KEYCHAIN" ]]; then
    log "Delete $KEYCHAIN"
    security delete-keychain "$KEYCHAIN"
  else
    log "No keychain at $KEYCHAIN"
  fi
  rm -f "$SEARCH_LIST_FILE"
}

case "$COMMAND" in
  create) create ;;
  delete) delete ;;
esac
