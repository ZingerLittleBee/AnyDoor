# Shared helpers for scripts/release/*.sh. Source it; do not execute it.
# Bash 3.2 compatible: these scripts also run from a maintainer's /bin/bash.
# Variables set here are consumed by the scripts that source this file.
# shellcheck shell=bash disable=SC2034

RELEASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$RELEASE_DIR/../.." && pwd)"

log() { printf '\033[1;34m▸\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# release_conf KEY: print KEY's value from release.conf, or fail.
release_conf() {
  local value
  value="$(sed -n "s/^$1=//p" "$RELEASE_DIR/release.conf")"
  [[ -n "$value" ]] || die "release.conf has no $1"
  printf '%s\n' "$value"
}

# release_conf_optional KEY: print KEY's value from release.conf, possibly
# empty; fail only when the key is absent.
release_conf_optional() {
  grep -q "^$1=" "$RELEASE_DIR/release.conf" || die "release.conf has no $1"
  sed -n "s/^$1=//p" "$RELEASE_DIR/release.conf"
}

# release_build_flags: set RELEASE_BUILD_FLAGS to the universal release build
# flags and MACOS_SDK_VERSION to the selected SDK's version. build.sh and
# assemble.sh must pass identical flags, or `--show-bin-path` names a different
# build directory.
#
# The `swiftbuild` backend is required: the `native` backend dispatches
# multi-arch builds to xcbuild, which (as of Swift 6.3) fails to resolve the
# XCStringsCompilerPlugin build-tool plugin ("Unable to resolve build file ...
# PACKAGE-TARGET"). That backend also writes the deployment target into
# LC_BUILD_VERSION's `sdk` field instead of the real SDK version, and macOS 26+
# gates the modern window appearance on that field (>= 26), so a 14.0 `sdk`
# forces the legacy, washed-out appearance. Overriding `platform_version`
# records minos MIN_MACOS but the real SDK. The linker applies minos
# unconditionally, so MIN_MACOS must match Package.swift and Info.plist
# (meta.py verify-plist asserts this) or the binary would claim to run on an
# older macOS than it was compiled for.
release_build_flags() {
  local min_macos
  min_macos="$(release_conf MIN_MACOS)"
  MACOS_SDK_VERSION="$(xcrun --show-sdk-version --sdk macosx)" \
    || die "xcrun cannot report the macOS SDK version"
  [[ -n "$MACOS_SDK_VERSION" ]] || die "xcrun reported an empty macOS SDK version"
  RELEASE_BUILD_FLAGS=(--build-system swiftbuild --arch arm64 --arch x86_64
    -Xlinker -platform_version -Xlinker macos -Xlinker "$min_macos" -Xlinker "$MACOS_SDK_VERSION")
}

# release_require_darwin: the packaging scripts drive macOS-only tools.
release_require_darwin() {
  [[ "$(uname -s)" == "Darwin" ]] || die "${0##*/} must run on macOS"
}
