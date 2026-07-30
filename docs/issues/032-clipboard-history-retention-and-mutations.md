---
id: 032
github: 85
title: "Clipboard History v2: retention, protection, mutations, and maintenance"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0011, ADR-0012, ADR-0022, and ADR-0023.

## What to build

Implement the typed mutation and maintenance operations behind
`ClipboardHistoryModule`: favorite and tag assignment, tag-definition cleanup,
text editing, entry deletion, Retention Period changes, Clear History, physical
reclamation, and History Storage Usage.

Retention is age-only for non-protected entries with the seven approved
presets. Favorite or any currently valid tag protects an entry. New and real
duplicate captures establish Retention Start; text edit and loss of final
protection reset it without changing original capture time or recency. Merely
viewing, copying, or pasting does not extend retention.

Shortening retention first returns an exact affected count and a revision-bound
confirmation token. Applying the change either atomically stores the new period
and deletes that same current set, or reports that the count changed. Clear
History follows the same preview/apply pattern and defaults to excluding
protected entries; an explicit flag includes favorites and tagged entries
without deleting tag definitions, settings, or the live pasteboard.

Text editing is allowed only for a one-item entry with an Exact Text Payload.
It replaces the representation set with exact plain text and transactionally
updates facets, fields, FTS rows, fingerprint, edit time, and Retention Start
without duplicate merge.

Make expiry a query and duplicate-candidate invariant. Logical deletion removes
entries immediately from every operation, cancels jobs, and retires database
references before payload cleanup. Maintenance checkpoints WAL, runs
incremental vacuum, reclaims unreferenced encrypted files within 24 hours, and
reports exact allocated History Storage Usage for the dedicated boundary
without following symlinks.

## Acceptance criteria

- [ ] All approved retention presets are available without entitlement or hidden item-count behavior, with 30 days as the default
- [ ] Favorite and every valid tag protect an entry; losing only the final protection starts a fresh full retention window
- [ ] Retention preview/apply and Clear History preview/apply reject stale counts instead of deleting a different set
- [ ] A retention reduction with zero affected entries applies immediately without presenting destructive confirmation
- [ ] The default Clear History scope preserves protected entries; the explicit expanded scope deletes them but preserves tag definitions and settings
- [ ] Expired entries are absent from pages, search, counts, and duplicate reuse before physical reclamation
- [ ] Text edit enforces eligibility and updates representations, facets, search, fingerprint, and retention in one transaction without moving recency
- [ ] Deletion and retention cleanup preserve FTS ordering, encrypted-payload ordering, and rollback guarantees
- [ ] History Storage Usage includes database sidecars, payloads, thumbnails, staging, and encrypted orphans but excludes referenced source files
- [ ] Disk-full and other write failures reject only the new mutation, preserve existing history, and never invoke emergency pruning
- [ ] Clock-driven tests cover boundary expiry, protection changes, pagination during expiry, cleanup deadlines, and Unlimited Retention

## Out of scope

Confirmation UI, settings controls, derived Vision jobs, and legacy migration
are later tickets.

## Blocked by

Tickets 029 and 031.
