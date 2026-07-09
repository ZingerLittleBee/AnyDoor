---
id: 011
title: "Quicklinks: Open With override and derived icons"
status: done
prd: docs/prds/2026-07-09-quicklinks.md
---

## Parent

PRD: `docs/prds/2026-07-09-quicklinks.md` (user stories 12, 13, 17, 18)

## What to build

**Open With.** The Settings edit sheet gains an app picker (backed by
`InstalledAppsScanner`, plus a "系统默认" nil choice) writing
`openWithBundleID`. `QuicklinkOpener` resolves the bundle ID at open time and
routes through `NSWorkspace.open(_:withApplicationAt:configuration:)`; an
unresolvable bundle ID falls back to the system default handler and shows a
toast — never a hard failure.

**Derived icons.** A `QuicklinkIconProvider` resolves, in priority order:
pinned Open With app icon (`AppIconCache`) → file/folder system icon
(`NSWorkspace.shared.icon(forFile:)`) → deeplink scheme-handler app icon
(`urlForApplication(toOpen:)`) → web favicon → SF Symbol `link` fallback.
Favicons fetch `https://<host>/favicon.ico` asynchronously, cache to disk
under Application Support keyed by host, never re-fetch on hit, and fall back
to the symbol on any failure (offline, 404, non-image data). Icons render in
both the Settings list and palette rows; resolution must never block the
MainActor render path (the `AppIconCache` `.task`-on-MainActor lesson
applies — decode off-main, publish results).

## Acceptance criteria

- [ ] A folder Quicklink pinned to VS Code opens in VS Code; the same path with 系统默认 opens in Finder
- [ ] Deleting the pinned app from disk, then opening the Quicklink, opens via the system default and shows a fallback toast
- [ ] A `https://github.com` entry shows the GitHub favicon after first display; relaunch shows it instantly with no network request; an unreachable host shows the `link` symbol without delaying the list
- [ ] File/folder entries show their Finder icon; `slack://` shows the Slack app icon; a scheme nothing handles shows the fallback symbol
- [ ] Palette scrolling with 20+ quicklinks stays smooth (no synchronous icon work on the render path)
- [ ] Unit tests pass: opener plan for openWith-hit / openWith-missing-fallback; icon-source priority given an injected lookup (no real network in tests)
- [ ] `swift build` and `swift test` pass; new strings resolve in zh-Hans and en

## Blocked by

- 008 (opener, Settings sheet, palette row)
