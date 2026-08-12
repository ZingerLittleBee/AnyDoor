---
status: accepted
---

# Migrate legacy Clipboard History through a staging store

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
