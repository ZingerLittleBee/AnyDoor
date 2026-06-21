#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDING_PUBLIC="$ROOT/../landing/public"

cd "$ROOT"
mkdir -p out "$LANDING_PUBLIC"

# Guard the render: fail fast if the montage/app-icon invariants regress
# (e.g. a stale slogan) before producing artifacts.
npm run test:system-montage
npm run test:app-icons

# Retry a render command a few times. Loading the Noto Sans SC webfont fans out
# to ~388 unicode-range subset requests per render tab; across the default 8 tabs
# that briefly saturates the connection pool and a single font face can exceed
# @remotion/google-fonts' internal 18s load timeout (which --timeout does NOT
# govern). The failure is intermittent and only happens at tab startup, so a
# plain retry reliably recovers without slowing successful renders.
retry() {
  local max=3 n=1
  until "$@"; do
    local status=$?
    if [ "$n" -ge "$max" ]; then
      echo "render: command failed after $n attempts (exit $status): $*" >&2
      return "$status"
    fi
    echo "render: attempt $n failed (exit $status); retrying ($((n + 1))/$max)..." >&2
    n=$((n + 1))
  done
}

render_language() {
  local composition="$1"
  local lang="$2"

  # --timeout raises Remotion's delayRender budget; retry covers the font-load
  # timeout that lives inside @remotion/google-fonts (see retry() above).
  retry npx remotion render "$composition" "out/promo-$lang.mp4" --codec=h264 --timeout=120000
  retry npx remotion render "$composition" "out/promo-$lang.webm" --codec=vp9 --timeout=120000
  # Poster frame 48 (not 0): Scene0's keycap is lit (glow window 42-58) and the
  # caption has faded in (from frame 34), so the README/landing thumbnail shows the
  # door + Hyper Key + slogan instead of a near-empty dim frame.
  retry npx remotion still "$composition" "out/promo-$lang.jpg" --frame=48 --timeout=120000

  # Only the poster JPG is tracked (README thumbnail / video poster). The mp4 and
  # webm stay under out/ (gitignored) as build artifacts and are published
  # out-of-band: GitHub upload for the README inline player, R2/etc. for the web.
  cp "out/promo-$lang.jpg" "$LANDING_PUBLIC/promo-$lang.jpg"
}

render_language AnyDoorPromo zh
render_language AnyDoorPromoEn en
