#!/usr/bin/env bash
# Submit an .app, .dmg, or .zip to Apple's notary service and require an
# explicit Accepted verdict; optionally staple and assess the result.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/release/notarize.sh --file PATH [--staple] [--log-dir DIR] [--timeout DURATION]

  --file PATH          AnyDoor.app (zipped with ditto before upload), a .dmg,
                       or a .zip (a .zip cannot be stapled).
  --staple             Staple and validate the ticket, then assess with spctl.
  --log-dir DIR        Where the notary log is saved (default: PATH's directory).
  --timeout DURATION   notarytool --wait timeout (default: 45m).

Credentials, in order of preference:
  ASC_API_KEY_P8 (key file contents), ASC_API_KEY_ID, ASC_API_ISSUER_ID
      App Store Connect team API key (CI).
  NOTARY_PROFILE
      A `notarytool store-credentials` keychain profile (local fallback).

Prints the submission id on stdout.
USAGE
}

FILE=""
STAPLE=0
LOG_DIR=""
TIMEOUT="45m"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --staple) STAPLE=1; shift ;;
    --file | --log-dir | --timeout)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a value"
      case "$1" in
        --file) FILE="$2" ;;
        --log-dir) LOG_DIR="$2" ;;
        --timeout) TIMEOUT="$2" ;;
      esac
      shift 2 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$FILE" ]] || { usage >&2; die "--file is required"; }
[[ -e "$FILE" ]] || die "no such file: $FILE"
[[ "$TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]] || die "--timeout must look like 3600, 45m, or 1h"
FILE="${FILE%/}"

case "$FILE" in
  *.app) KIND=app ;;
  *.dmg) KIND=dmg ;;
  *.zip) KIND=zip ;;
  *) KIND="" ;;
esac
if [[ "$KIND" == app && ! -d "$FILE" ]] || [[ -n "$KIND" && "$KIND" != app && ! -f "$FILE" ]]; then
  KIND=""
fi
[[ -n "$KIND" ]] || die "unsupported file (expected an .app bundle, .dmg, or .zip): $FILE"
[[ "$STAPLE" -eq 0 || "$KIND" != zip ]] \
  || die "a .zip cannot be stapled; staple the .app inside it and re-zip"

AUTH=()
if [[ -n "${ASC_API_KEY_P8:-}" ]]; then
  [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_API_ISSUER_ID:-}" ]] \
    || die "ASC_API_KEY_P8 needs ASC_API_KEY_ID and ASC_API_ISSUER_ID"
  AUTH_MODE=api-key
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
  AUTH_MODE=profile
else
  die "no notary credentials: set ASC_API_KEY_P8/ASC_API_KEY_ID/ASC_API_ISSUER_ID or NOTARY_PROFILE"
fi

LOG_DIR="${LOG_DIR:-$(dirname "$FILE")}"
mkdir -p "$LOG_DIR"

WORK="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/anydoor-notarize.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

KEY_FILE=""
if [[ "$AUTH_MODE" == api-key ]]; then
  # mktemp -d is mode 700 and the umask keeps the key at 600. The key exists
  # only for the notarytool calls and is removed before stapling.
  KEY_FILE="$WORK/AuthKey_$ASC_API_KEY_ID.p8"
  (umask 077 && printf '%s\n' "$ASC_API_KEY_P8" >"$KEY_FILE")
  chmod 600 "$KEY_FILE"
  AUTH=(--key "$KEY_FILE" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID")
fi

SUBMISSION="$FILE"
if [[ "$KIND" == app ]]; then
  SUBMISSION="$WORK/$(basename "$FILE" .app).zip"
  log "Zip $(basename "$FILE") for upload"
  ditto -c -k --keepParent "$FILE" "$SUBMISSION"
fi

log "Submit $(basename "$FILE") to the notary service (wait up to $TIMEOUT)"
submit_status=0
submit_output="$(xcrun notarytool submit "$SUBMISSION" "${AUTH[@]}" \
  --wait --timeout "$TIMEOUT" --output-format json)" || submit_status=$?

# The exit status alone does not prove acceptance, so the verdict comes from
# the JSON: id, status, and message on one line. The separator is the ASCII
# unit separator because `read` collapses empty fields between tabs.
parsed="$(printf '%s' "$submit_output" | python3 -c '
import json
import sys

try:
    result = json.load(sys.stdin)
except ValueError:
    sys.exit(1)
if not isinstance(result, dict):
    sys.exit(1)
fields = (result.get("id"), result.get("status"), result.get("message"))
print("\x1f".join("" if value is None else str(value).replace("\x1f", " ").replace("\n", " ") for value in fields))
')" || die "notarytool submit (exit $submit_status) did not return JSON: $submit_output"
IFS=$'\x1f' read -r SUBMISSION_ID STATUS MESSAGE <<<"$parsed" || true
[[ -n "$SUBMISSION_ID" ]] \
  || die "notarytool submit (exit $submit_status) returned no submission id: $submit_output"
log "Submission id: $SUBMISSION_ID (status: ${STATUS:-unknown}${MESSAGE:+, $MESSAGE})"
printf '%s\n' "$SUBMISSION_ID"

# Apple: always check the log, even when notarization succeeds. A missing log
# is a warning; the verdict above decides the outcome.
LOG_FILE="$LOG_DIR/notary-$(basename "$FILE")-$SUBMISSION_ID.json"
if xcrun notarytool log "$SUBMISSION_ID" "${AUTH[@]}" "$LOG_FILE" >/dev/null; then
  log "Notary log → $LOG_FILE"
  python3 - "$LOG_FILE" <<'PY' >&2 || true
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    issues = json.load(handle).get("issues") or []
for issue in issues:
    print(f"notary {issue.get('severity', 'issue')}: {issue.get('path', '')}: {issue.get('message', '')}")
PY
else
  log "warning: could not fetch the notary log for $SUBMISSION_ID"
fi

if [[ -n "$KEY_FILE" ]]; then
  rm -f "$KEY_FILE"
fi

if [[ "$STATUS" != "Accepted" ]]; then
  if [[ "$STATUS" == "In Progress" ]]; then
    die "notarization of $SUBMISSION_ID is still in progress after $TIMEOUT; resume with 'xcrun notarytool wait $SUBMISSION_ID' instead of resubmitting"
  fi
  die "notarization of $(basename "$FILE") was not accepted (status: ${STATUS:-none}, exit $submit_status); see $LOG_FILE"
fi
log "Accepted: $(basename "$FILE")"

if [[ "$STAPLE" -eq 1 ]]; then
  log "Staple and validate $(basename "$FILE")"
  xcrun stapler staple "$FILE" >&2
  xcrun stapler validate "$FILE" >&2
  if [[ "$KIND" == app ]]; then
    spctl -a -t exec -vv "$FILE" >&2
  else
    spctl -a -t open --context context:primary-signature -vv "$FILE" >&2
  fi
fi
