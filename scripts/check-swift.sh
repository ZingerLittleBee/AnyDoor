#!/bin/bash
# Shared local/CI Swift build warning gate and test entry point.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_only=0
skip_build=0
allow_mismatch=0
clean_build=0
test_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) build_only=1 ;;
    --skip-build) skip_build=1 ;;
    --allow-toolchain-mismatch) allow_mismatch=1 ;;
    --clean-build) clean_build=1 ;;
    --help)
      echo 'Usage: scripts/check-swift.sh [--build-only|--skip-build] [--clean-build] [--allow-toolchain-mismatch] [-- <swift test arguments>]'
      exit 0 ;;
    --) shift; test_args=("$@"); break ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$build_only" -eq 1 && "$skip_build" -eq 1 ]]; then
  echo '--build-only and --skip-build are mutually exclusive' >&2
  exit 2
fi
if [[ "$skip_build" -eq 1 && "$clean_build" -eq 1 ]]; then
  echo '--skip-build and --clean-build are mutually exclusive' >&2
  exit 2
fi

# CI owns the pin. Select it per process; never change global xcode-select.
ci_xcode="$(sed -n 's/^  XCODE_APP: //p' .github/workflows/ci.yml)"
if [[ -z "$ci_xcode" ]]; then
  echo 'The CI XCODE_APP pin is missing' >&2
  exit 1
fi
if [[ -z "${DEVELOPER_DIR:-}" && -d "$ci_xcode/Contents/Developer" ]]; then
  export DEVELOPER_DIR="$ci_xcode/Contents/Developer"
fi
active_developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$active_developer" != "$ci_xcode/Contents/Developer" ]]; then
  echo "CI toolchain: $ci_xcode/Contents/Developer" >&2
  echo "Active toolchain: $active_developer" >&2
  if [[ "$allow_mismatch" -ne 1 ]]; then
    echo 'Install/select the CI-pinned Xcode, or explicitly pass --allow-toolchain-mismatch for local evidence only.' >&2
    exit 1
  fi
  echo 'Toolchain mismatch accepted explicitly; this run does not establish CI compiler compatibility.' >&2
fi
for override in TOOLCHAINS SWIFT_EXEC SWIFT_DRIVER_SWIFT_FRONTEND_EXEC; do
  if [[ -n "${!override:-}" ]]; then
    echo "Unset $override for this lane; it uses the selected Xcode's default Swift compiler." >&2
    exit 1
  fi
done
swift_compiler="$active_developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
if [[ ! -x "$swift_compiler" ]]; then
  echo "The selected Xcode has no executable default Swift compiler: $swift_compiler" >&2
  exit 1
fi
"$swift_compiler" --version

# These opt-in tests can touch the live history or run release benchmarks.
# Keep the ordinary lane identical to CI, with those opt-ins unset.
for flag in CLIPBOARD_HISTORY_REMOVE_GUI_FIXTURE CLIPBOARD_HISTORY_RELEASE_ACCEPTANCE CLIPBOARD_HISTORY_GUI_FIXTURE CLIPBOARD_HISTORY_GUI_MIGRATION ANYDOOR_RUN_INTERACTIVE_KEYCHAIN_ACL; do
  if [[ "${!flag:-}" == 1 ]]; then
    echo "$flag=1 is outside the ordinary check lane; run the documented acceptance command separately." >&2
    exit 1
  fi
done

if [[ "$clean_build" -eq 1 ]]; then
  "$swift_compiler" package clean
fi
if [[ "$skip_build" -ne 1 ]]; then
  mkdir -p .build/anydoor-check
  build_log=.build/anydoor-check/build.log
  "$swift_compiler" build --build-tests 2>&1 | tee "$build_log"
  python3 - "$build_log" "$repo_root" <<'PY'
import re
import sys
from pathlib import Path

log_path, root = sys.argv[1:]
diagnostic = re.compile(
    re.escape(root) + r"/(?:Sources|Tests|Plugins)/.+:\d+:\d+: warning: "
)
warnings = sorted({
    line for line in Path(log_path).read_text().splitlines()
    if diagnostic.match(line)
})
if warnings:
    print("\n".join(warnings))
    print("First-party build warnings must be resolved.", file=sys.stderr)
    sys.exit(1)
PY
fi
if [[ "$build_only" -ne 1 ]]; then
  # Bash 3.2 treats expansion of an empty array as unbound under set -u.
  if [[ ${#test_args[@]} -gt 0 ]]; then
    "$swift_compiler" test --skip-build "${test_args[@]}"
  else
    "$swift_compiler" test --skip-build
  fi
fi
