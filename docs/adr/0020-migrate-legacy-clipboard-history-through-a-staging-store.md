---
status: accepted
---

# Migrate legacy Clipboard History through a staging store

## Current decision

Migration still builds and verifies an encrypted staging store before
publication, preserving the legacy snapshot until verified cleanup. The
amendments and [OCR facet addendum](0019-model-content-types-as-overlapping-facets.md#addendum-2026-09-22-ocr-joins-the-closed-facet-set)
update the original decision below:

- Legacy OCR rows migrated now retain Text and OCR through their first-party
  capture kind. Already-published v2 rows that lost that provenance cannot be
  recovered by content inference. Filter ordering follows the current
  ADR-0019 contract, including persisted user reordering.
- [Before the cutover](#amendment-copies-that-are-not-files-and-captures-before-the-cutover-2026-10-01),
  passive monitoring stays paused and explicit captures skip history writes;
  their pasteboard writes and saved files still work.
- [A blocked migration](#amendment-discarding-the-entries-that-block-the-migration-2026-10-01)
  offers Retry and a confirmed discard of the entries that block publication.
  The count must still match, the staging store must already be verified, and
  the Keychain key and displaced stores are retained. Reset is not this flow.

The original kind mapping and fixed-filter wording remain below as decision
history. Current implementation entry points are
[`ClipboardHistoryLegacyMigration.swift`](../../Sources/ClipboardHistory/ClipboardHistoryLegacyMigration.swift)
and [`ClipboardHistoryLifecycle.swift`](../../Sources/AnyDoor/Services/ClipboardHistoryLifecycle.swift).

## Original decision

The first release that removes `ClipboardHistoryItem` from the shared SwiftData
schema performs a one-time migration before Clipboard History monitoring
starts. It retains a read-only legacy schema long enough to extract the old
rows; it must not let SwiftData remove or rewrite the legacy model before that
extraction succeeds.

Migration builds a complete encrypted Clipboard History Store in a sibling
staging directory. The legacy SwiftData store and plaintext history payload
directory remain authoritative while staging is incomplete. The staged store
is published atomically only after database integrity checks, row and identifier
reconciliation, foreign-key validation, search-index validation, and
authenticated decryption of every migrated owned payload succeed. Clipboard
History UI exposes a migration or failure state, and passive monitoring remains
paused until publication completes.

Each logically retained legacy row becomes one Clipboard Entry containing one
Clipboard Item. Migration preserves its stable identifier, capture time,
source metadata, favorite state, valid tag assignments, exact data still
available in the old schema, and recency order. It does not merge existing
duplicates or reorder rows. Non-protected rows that are already expired under
the current Retention Period are omitted; protected rows are retained. Removing
an orphaned tag identifier during migration counts as losing protection at the
migration time, so the entry receives a fresh Retention Start rather than being
deleted immediately.

Legacy kinds map as follows:

- text becomes Text and receives deterministic Link, Email, and Color
  classification from its complete value;
- color becomes Text and Color;
- QR scanner output becomes Text and QR Code;
- standalone OCR output becomes Text because the old schema cannot reconstruct
  a relationship to its source image;
- image becomes Image;
- screenshot becomes Image and Screenshot because the old kind was written only
  by AnyDoor's first-party screenshot path; and
- each file member becomes a verified reference, a legacy-unverified
  reference, an unavailable legacy reference, or a Legacy Owned File according
  to the member-level rules below; Image is added when its filename or resource
  type declares an image.

The old mixed category-tab order no longer controls the fixed Facet Filter.
Its relative order for still-valid custom tag identifiers migrates into the
tag-only display order; stale identifiers and positions for All, Favorites,
OCR, or legacy kinds are discarded, and newly unmentioned tags append in their
definition order.

Owned legacy image and screenshot payloads are encrypted into the staged
payload directory. Neither Automatic Image Text Indexing nor Automatic QR
Indexing backfills migrated images.

Legacy file manifests migrate member by member because one old row may contain
both copied and path-only members. For a member with an intact legacy copy,
migration compares file size and streamed SHA-256 digests with the current
regular file. Equal content becomes a bookmark reference, and the redundant
old copy is deleted only after publication is verified. A missing, changed,
replaced, unreadable, or otherwise unverifiable current target causes the
legacy copy to become an encrypted Legacy Owned File instead. Path existence
alone is never proof that the target is the captured file.

A legacy member without readable captured bytes, whether the manifest was
path-only or its named copy is now missing, cannot prove pre-migration
identity. A resolving path receives a bookmark plus legacy-unverified
provenance; its identity guarantee begins at migration. A non-resolving path
remains a searchable unavailable legacy reference with no bookmark and never
auto-binds to a file later created there. Either state preserves the old path
record without inventing recovered content, silently deleting the row, or
asking the user to confirm its loss.

An entry may therefore mix ordinary references, legacy-unverified references,
unavailable references, and Legacy Owned Files. Any owned or unavailable
member blocks normal paste of the complete collection. Restore File… or
Restore Files… writes every owned member to explicit user-chosen destinations
and creates every bookmark before one database transaction converts all owned
members to ordinary references. The history-state transition is all-or-nothing:
no encrypted owned payload is retired on partial failure. User-owned output
files already written before a filesystem or process failure may remain at
their chosen destinations; retry uses explicit collision handling while the
history entry remains recoverable. Restore preserves capture-time paths and
the duplicate fingerprint.

Publication and cleanup are independently idempotent. A crash before
publication leaves the legacy source untouched and the incomplete staging
store safe to discard and rebuild. A crash after publication but before legacy
cleanup resumes cleanup from the verified new store. No path treats a partially
migrated store as live, silently resets history, or deletes the only readable
copy.

Consequences:

- Migration may delay Clipboard History availability on the first upgraded
  launch, especially when many owned images require encryption.
- Other AnyDoor SwiftData models remain untouched; only the legacy clipboard
  rows and their owned payload directory are retired.
- Legacy source attribution whose provenance was not stored is marked as legacy
  rather than upgraded to a false declared-source claim.
- A failed migration presents retry and diagnostic actions but continues to
  preserve the old data.
- Migration fixtures must cover every legacy kind, protected and expired rows,
  member-level copied/path-only mixtures, equal and changed same-path files,
  replaced paths, missing originals with and without copies, Legacy Owned File
  retention, single- and multi-member restore failures, payload corruption,
  duplicate rows, crashes at every publication boundary, and retry after
  failure.

## Amendment: copies that are not files, and captures before the cutover (2026-10-01)

v1 copied a symbolic link as the link itself, so a pre-v2 payload folder can
hold links, and in principle other entries that are not regular files. The
snapshot takes every entry as it is: each one is renamed into the snapshot
without following a link, and a name the snapshot already holds stops the move
instead of being replaced. A named copy that is not itself a regular file
(checked with `lstat`) holds no readable captured bytes, so its member migrates
by the rule for a missing copy above: legacy-unverified while its original
path resolves, unavailable otherwise. Image payloads keep strict validation,
because v1 wrote them itself. Deleting the snapshot removes links, never their
targets. Before this, one such link failed the migration on every launch.

Passive monitoring was already paused until publication, but explicit captures
(screenshots, recognized text, QR codes and picked colors) still reached the
store, which opens at launch. The migration replaces only an empty initial
store, so one capture taken while it was pending or had failed made the failure
permanent. Explicit captures are now held back from history until the process
has confirmed the cutover; their pasteboard writes and saved files are
unaffected. A store that a 4.2 release already filled this way still refuses
the migration; the next amendment recovers it.

Every failure that leaves the lifecycle in the migration-failed or reset-failed
state is now logged, by error type and case or by domain and code, never with a
path. That log is the diagnostic the consequences above call for; a failed
migration still offers only Retry.

## Amendment: discarding the entries that block the migration (2026-10-01)

Publication still replaces only a store without entries. A store that holds
entries and no published migration is refused with its entry count, and the
lifecycle reports the migration as blocked rather than failed. Before the
cutover, passive monitoring never runs and current releases hold explicit
captures back, so every entry in such a store is an explicit capture a 4.2
release recorded while its migration was pending or had failed. Clipboard
Settings offers Retry and a confirmed discard that names the entry count and
those capture kinds. Reset is not offered there, because it would discard the
pre-v2 history as well.

The confirmation carries the count it showed, and the migration discards only
while the store holds exactly that many entries; otherwise it refuses again
with the current count. The discard runs inside the migration, after the
staging store has been built and verified and immediately before publication.
It removes the payload and staging folders first, then the write-ahead log
and the database, each by name, and the store folder only once it is empty. A
failure before the discard leaves the store as it was. A discard that stops
partway leaves either a database that still lists its entries, which the next
confirmation discards again, or no database and no payloads, which the next
launch replaces with an empty store and migrates as usual. The legacy snapshot
stays authoritative until publication and cleanup, as before. Unlike Reset,
the discard keeps the Keychain key and any store kept aside under
`ClipboardHistoryV2.displaced/`, and a write that was still waiting for its
turn against the discarded store is refused rather than landing in the
migrated one.
