#!/usr/bin/env bash
# Permit the one-time feed bootstrap only while the canonical endpoint is absent.

set -euo pipefail

feed_url="${1:-https://anydoor.dev/appcast.xml}"

if ! http_status="$(
    curl --silent --show-error \
        --max-time 30 \
        --output /dev/null \
        --write-out '%{http_code}' \
        -H 'Cache-Control: no-cache' \
        "$feed_url"
)"; then
    echo "Cannot verify whether the canonical feed already exists: $feed_url" >&2
    exit 1
fi

if [[ "$http_status" != "404" ]]; then
    echo "Bootstrap refused: canonical feed returned HTTP $http_status; expected 404" >&2
    exit 1
fi
