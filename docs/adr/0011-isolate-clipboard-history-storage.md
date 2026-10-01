---
status: accepted
---

# Isolate Clipboard History storage

AnyDoor will move Clipboard History out of the shared application data store
into a device-local storage boundary that exclusively owns its entry records,
search data, and owned payloads. Independently attributable files are
required to report the feature's actual file-system-allocated History Storage
Usage, and the boundary also allows paging and indexed search to scale under
Unlimited Retention.

An attachment-directory-only measurement was rejected because it excludes text,
rich content, database pages, and search indexes. Measuring the shared AnyDoor
store was rejected because it includes unrelated application data. The storage
engine is selected separately by ADR-0013: a dedicated SQLite database, not a
second SwiftData `ModelContainer`.

The boundary has one pinned location shared by development and installed app
identities:
`~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistory/`. It owns
the encrypted database, WAL and shared-memory files, encrypted payloads and
thumbnails, migration staging, and temporary encrypted orphans. History Storage
Usage recursively sums their file-system allocated sizes without following
symlinks. It excludes referenced source files and every unrelated AnyDoor
store. The displayed value refreshes after mutations and when the Settings
section appears; it is not an estimate by content kind.

Existing clipboard records and payloads will require a one-time migration. The
new storage remains device-local and outside Config Sync and Config Backup.
Portable configuration includes tag definitions, tag order, and excluded
applications or source channels. Clipboard monitoring, copy-only paste
behavior, Retention Period, and Automatic Image Text Indexing remain
device-local, and a restore never turns monitoring on or off or replaces or
merges local Clipboard History entries.

AnyDoor performs no proactive disk-pressure monitoring, storage warning,
emergency purge, or automatic retention reduction. Age-based retention and
explicit Clear History are the only deletion policies. An actual failed write
is still reported as an operation failure and never authorizes deletion of
existing entries.

No standalone Clipboard History export or import is included in this scope. A
future history archive requires its own encrypted format, capacity disclosure,
migration policy, and conflict semantics.

## Amendment: the store root moves to ClipboardHistoryV2 (2026-10-01)

The pinned location above is the folder where pre-v2 releases keep their
clipboard payloads, and those releases stay installable. Releases 1.8.0
through 4.1.1 delete every file in `ClipboardHistory/` that no legacy row
names whenever they prune history (on launch and after captures), and their
Clear History empties the folder (1.2.0 through 4.1.1). Running one of them
after 4.2.0 through 4.2.5 therefore destroyed the encrypted store, and the next
v2 launch silently created an empty one.

The store root is now
`~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistoryV2/`, a
sibling folder no pre-v2 sweep enumerates. `ClipboardHistory/` keeps only
pre-v2 payloads awaiting the legacy migration, and no v2 file may be created
there.

Every store open first finishes moving a store still found in the legacy
folder, before any database connection opens and before the Keychain is read:

- The legacy folder is detached with one atomic `renamex_np` rename to
  `ClipboardHistoryV2.relocating/`, every child that is not a store file (the
  pre-v2 payloads) goes back to `ClipboardHistory/` under its own name (or as
  `<name>.relocated-<8 hex digits>` if that name was taken meanwhile), and a
  second rename publishes the staged store as `ClipboardHistoryV2/`. The
  database, WAL, and shared-memory files always move together, each step is
  made durable, and an interrupted move resumes on the next open. Nothing is
  copied or re-encrypted, and only empty directories are deleted: an empty
  store skeleton already at `ClipboardHistoryV2/` is removed, and anything
  else found there without store data is moved aside to
  `ClipboardHistoryV2.displaced/<UTC timestamp>-<8 hex digits>-target`, where
  it is never weighed or adopted.
- A store that another process holds open, such as a 4.2.x release still
  running, is not moved. If the new root holds no store yet, Clipboard History
  becomes Store Unavailable with the Store Relocation Failed reason until a
  Retry succeeds; if the new root already holds a store, that store opens and
  the move waits for the next open (a later launch or a Retry).
- When both folders hold a store (the fixed release, then 4.2.x, then the fixed
  release again), the store in `ClipboardHistoryV2/` stays current and the
  legacy one is displaced to
  `ClipboardHistoryV2.displaced/<UTC timestamp>-<8 hex digits>.pending`. The
  displaced store is not necessarily older history: it holds what the 4.2.x
  release captured, often during a downgrade. Once an open has loaded the
  key, it opens each pending store in place with that key. A store that does
  not open or fails integrity validation is kept aside and never adopted; an
  empty one is removed; a populated one replaces the current store with one
  atomic swap only while the current store is empty (for example when the
  fixed release was installed fresh and a 4.2.x release then captured history
  in the legacy folder), and is kept aside otherwise. The swap also waits,
  leaving the store pending, while another process such as a second running
  copy of AnyDoor has either store open: that process would keep writing to
  the files it opened, while its payload files follow the folder names.
  Stores are never merged.

Displaced stores kept aside are not current history. They are exempt from
Retention Period and Clear History, an accepted exception to ADR-0023, and only
Reset Clipboard History removes them, because they are encrypted with the key
Reset deletes; Reset removes everything under `ClipboardHistoryV2.displaced/`.
Reset is offered only while the store is unavailable (ADR-0014), so a displaced
store beside a working store stays on disk indefinitely. That is accepted: it
stays encrypted under the device-only key, nothing references it, and it counts
toward History Storage Usage, measured best effort so that failing to measure
it never fails maintenance. Reset is refused while a store may still sit
outside the store root (a move in progress, or v2 store files in
`ClipboardHistory/`), since deleting the key would make that store unreadable.

Store Relocation Failed is a Store Unavailable reason that offers Retry but
never Reset, an exception to ADR-0014's retry-and-reset recovery: the history
is intact (in `ClipboardHistory/`, or in `ClipboardHistoryV2.relocating/` when
a move stopped part way), no Keychain item was read or created, and nothing was
created at the new root, so a Reset could only destroy history that a Retry
recovers.
