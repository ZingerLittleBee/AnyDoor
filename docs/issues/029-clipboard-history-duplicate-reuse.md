---
id: 029
github: 82
title: "Clipboard History v2: canonical fingerprint verification and duplicate reuse"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decision: ADR-0024.

## What to build

Implement the versioned canonical encoding and duplicate-reuse transaction
inside the module. The encoding length-prefixes values, preserves Clipboard
Item boundaries and order, sorts representation identifiers only within an
item, and follows ADR-0024's exact identity rules for text, rich data, URLs,
colors, files, and canonical bitmaps.

Use indexed SHA-256 only to select live candidates. Before reuse, compare the
complete canonical structure and payload digests so a digest collision cannot
merge unrelated entries. The fingerprint column remains non-unique. If several
live records match, reuse the newest one.

One reuse transaction moves the selected entry to newest, updates capture time
and latest source attribution, resets Retention Start, preserves favorite and
tag assignments, refreshes eligible derived-indexing budgets, and reuses valid
immutable owned payloads. Expired rows and AnyDoor self-writes are not
candidates. Explicit text editing never invokes duplicate merge.

## Acceptance criteria

- [ ] Fingerprints distinguish item order, item boundaries, exact whitespace, line endings, formatting bytes, file order, and semantically different bitmap content
- [ ] Representation advertisement order within one item does not change identity
- [ ] Equivalent source image encodings that produce the same canonical bitmap can reuse one entry
- [ ] A forced SHA-256 collision fails structural verification and creates an independent entry
- [ ] Reuse preserves favorite and tags while updating only the PRD-authorized capture, source, recency, retention, and derived-job fields
- [ ] Multiple matching legacy rows reuse the newest live row without merging the others
- [ ] Expired entries, history copy/paste writes, and explicit text edits never trigger duplicate reuse
- [ ] Payload reuse never trusts an unauthenticated or missing encrypted file

## Out of scope

Age expiry, retention settings, search ranking, monitor self-write detection,
and migration of existing duplicates belong to later tickets.

## Blocked by

Ticket 028.
