---
id: 034
github: 87
title: "Clipboard History v2: staged legacy migration and owned-file restore"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0015 and ADR-0020.

## What to build

Implement the one-time pre-monitoring migration without adding SwiftData to the
new module. A host-side read-only legacy adapter extracts versioned transfer
values from the shared SwiftData store and old plaintext payload directory.
The module builds a complete encrypted sibling staging store while the legacy
source remains authoritative.

Preserve each retained row as one Clipboard Entry with its stable id, order,
source metadata, favorite, valid tag assignments, available representations,
and recency. Apply the approved kind and facet mappings, omit already-expired
unprotected rows, retain protected rows, remove orphan tag ids with a fresh
Retention Start, and never merge existing duplicates or backfill OCR/QR.

Migrate every legacy file manifest member independently. An intact old copy
becomes an ordinary bookmark reference only when file size and streamed
SHA-256 digest prove equal current regular-file content. Otherwise preserve the
copy as an encrypted Legacy Owned File. A member without readable captured
bytes becomes a legacy-unverified bookmark when its path resolves or a
searchable unavailable reference when it does not; it never auto-binds later
and never asks the user to confirm record loss.

Support mixed file collections and the module side of Restore File… / Restore
Files…. The host supplies explicit user destinations. Write every owned output
and create every replacement bookmark before one database transaction converts
all owned members. A partial failure retires no encrypted payload and leaves
history retryable even if an already-written user output remains.

Publish staging only after database, foreign-key, row/id, FTS, and authenticated
payload verification. Cleanup is separately idempotent so crashes before and
after publication have distinct safe recovery paths.

## Acceptance criteria

- [ ] Migration begins before monitoring and never opens a partially staged store as live
- [ ] Fixtures cover every legacy kind, protection state, expiry state, duplicate state, source provenance, tag-order mapping, and corrupt payload
- [ ] Copied/path-only mixtures, equal and changed same-path files, replacement files, missing originals, missing named copies, and double-missing members follow the member-level contract
- [ ] Equal-content comparison streams bytes and never treats path existence or filename equality as identity proof
- [ ] Mixed ordinary, legacy-unverified, unavailable, and owned members preserve order and block partial normal paste
- [ ] Single- and multi-owned-member restore is one history-state transaction and preserves capture-time paths and duplicate fingerprint
- [ ] Crash fixtures cover every staging publication and legacy cleanup boundary, with retry producing one verified live store
- [ ] No legacy plaintext row or payload is deleted until the encrypted published store proves it is redundant or durably retained
- [ ] Migrated images receive no automatic OCR or QR backfill

## Out of scope

Migration progress UI, destination pickers, and production startup wiring are
ticket 036.

## Blocked by

Tickets 028, 029, 031, 032, and 033.
