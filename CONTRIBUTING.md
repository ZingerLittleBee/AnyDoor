# Contributing to AnyDoor

Thanks for your interest in contributing! This guide covers how to set up a
development environment, the conventions the project follows, and how to get
a pull request merged.

## Before you start

- **Bug fixes and small improvements**: feel free to open a PR directly.
- **New features or larger changes**: please [open an issue](https://github.com/ZingerLittleBee/AnyDoor/issues/new/choose)
  first to discuss the idea, so nobody spends time on work that won't land.

## Development setup

### Requirements

- macOS 14+
- Swift 6.2 toolchain (Xcode 16.x or the matching command line tools)
- [`watchexec`](https://github.com/watchexec/watchexec) (optional, for hot-reload development)

### Build and run

```bash
# Build
swift build

# Run (dev mode; the process has no Bundle ID identity)
swift run AnyDoor

# Run tests
swift test

# Hot-reload development (requires watchexec)
make

# Install as /Applications/AnyDoor.app (Bundle ID = dev.bybee.AnyDoor)
make install
```

Running requires the macOS **Accessibility** permission (System Settings →
Privacy & Security → Accessibility). Note that the app started by `swift run`
and the one installed by `make install` are two distinct process identities —
each must be granted Accessibility separately. Use `swift run` for daily
development; both share the same SwiftData store, so your data follows you.

Some features need additional permissions when you exercise them (Screen
Recording for capture, Automation for AppleScript-backed toggles, an
administrator prompt or the privileged helper for `/etc/hosts` writes).

### Project structure

The codebase layout, architecture notes, and subsystem map live in
[`AGENTS.md`](AGENTS.md) — read it before making non-trivial changes. It
documents load-bearing invariants (the CGEvent tap timeout budget, the pinned
SwiftData store path, PanelStore as the single write path, etc.) that are easy
to break by accident.

## Code conventions

- **Swift 6 strict concurrency** — the package builds with
  `.swiftLanguageMode(.v6)`; new code must be concurrency-clean (no new
  warnings).
- **Code comments in English.**
- **UI-facing strings in Chinese**, added through the `L10n` /
  `LocalizedText` helpers and the `.xcstrings` string catalog — never
  hardcoded. (The catalog is compiled at build time by an SPM plugin, so plain
  `swift build` picks up new strings.)
- Match the style of the surrounding code; prefer small, focused types.

## Commit conventions

- Write commit messages in **English**.
- Follow [Conventional Commits](https://www.conventionalcommits.org/):
  `type(scope): summary` in the imperative mood, e.g.
  `fix(clipboard): roll back pending deletion when save fails`.
- One logical change per commit.

## Changelog

User-visible changes get an entry in `CHANGELOG.md` under the
`## [Unreleased]` heading (create the appropriate `### Added` / `### Changed`
/ `### Fixed` subsection as needed). Do **not** hand-author a versioned
`## [x.y.z]` heading — the release script rewrites `[Unreleased]` at release
time.

## Pull requests

1. Fork the repository and create a branch from `main`.
2. Make your change, keeping commits focused and conventional.
3. Verify it builds and tests pass: `swift build && swift test`.
4. For behavior changes, describe how you verified them manually — much of
   AnyDoor (hotkeys, capture, menu-bar UI) can only be exercised by running
   the app.
5. Open a PR with an **English** title (Conventional Commits style) and an
   English description. The PR template will walk you through the rest.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
