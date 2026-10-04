# Development and verification

The package requires Swift 6 language mode and macOS 14 or later. The exact CI
and release toolchain is the Xcode build pinned in
[macos-toolchain.env](../.github/macos-toolchain.env), selected on runners by the
[setup action](../.github/actions/setup-macos-toolchain/action.yml);
[Package.swift](../Package.swift) defines the package tools version and targets.
Use those files rather than a copied toolchain-version list.

## Build and run

| Task | Entry point |
| --- | --- |
| Compile the app with the installed SDK appearance stamp | `make build` |
| Hot-reload development (requires `watchexec`) | `make` |
| Build the signed/ad-hoc installed identity | `make install` |
| Build and test with the first-party warning gate | `make check` |
| Validate documentation and navigation | `make docs-check` |
| Verify Script Plugin author tooling and contract fixtures | `pnpm -C tooling verify` |
| Search current source and reference text | `python3 scripts/search.py PATTERN` |

`make check` and CI call [the same Swift runner](../scripts/check-swift.sh).
It selects the pinned Xcode per process when installed at the pinned path,
accepts any active Xcode whose `version.plist` reports the pinned build (so a
plain `/Applications/Xcode.app` of the same build matches), invokes that Xcode's
default Swift compiler directly, reports the compiler, fails on first-party
warnings, and runs `swift test --skip-build`. Unset `TOOLCHAINS`, `SWIFT_EXEC`,
and `SWIFT_DRIVER_SWIFT_FRONTEND_EXEC` for this lane so an inherited compiler
override cannot bypass the selection.
It does not change global `xcode-select` or the default Keychain. CI prepares
its own throwaway unlocked Keychain before the test step. Local translation
tests use unique throwaway service names in the current unlocked default
Keychain and remove their test entries.

If the CI-pinned Xcode is unavailable, install it or explicitly collect local
evidence with a different compiler:

```bash
make check CHECK_SWIFT_FLAGS=--allow-toolchain-mismatch
```

Such a run does not prove CI compiler compatibility. Set `DEVELOPER_DIR` to the
desired Xcode `Contents/Developer` directory to select it without changing the
machine default. A locked local Keychain can fail translation credential tests;
run those in a disposable macOS account with an unlocked default Keychain rather
than changing the daily account's Keychain configuration for the test.

For a focused Swift check:

```bash
scripts/check-swift.sh --allow-toolchain-mismatch -- --filter ClipboardHistorySearchTests
```

The warning gate sees diagnostics emitted by this build. CI does not cache
`.build`; a local incremental build may not recompile unchanged targets. Pass
`--clean-build` for the equivalent fresh compilation (`swift package clean`,
then build/test). Use `--build-only` or `--skip-build` when coordinating separate
build and test steps. Keep release/GUI acceptance opt-in environment variables
unset for this ordinary lane; see the [testing index](testing/README.md) for
their separate procedures.

## Native UI evidence

A bare `swift build` / `swift run` can record the deployment target as its SDK
version in `LC_BUILD_VERSION`, changing macOS 26+ window chrome. The
[Makefile](../Makefile) and release driver supply the SDK linker stamp. Judge UI
against those builds and check the binary before calling an appearance change a
regression:

```bash
otool -l /Applications/AnyDoor.app/Contents/MacOS/AnyDoor | grep -A5 LC_BUILD_VERSION
```

The development executable and installed `.app` have different process
identities and permissions, even though their production data paths are shared.
Follow [native UI setup](testing/native-ui.md) and the isolation requirements in
the [Clipboard History acceptance plan](testing/clipboard-history-v2-manual-test-plan.md)
before launching old versions or testing recovery flows.

## Navigation and document roles

Start at the [task routes](agents/navigation.md) or [documentation index](README.md).
Use [bounded search](../scripts/search.py) instead of searching an entire checkout
including bundled apps. `--files` searches paths; `--regex` enables regular
expressions; `--history` includes separately labelled historical plans, issues,
and research. Historical references explain earlier decisions; current contracts
and the implementation decide today's behavior.

`make docs-check` validates repository-relative Markdown navigation and runs
the tooling behavior tests. The lightweight [documentation workflow](../.github/workflows/docs.yml)
runs even when the Swift workflow skips a docs-only change. It checks links and
paths, not semantic agreement between a PRD, an ADR amendment, and the source;
review those together when changing behavior.
