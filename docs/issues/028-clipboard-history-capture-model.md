---
id: 028
github: 81
title: "Clipboard History v2: complete capture model and standard representations"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0015, ADR-0017, ADR-0018, ADR-0019, ADR-0022, and ADR-0025.

## What to build

Implement Clipboard Entry canonicalization and persistence inside the module.
One observed pasteboard generation becomes one entry containing the complete
ordered `NSPasteboardItem` sequence. Each item retains every supported standard
representation: exact text; every supplied RTF, RTFD, and HTML form; URL plus
exact text; standard color plus normalized value; one orientation-applied
lossless canonical bitmap; or concrete local file URLs.

Read History Exclusion Markers before payload bytes. Copy the selected
representations into an immutable in-memory snapshot and reject the entire
state if any item is unsupported-only, if the pasteboard generation changes
during the read, or if the entry exceeds the 128 MiB or 64-megapixel Capture
Safety Limit. Never persist a partial item sequence or representation set.

Derive the closed overlapping facet set and searchable field values without
rewriting exact representations. Screenshot requires first-party AnyDoor
provenance. File capture creates regular non-security-scoped bookmarks for
every concrete URL as one all-or-nothing operation, stores capture-time paths,
and never copies file or directory content or materializes file promises.

Persist canonical bitmaps through ticket 027's encrypted publication path.
Implement public explicit-capture requests for AnyDoor screenshot, OCR, QR, and
color actions so those user-invoked tools do not depend on passive monitoring.
Implement module materialization values for preview and later paste without
letting encrypted payload paths escape.

## Acceptance criteria

- [ ] Named-pasteboard tests preserve item boundaries, item order, and all simultaneously supplied standard representations
- [ ] Exact text preserves whitespace, tabs, and line endings; only a truly zero-length string is absent
- [ ] Private types are ignored only when the same item has supported content; an unsupported-only item rejects the complete entry
- [ ] Pre/post `changeCount` mismatch, aggregate-byte overflow, and pixel overflow commit no row or payload subset
- [ ] Canonical PNG generation applies orientation and preserves alpha, component depth, and applicable color profile through ImageIO
- [ ] Text, Link, Email, Color, Image, Screenshot, File, and QR Code facet fixtures match ADR-0019 without duplicate entries
- [ ] Every file member must create a bookmark before the collection commits; one failure commits none, and no capture copies referenced content
- [ ] Unavailable bookmarks never fall back to a different file later created at the capture-time path
- [ ] Explicit first-party captures produce the required provenance while normal external bitmaps never infer Screenshot
- [ ] Preview materialization authenticates and decrypts owned payloads only into process memory

## Out of scope

Passive scheduling, duplicate reuse, ranked search, derived OCR/QR jobs, legacy
file migration, and host paste synthesis are later tickets.

## Blocked by

Ticket 027.
