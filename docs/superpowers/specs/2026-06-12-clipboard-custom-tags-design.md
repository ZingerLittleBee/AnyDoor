# Clipboard Custom Categories (Manual Tags) — Design

Date: 2026-06-12
Status: Approved direction (Approach A), pending spec review

## Goal

Let the user create their own categories in the clipboard wall and assign
items to them manually. Confirmed requirements:

- **Manual tagging**: membership is assigned by the user via the card context
  menu, not by rules.
- **Multi-tag**: one item can belong to several categories at once.
- **Retention exemption**: tagged items are exempt from automatic pruning,
  exactly like favorites. Tags are effectively named, permanent collections.
- **Independent from Favorites**: the favorite flag, its tab, and its star
  badge stay as they are.
- **All management in the wall window**: create / assign / rename / delete
  without opening Settings.

## Approach (chosen: A)

Item side: a tag-ID array on the SwiftData model. Definition side: a small
registry persisted in UserDefaults.

- Rejected B (new `@Model ClipboardTag` + many-to-many relationship): adds a
  fifth model to the pinned-schema store, SwiftData many-to-many friction
  under Swift 6 strict concurrency, and new backup plumbing — high cost for
  "textbook correctness".
- Rejected C (tag *names* stored on items, no registry): rename rewrites every
  item, empty categories cannot exist, no stable ordering.

## Data model

### `ClipboardHistoryItem.tagIDs: [String] = []`

New persisted field. The inline default makes SwiftData lightweight migration
backfill existing rows (same pattern as `KeyBinding.isEnabled`). IDs are UUID
strings referencing the registry. The schema stays at four `@Model` types.

### `ClipboardTag` (value type)

```swift
struct ClipboardTag: Codable, Equatable, Identifiable {
    let id: String      // UUID string, stable across renames
    var name: String
}
```

### `ClipboardTagStore` (`@MainActor @Observable final class`, singleton)

Owns `private(set) var tags: [ClipboardTag]` — array order is display order
(creation order; no manual reordering in v1). Persists the array as JSON under
one UserDefaults key (`clipboard.customTags`).

API:
- `createTag(name:) -> ClipboardTag?` — trims whitespace; rejects empty;
  if a tag with the same trimmed name already exists, returns the existing
  tag instead of creating a duplicate.
- `renameTag(id:to:)` — trims; rejects empty; renaming to an existing other
  tag's name is a no-op.
- `deleteTag(id:)` — removes from the registry, then asks
  `ClipboardHistoryStore` to sweep the ID off all items (restoring their
  prunability).
- `reload()` — re-reads UserDefaults (used after a backup import).

## Store changes (`ClipboardHistoryStore`)

- `toggleTag(_ item:, tagID:)` — add/remove the ID, save, `reload(kind:)`.
- `removeTagFromAllItems(_ id:)` — fetch all, strip the ID, save, reload.
  Called by `deleteTag`.
- **Pruning**: the exemption condition becomes
  `!item.isFavorite && item.tagIDs.isEmpty` in both the age loop and the
  per-kind overflow loop (today it is `!item.isFavorite` only).
- **Timeline**: the current `#Predicate { createdAt >= cutoff || isFavorite }`
  cannot express array emptiness reliably; switch to fetching sorted rows and
  filtering in memory: `createdAt >= cutoff || isFavorite || !tagIDs.isEmpty`.
  Row counts are small (capped per kind), so this is fine.
- **Launch-time hygiene**: an idempotent sweep removes tag IDs that no longer
  exist in the registry (covers a crash between registry delete and item
  sweep), so stale IDs cannot make items immortal.

## Filtering and category model

- `ClipboardWallCategory` gains `.tag(String)` (the tag ID). `kindFilter`
  returns nil for it. Title resolution branches: builtins keep their
  `LocalizedText(titleKey)`; tag tabs render the registry name with plain
  `Text` (free-form names do not localize).
- `ClipboardSearch.filter` gains `tagID: String? = nil`; when set, keeps rows
  whose `tagIDs` contains it. Composes with `favoritesOnly`, `category`, and
  the query as today.
- `ClipboardWallState.categoryOrder` becomes a function of the registry:
  `[.all, .favorites] + tags.map { .tag($0.id) } + kind tabs`. The state holds
  the current order (pushed in by the view when the registry changes) so Tab /
  Shift-Tab cycling includes custom tabs and stays unit-testable.
- If the active tag is deleted, the category falls back to `.all`.

## UI

### Tab row

- Custom tag tabs appear **after Favorites, before 文本**, in registry order,
  styled like the other capsules (plain text, no icon).
- The capsule row is wrapped in a horizontal `ScrollView` (no indicators) so
  many tags cannot push the search field away; the search field stays pinned
  on the right.
- Right-clicking a **custom** tab (reusing `RightClickMenu`) shows
  重命名… / 删除…. Built-in tabs have no context menu.

### Card context menu

- New submenu 「添加到分类 ▸」 between 收藏 and the Delete separator. It lists
  all tags in order with a checkmark (`NSMenuItem.state = .on`) on the ones
  the item carries; clicking toggles membership via `toggleTag`.
- The submenu ends with a separator and 「新建分类…」. Confirming the new name
  creates the tag **and** assigns it to the right-clicked item in one step.
- With no tags defined yet the submenu contains only 「新建分类…」.

### In-wall input/confirm overlay

Create, rename, and delete-confirmation all use a lightweight overlay **inside
the wall window** (same pattern as the text editor's discard overlay), not
`NSAlert`: an app-modal alert would steal key status and trigger the wall's
`windowDidResignKey` dismissal path. The overlay hosts a focused
`NSTextField`-backed input (create/rename) or a confirm card (delete; copy
states that items are not deleted, they only lose the retention exemption).

Key routing while an overlay is up: Return commits, Esc cancels; both are
consumed before the wall's normal staged-exit handling.

## Sync / backup

The registry's UserDefaults key joins the `SyncSettingsRegistry` whitelist, so
tag *definitions* travel with backups; `reconcileAfterImport` calls
`ClipboardTagStore.reload()`. Memberships (`tagIDs`) live in clipboard history,
which is excluded from backups by existing policy — definitions sync, the
items they contain stay machine-local.

## Edge cases

- Deleting the currently active tag tab → wall resets to 「全部」.
- Create/rename with empty or whitespace-only name → rejected, overlay stays.
- Duplicate names: create returns the existing tag (and still assigns the
  item); rename to a duplicate is a no-op.
- Text edit (`updateText`) and copy/paste flows never touch `tagIDs`.
- Search inside a tag tab composes as on every other tab.
- No tag badge on cards in v1 (favorites keep the star; tag badges would get
  noisy with multi-tag).

## Testing

- `ClipboardSearch`: `tagID` narrowing, composition with query/favorites.
- `ClipboardWallState`: cycling over a dynamic order including tags; fallback
  to `.all` when the active tag disappears.
- `ClipboardTagStore`: create/rename/delete, trimming, duplicate handling,
  UserDefaults round-trip.
- `ClipboardHistoryStore`: `toggleTag` persists; pruning exempts tagged items;
  `removeTagFromAllItems` restores prunability; timeline keeps old tagged
  items; launch sweep drops unknown IDs.
