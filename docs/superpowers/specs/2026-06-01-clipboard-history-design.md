# Clipboard History (Paste-style) — Design

**Date:** 2026-06-01
**Status:** Approved
**Branch:** `feat/clipboard-history`

## Goal

Add a Paste-style clipboard manager to AnyDoor. A background watcher captures
everything the user copies (text, images, files), and a full-width card wall —
summoned by a global hotkey — lets the user browse, search, and re-paste past
clipboard entries. Reusing an entry restores its original rich text; an Option
modifier pastes it as plain text.

This extends the existing `ClipboardHistoryStore`, which today only records
app-generated content (OCR, color pick, QR code, screenshot) and surfaces each
kind through its own menu-bar hover popover. Those four popovers stay; their
content is also merged into the unified card-wall timeline as fixed categories.

## Scope

### In scope (v1)
- Background system-clipboard capture for `text`, `image`, `file`.
- Unified bottom card wall with category tabs + search, summoned by hotkey.
- Auto-paste into the previously focused app (with a copy-only preference).
- Rich-text preservation: Enter restores formatting, Option+Enter pastes plain text.
- Single ★ favorite (exempt from pruning), single-item delete, existing clear-all.
- Privacy filtering (concealed/transient pasteboard types, app exclusion list).
- File contents copied into app storage (with a size ceiling → reference-only fallback).
- Configurable retention (7 / 30 / unlimited) + disk budget.

### Out of scope (v1)
- Pinboards / custom collections (only a single flat favorite flag).
- iCloud / cross-device sync.
- Paste Stack (sequential multi-paste).

## Architecture

Builds on the existing `@MainActor @Observable ClipboardHistoryStore` (record /
reload / prune / clearAll, keyed by `ClipboardHistoryKind`). Three new units:

- **`ClipboardWatcher`** — polls the system pasteboard and records general copies.
- **`ClipboardWallController` + wall window/view** — the bottom card-wall overlay.
- **`ClipboardWallProvider`** — wires the wall into the existing panel/hotkey system.

Data flow:

```
Cmd+C → ClipboardWatcher (classify + privacy filter)
      → ClipboardHistoryStore.record*  (SwiftData)
      → card wall aggregated query (category + search)
      → user selects → Store writes pasteboard + synthesizes ⌘V
```

The wall and the four existing per-kind hover popovers coexist. Both read the
same store; the popovers query a single kind, the wall queries an aggregated,
optionally filtered timeline.

## Data Model

Extend the existing SwiftData types (additive → lightweight migration).

**`ClipboardHistoryKind`** — add cases: `text`, `image`, `file`
(existing `ocr`, `color`, `qrcode`, `screenshot` unchanged).

**`ClipboardHistoryItem`** — add optional fields:
- `richData: Data?` + `richType: String?` — original rich payload (RTF/HTML)
  for format-preserving paste. `richType` records which `NSPasteboard.PasteboardType`
  the bytes represent, so paste can write it back faithfully.
- `sourceBundleID: String?`, `sourceAppName: String?` — source app for the card
  icon (resolved to an `NSImage` at render time via `NSWorkspace`).
- `isFavorite: Bool = false` — ★ favorite; favorites are never auto-pruned.
- `filesManifest: Data?` — JSON describing copied files: list of
  `{ storedName, originalName }`. `isReferenceOnly: Bool = false` marks files
  that exceeded the size ceiling and are stored as a path reference only.

Existing fields (`text`, `fileName`, `colorHex`, `previewTitle`,
`previewSubtitle`, `createdAt`) are reused. For `text`, the plain string lives in
`text` (used for preview + search); rich bytes live in `richData`.

## ClipboardWatcher

A `@MainActor` service started in `AppDelegate` after the store bootstraps.

- Timer-driven poll (~0.5s) of `NSPasteboard.general.changeCount`. On change:
  - classify: file URLs → `file`; image → `image`; otherwise → `text`
    (capturing RTF/HTML rich representations alongside the plain string).
  - **privacy filter:** skip if the pasteboard declares
    `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`; skip if
    the source app is on the user's exclusion list; skip empty/whitespace-only text.
  - **source app:** read `NSWorkspace.shared.frontmostApplication` (best effort).
  - record via the appropriate store method.
- **Self-write suppression:** when the store writes the pasteboard for a paste,
  it records the resulting `changeCount`; the watcher skips that exact value so
  re-pasting from history does not create a duplicate entry.
- Honors the "enable clipboard monitoring" preference (can be turned off).

## Paste Behavior

On selecting a card:
1. Hide the wall (a `.nonactivatingPanel`, so focus returns to the prior app).
2. Write the entry to `NSPasteboard.general` — Enter restores `richData`
   (under `richType`) plus the plain string; Option+Enter writes `.string` only.
3. Synthesize `⌘V` via the existing CGEvent infrastructure — unless the
   "copy only, don't paste" preference is on, in which case stop after step 2.

Files write file references back to the pasteboard. A reference-only file whose
original path is gone is shown greyed-out and surfaces a Toast on paste failure.

## Card Wall UI

A bottom, full-width `.nonactivatingPanel` overlay (can become key for the search
field and keyboard navigation without changing the app's activation policy).

- **Top:** category tabs — `全部 / 文本 / 图片 / 文件 ‖ 截图 / 颜色 / OCR / 二维码`
  — plus a search field.
- **Middle:** horizontally scrolling cards. Each card shows source-app icon,
  type, relative time, a content preview, and a ★ toggle.
- **Keyboard:** `←/→` move selection · `↵` paste · `⌥↵` paste plain · `space`
  Quick Look preview · `⌘F` focus search · `⌫` delete · `esc` close.

The store exposes an aggregated query: `items(category:, query:)` returning a
time-sorted timeline filtered by category tab and search text.

## Integration

- New `BuiltinItem.clipboardWall` (kind `.action`, SF Symbol e.g.
  `doc.on.clipboard`, a `defaultOrder`, `requiresAutomation = false`). It appears
  as a panel row — show/hide, reorder, and hotkey-bind via existing settings UI.
- Dispatched through the existing `runBuiltin` path (no new `HotkeyAction` case).
  `ClipboardWallProvider` is a `@MainActor` `ActionProvider` whose `run()` toggles
  the wall open/closed via `ClipboardWallController`.
- `BuiltinPreferenceSeeder` seeds a default hotkey of `⌘⇧V` for `clipboardWall`;
  if that combination is already bound, it is left empty for the user to set.
- Registered in `AppDelegate` alongside the other providers; the new
  `ClipboardHistoryItem` fields require no schema URL change (same store path).

## Settings (GeneralSettingsView, beside existing Clear History)

- Toggle: enable clipboard monitoring.
- Toggle: copy only (don't auto-paste).
- Retention: 7 days / 30 days / unlimited (default 30).
- Disk budget ceiling for images + files.
- Per-file size ceiling (above it → reference-only).
- App exclusion list.
- Clear history (existing `clearAll`).

## Retention & Cleanup

Extend `pruneExpiredAndOverflow`:
- Configurable max age (replaces the fixed 7-day constant; favorites exempt).
- Images and files count toward a disk budget; oldest non-favorite items evicted
  when exceeded.
- Orphan-file sweep (existing screenshot mechanism) extended to `image` and
  `file` stored payloads.

## Testing

Follow the existing `ClipboardHistoryStoreTests` style (injected clock + temp
history directory):
- Watcher classification (text / image / file) and privacy filtering
  (concealed / transient / excluded app).
- Self-write suppression: pasting from history does not re-record.
- Record / prune / favorite-exemption across the new kinds.
- Plain-text vs rich-text paste payloads written to a stub pasteboard.
- File over the size ceiling falls back to reference-only; missing file path
  surfaces a failure.
- Aggregated `items(category:, query:)` filtering and ordering.

## Risks / Notes

- Auto-paste via synthesized `⌘V` can be unreliable in terminals / remote
  desktops; the copy-only preference is the escape hatch.
- Storing file contents grows disk usage; the size ceiling + disk budget bound it.
- Polling cadence is a battery/latency trade-off; ~0.5s is the macOS-conventional
  value (no public clipboard-change notification exists).
