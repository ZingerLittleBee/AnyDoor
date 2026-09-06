---
id: 035
github: 88
title: "Clipboard History v2: paged host presentation, preview, and paste actions"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decision: ADR-0025.

## What to build

Refactor the AnyDoor host presentation to consume only injected
`ClipboardHistoryModule` values and operations. Replace persistence-aware
SwiftUI state and `[ClipboardHistoryItem]` inputs with a host-owned observable
presentation model that requests the first 100-result page, prefetches near the
visible end, invalidates cursors when query or filters change, and represents
loading, indexing, empty, unavailable, and action-failure states.

Adapt Clipboard Wall, panel popovers, rows, cards, selection, Quick Look, text
editing, context menus, favorites, tags, source filtering, facet filtering, and
delete actions to the new entry summaries and typed mutations. Preserve current
keyboard, focus restoration, window, and selection behavior while replacing
the data source.

Implement host-side materialization and paste. Normal paste restores every
stored representation and item in order. Plain-text paste is offered only when
every item has Exact Text. Any unavailable file member or Legacy Owned File
blocks the complete normal paste and returns a precise action state; no path
silently writes a subset. Decrypted bitmaps remain in memory.

Keep synthetic `Command-V`, focus restoration, localization, Finder reveal,
save panels, and plugin routing in the host. Update
`ClipboardPluginPayloadMapper` to build neutral `PluginClipboardPayload` values
from materialized domain data without exposing the module's encrypted paths or
making the module depend on `PluginInterface`.

This ticket prepares the production presentation but does not yet activate the
new startup lifecycle or delete the legacy implementation.

## Acceptance criteria

- [ ] Clipboard views and presentation models compile without importing SwiftData, GRDB, SQLCipher, Security, or encrypted storage paths
- [ ] Empty browsing is newest-first and paged; non-empty search and every filter use module queries rather than in-memory filtering
- [ ] Cursor invalidation, prefetch, selection preservation, and no-result state are covered through presentation-model tests
- [ ] Normal and plain-text materialization preserve every approved representation and item boundary
- [ ] Mixed or unavailable file collections never paste a partial subset and surface the module's exact unavailable count
- [ ] Preview, Quick Look, text editing, favorite, tag, delete, Finder reveal, copy, and paste retain existing focus and keyboard behavior
- [ ] Native Plugin clipboard actions receive only neutral in-memory payloads and are rechecked through `PluginRegistry`
- [ ] No new mutable global store, watcher, view model, or persistence-aware compatibility wrapper is introduced

## Out of scope

Settings, migration progress, production `AppDelegate` activation, localization
copy completion, and deletion of old sources belong to tickets 036 and 037.

## Blocked by

Tickets 029, 031, 032, and 033.
