#!/usr/bin/env bash
# Build and package the example Script Plugins as plugin-<id>.zip release assets.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --out DIR [--tooling-dir DIR]

Runs \`pnpm install --frozen-lockfile && pnpm verify\` in the tooling workspace,
which builds every tooling/examples/*/dist, then zips each dist that has a
manifest.json into DIR/plugin-<manifest id>.zip. Each zip holds the dist files
(manifest.json, bundle.js, ...) at its root and is byte-reproducible.

Prints the written zip paths on stdout, one per line. Fails if no plugin is found.

  --out DIR          output directory (created if missing)
  --tooling-dir DIR  tooling workspace (default: <repo>/tooling)
  -h, --help         show this help
EOF
}

out=""
tooling_dir="$REPO_ROOT/tooling"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) [[ $# -ge 2 ]] || die "--out needs a value"; out="$2"; shift 2 ;;
    --tooling-dir) [[ $# -ge 2 ]] || die "--tooling-dir needs a value"; tooling_dir="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown argument: $1" ;;
  esac
done
[[ -n "$out" ]] || { usage >&2; die "--out is required"; }
[[ -d "$tooling_dir" ]] || die "tooling directory not found: $tooling_dir"
command -v pnpm >/dev/null 2>&1 || die "pnpm not found in PATH"
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
tooling_dir="$(cd "$tooling_dir" && pwd)"

# `pnpm verify` is the tooling gate and builds every example's dist/ in place.
log "pnpm install --frozen-lockfile && pnpm verify (in $tooling_dir)"
(cd "$tooling_dir" && pnpm install --frozen-lockfile && pnpm verify) >&2

written=""
count=0
for example_dist in "$tooling_dir"/examples/*/dist; do
  [[ -d "$example_dist" ]] || continue
  manifest="$example_dist/manifest.json"
  [[ -f "$manifest" ]] || die "no manifest.json in $example_dist; pnpm verify should have built it"
  plugin_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$manifest")" \
    || die "cannot read the plugin id from $manifest"
  # The id becomes a file name and a release asset name.
  [[ "$plugin_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "unsafe plugin id '$plugin_id' in $manifest"
  plugin_zip="$out/plugin-$plugin_id.zip"
  case "$written" in
    *"|$plugin_zip|"*) die "duplicate plugin id '$plugin_id' ($example_dist)" ;;
  esac
  log "Package $plugin_zip"
  python3 "$RELEASE_DIR/zip_dir.py" --src "$example_dist" --out "$plugin_zip"
  written="$written|$plugin_zip|"
  count=$((count + 1))
  printf '%s\n' "$plugin_zip"
done
[[ $count -gt 0 ]] || die "no example Script Plugins found under $tooling_dir/examples/"
log "Packaged $count example Script Plugin(s) into $out"
