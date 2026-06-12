# Clipboard Wall: Text Preview (Space) + Card Context Menu with Edit

**Date:** 2026-06-12
**Status:** Approved

## Goal

Two additions to the clipboard card wall (`ClipboardWallWindowController` / `ClipboardWallView`):

1. **Text preview via Space** — pressing Space on a selected text-bearing item (`.text` / `.ocr` / `.qrcode`) opens a large floating read-only preview, mirroring the existing Quick Look behavior for images/files. The `space → preview` hint in the wall footer already exists; today text items do nothing on Space.
2. **Card context menu with Edit** — right-clicking a card shows a context menu: **Edit** (text-bearing kinds only), **Copy**, **Favorite/Unfavorite**, **Delete**. Edit opens the same floating panel in editable mode and persists changes.

## Components

### 1. `ClipboardTextWindow` (new, `Sources/AnyDoor/Views/ClipboardTextWindow.swift`)

A singleton floating panel modeled on `ScreenshotPreviewWindow` (`.borderless + .nonactivatingPanel`, centered at ~60% of the visible screen frame, floating level, closes on outside click), with two modes:

- **Preview (read-only):** scrollable full text, close button, footer metadata (e.g. character count). Panel does **not** become key, so the wall keeps receiving keyboard events.
- **Edit:** embeds the existing `PlainTextEditor` (NSTextView wrapper from Hosts, undo-capable) plus Cancel / Save buttons. The panel must become key for typing, so it uses a `canBecomeKey = true` NSPanel subclass (same trick as `ClipboardWallPanel`); still non-activating, so the previously focused app is not deactivated.

Edit-mode interactions:

- **Save:** Save button or **⌘S**. Persists via `ClipboardHistoryStore.updateText`, then closes the panel.
- **Cancel/Esc with unsaved changes:** show an inline confirmation overlay inside the panel (Discard / Keep Editing) rather than an NSAlert, to avoid activating the app. Esc or Cancel with no changes closes immediately.
- Saving an empty result is allowed only if trimmed text is non-empty; otherwise Save is disabled.

### 2. Space handling in `ClipboardWallWindowController`

`toggleQuickLook()` currently returns nil for text kinds ("preview is already visible on the card"). Change the routing:

- `.text` / `.ocr` / `.qrcode` → toggle `ClipboardTextWindow` in preview mode.
- `.image` / `.screenshot` / `.file` → system Quick Look (unchanged).
- `.color` → no preview (unchanged).

While the text preview is visible:

- **Esc** closes the preview first and consumes the event (the wall stays open).
- **←/→** still move the selection, and the preview content refreshes to follow it (Finder Quick Look behavior). If the new selection is not text-bearing, the preview closes.
- **Space** closes the preview (toggle).

Wall lifecycle guards: `windowDidResignKey` and the global outside-click monitor must exempt `ClipboardTextWindow` the same way they already exempt `QLPreviewPanel`, so opening the edit panel (which becomes key) does not dismiss the wall. Dismissing the wall closes any open text panel.

### 3. Card context menu (`ClipboardCardView` + `ClipboardWallView`)

Attach `.contextMenu` to the card (pattern: `HostsEditorView`). Right-click also selects the card. Items:

- **Edit** — only for `.text` / `.ocr` / `.qrcode`; opens `ClipboardTextWindow` in edit mode for that item.
- **Copy** — writes the payload to the general pasteboard without pasting or dismissing the wall: `ClipboardPasteService.writePayload` + `watcher.noteSelfWrite` (suppress self-capture) + success toast.
- **Favorite / Unfavorite** — existing `ClipboardHistoryStore.toggleFavorite`.
- **Delete** (destructive role) — existing `ClipboardHistoryStore.delete`.

Callbacks (`onEdit`, `onCopy`, `onDelete`) are injected from `ClipboardWallWindowController.makeWallView()` alongside the existing `onSelect` / `onToggleFavorite`.

### 4. `ClipboardHistoryStore.updateText(_ item:newText:)` (new)

Follows the `toggleFavorite` mutation pattern:

- Set `item.text = newText`; recompute `previewTitle` / `previewSubtitle` via the existing `previewTitle(for:)` / `textSubtitle(for:)` helpers.
- **Clear `richData` / `richType`** — the stale rich payload would otherwise win on paste and resurrect the pre-edit content.
- `createdAt` unchanged (the card keeps its position).
- `mainContext.save()` + `reload(kind:)`; the wall's `@Query` re-renders automatically.

`kind` is unchanged: an edited OCR/QR item stays in its category; only its text payload changes.

### 5. Localization

New `L10n.Key` cases + `Localizable.xcstrings` entries (zh-Hans + en): edit menu item, copy menu item, delete menu item, favorite/unfavorite, edit panel title, Save, Cancel, discard-confirmation text (Discard / Keep Editing), copy-success toast. Reuse existing `.clipboardPreviewClose`, `.clipboardHintPreview`, etc.

## Out of Scope

- The hover popover (`ClipboardHistoryPopoverView`) already has its own inline preview for text kinds; it is not changed.
- No editing for color/image/file items.
- No rich-text editing; the editor is plain text.

## Testing

- Unit tests for `ClipboardHistoryStore.updateText`: text updated, preview title/subtitle recomputed, rich payload cleared, `createdAt` preserved.
- UI behavior (Space toggle, Esc layering, context menu, ⌘S, dirty-close confirmation) verified manually via `swift run` / `make install`.
