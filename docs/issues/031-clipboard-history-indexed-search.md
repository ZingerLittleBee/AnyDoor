---
id: 031
github: 84
title: "Clipboard History v2: encrypted substring search, ranking, and cursor pages"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decision: ADR-0021.

## What to build

Implement the module's indexed search and paged query operations. Store
authoritative normalized field rows and create an external-content FTS5 trigram
table for terms of at least three Unicode code points plus a
`contentless_delete=1` unigram/bigram table for shorter terms. Both FTS tables
use persistent FTS5 `secure-delete=1` in addition to core secure deletion.

Query both indexes only with bound literal MATCH expressions. Verify every
candidate against its authoritative normalized field value with a real
continuous-substring comparison. Implement complete-query exact, prefix, and
substring preference; per-term AND semantics across an entry's fields and
items; field priority; recency; and stable-id ties exactly as defined by the
PRD. Facet, source, tag, favorite, and date constraints remain typed filters
rather than searchable text.

All field and index mutation uses one transaction. Delete the
external-content row while the old field remains available, remove the
short-gram row, and only then delete the authoritative field. Updates remove
old index entries before replacing the field and inserting new index entries.
Inserts commit the field and both indexes together.

Return opaque keyset pages of 100. Cursors bind the normalized query, filters,
index generation, ranking tuple, capture time, and entry id. Rebuild derived
indexes from authoritative fields after a version change or index-only
corruption; browsing remains available while search reports indexing.

## Acceptance criteria

- [ ] CJK, Latin, combining-mark, full-width, emoji, punctuation, and mixed-item fixtures return complete exact, prefix, and substring results
- [ ] One- and two-code-point terms use the short-gram index without a full-history scan
- [ ] Both FTS tables are MATCH-only; LIKE or GLOB against an FTS table is absent from production query code
- [ ] Candidate verification rejects stale or false-positive tokens before ranking
- [ ] Insert, update, delete, and rollback tests cover every index-ordering boundary and pass FTS integrity checks
- [ ] Both FTS tables persist `secure-delete=1`, and committed deletions no longer produce stale candidates
- [ ] Ranking and multi-term behavior match the PRD across different fields and Clipboard Items
- [ ] Facet, source, tag, favorite, and date filters combine with search without entering FTS text
- [ ] Keyset pagination has no total cap, produces no duplicates across pages, and restarts when inputs or index generation change
- [ ] Missing FTS5 or trigram support produces an invalid-build/store diagnostic rather than a linear fallback

## Out of scope

SwiftUI search presentation, OCR/QR job production, and final large-corpus
performance thresholds belong to later tickets.

## Blocked by

Ticket 028.
