<!-- Canonical project instructions. CLAUDE.md is a symlink to this file. -->

# AnyDoor

A macOS menu-bar toolbox built with SwiftUI/AppKit, SwiftData, and Swift 6 strict concurrency.
Package targets, platform requirements, and dependencies are defined in [Package.swift](Package.swift).

## Task routes

Read the matching reference before changing the subsystem. Follow its links to actual source and tests;
the [navigation map](docs/agents/navigation.md) replaces the old conceptual directory tree.

| Task | Start here |
| --- | --- |
| Find code, ownership, or the current specification | [Navigation](docs/agents/navigation.md), [documentation authority](docs/README.md) |
| Build, run, or investigate local/CI toolchain differences | [Development](docs/development.md) |
| Validate UI, performance, migration, or Keychain behavior | [Testing](docs/testing/README.md) |
| Change persistence or Clipboard History | [Persistence and clipboard history](docs/agents/architecture.md#persistence-and-clipboard-history), [Clipboard History routes](docs/agents/navigation.md#clipboard-history) |
| Change panel actions, hotkeys, Hyper Key, or keyboard lock | [Hotkeys and panel](docs/agents/architecture.md#hotkeys-and-panel) |
| Add or modify a Native Plugin | [Native Plugin playbook](docs/agents/native-plugins.md) |
| Change Script Plugins or command-palette navigation | [Script plugins](docs/agents/architecture.md#script-plugins), [command palette](docs/agents/architecture.md#command-palette), [plugin author guide](tooling/README.md) |
| Change windows, capture, recording, or localization | [Windows and localization](docs/agents/architecture.md#windows-and-localization), [capture and recording](docs/agents/architecture.md#capture-and-recording) |
| Change backup, Config Sync, or privileged system actions | [Backup and sync](docs/agents/architecture.md#backup-and-sync), [system services](docs/agents/architecture.md#system-services) |
| Release, package, or deploy the app, landing site, or feed | [Deployment](docs/deployment.md), [Beta Updates](docs/beta-updates.md) |
| Review a change | [Coding standards](CODING_STANDARDS.md), then the relevant current contract from [docs](docs/README.md) |

## Cross-cutting invariants

- Share the `ModelContainer` created by `AppDelegate`. Keep the pinned
  `~/Library/Application Support/dev.bybee.AnyDoor/AnyDoor.store` path. Never open
  `~/Library/Application Support/default.store`, which can contain another app's data.
- Clipboard History v2 owns `dev.bybee.AnyDoor/ClipboardHistoryV2/`. The sibling
  `ClipboardHistory/` contains pre-v2 payloads only. Read the persistence reference before changing
  either path, migration ordering, recovery, or Keychain access; preserve user data and the frozen
  legacy schema fixture.
- Panel/binding mutations go through `PanelStore` methods, which persist, rebuild, and refresh hotkeys.
  Keep expensive work outside the CGEvent callback and preserve its Sendable snapshot boundary.
- AnyDoor-originated pasteboard writes use the injected
  `ClipboardHistoryPasteboardSelfWriteFunnel` (plugins use `PluginHostServices.pasteboardSelfWrite`).
  History copy/materialization goes through `ClipboardHistoryPasteService`.
- Native Plugin state belongs to the plugin instance. Keep concrete plugin imports in
  `NativePluginCatalog`; use registered descriptors and host capabilities elsewhere. Retain plugin
  data across uninstall/reinstall and publish lifecycle changes across all active surfaces.
- The menu-bar item is an AppKit `NSStatusItem`; the real Settings window is manually managed.
  Preserve scene-level launch/restoration suppression and the installed-app validation required by
  the window reference.

## Working conventions

Repository content, comments, commits, PRs, and issues are in English. User-facing copy goes through
`L10n` / `LocalizedText` and the shared string catalog, supporting the selected app language.
Use Conventional Commits without attribution trailers or email addresses. See
[CONTRIBUTING.md](CONTRIBUTING.md) for contributor setup and the existing attribution checks.

Use relevant skills available in the current session; the skill catalog is the source of truth for
installed skill names. Verification commands and their scope live in [development](docs/development.md)
and [testing](docs/testing/README.md).
