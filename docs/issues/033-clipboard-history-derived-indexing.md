---
id: 033
github: 86
title: "Clipboard History v2: persisted OCR and QR indexing jobs"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decision: ADR-0019.

## What to build

Implement persisted, asynchronous on-device OCR and QR indexing for owned
bitmap captures. The module owns job eligibility, attempt count, scheduling,
cancellation, and transactional publication of derived fields and facets.
Recognition begins only after the authenticated bitmap payload is committed.

Automatic Image Text Indexing is device-local, disabled by default, and applies
only to bitmaps captured while enabled. Enabling never backfills. Disabling
prevents later eligibility while allowing already pending jobs to finish and
retaining existing text. OCR uses Vision accurate recognition and adds
searchable text, not a content facet.

Automatic QR Indexing is always enabled for newly captured owned bitmaps. It
attaches every decoded value and the QR Code facet to the existing entry.
Referenced image files and migrated images are never scanned. Text produced by
the explicit AnyDoor QR scanner receives first-party QR provenance without
passing through bitmap auto-indexing.

Each eligible job receives at most three attempts, including the first.
Interrupted pending work resumes after relaunch. Exhaustion is silent and marks
only that derived job failed. A successful empty result is complete. A real
duplicate recapture while eligible grants a fresh budget.

Keep Vision behind the internal seam allowed by ADR-0025. Scheduler tests may
use a deterministic adapter, while production-adapter tests must exercise real
Vision against repository fixtures rather than replacing the engine with a
synthetic implementation.

## Acceptance criteria

- [ ] OCR defaults off, never backfills, uses accurate on-device recognition, and publishes only searchable derived text
- [ ] QR indexing defaults on for eligible new owned bitmaps and attaches all values plus one QR Code facet to the same entry
- [ ] Referenced files, migrated images, and images captured while OCR was disabled are never retroactively scanned
- [ ] Pending jobs survive relaunch and stop after exactly three failed attempts without user-facing warning or retry
- [ ] Successful empty recognition does not retry; duplicate recapture grants a fresh budget only when currently eligible
- [ ] Deletion, expiry, and Clear History cancel related work and prevent a late result from resurrecting fields or facets
- [ ] Derived field and FTS updates commit atomically and preserve the original image paste behavior
- [ ] Real Vision fixture tests cover representative text, no-text, single-QR, multi-QR, and no-QR images

## Out of scope

Settings copy and controls, legacy backfill, and OCR or QR of file references
are excluded.

## Blocked by

Tickets 031 and 032.
