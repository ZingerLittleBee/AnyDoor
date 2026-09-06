---
status: accepted
---

# Use age-only retention with explicit protection

Clipboard History retention is based only on a user-selected age policy for
non-protected entries. The fixed presets are 1 day, 7 days, 30 days, 3 months
(90 elapsed days), 6 months (180 elapsed days), 1 year (365 elapsed days), and
Unlimited. Thirty days is the default. Every preset, including Unlimited, is
available to every user without an entitlement, record-count cap, or paid tier.

An entry is protected while it is a favorite or has at least one valid tag.
Protection has no independent expiration. A non-protected entry's Retention
Start is:

- its capture time for a new entry;
- the newest capture time when a real duplicate capture reuses it;
- the moment it loses its final favorite-or-tag protection; or
- the commit time of an explicit text edit.

Copying, pasting, previewing, or opening an existing history entry is usage, not
a new capture. Those actions do not change its source, recency order, capture
time, or Retention Start. A user who wants durable retention uses favorite or a
tag rather than relying on incidental reuse.

Changing to a longer period or Unlimited takes effect immediately without
resurrecting entries that already expired. A shorter period first computes the
exact affected non-protected count. If that count is zero, the new period takes
effect immediately because no history is deleted. Otherwise confirmation is
required; if history changes while the prompt is open, it refreshes instead of
deleting a different count. The new period and the current affected set then
commit atomically.

Expiry is a query invariant as well as maintenance. Once the elapsed period is
reached, an entry is absent from browsing, search, duplicate reuse, and count
queries even if physical database pages or encrypted payload files await
reclamation. Maintenance cancels its OCR and QR work and reclaims storage
within 24 hours. A later capture of the same content creates or reuses a
currently live entry; it never revives the expired row.

Clear History is a separate explicit operation and always confirms. Its default
scope is non-protected entries. An unchecked checkbox expands the scope to
tagged and favorite entries, with the affected count updating before
confirmation. Either form leaves tag definitions and their order, excluded
source rules, retention settings, and the live system pasteboard unchanged.
The monitor advances its self-write baseline so clearing history cannot
recapture the current pasteboard.

Count-based pruning, disk-pressure pruning, least-recently-used eviction, and a
hidden maximum were rejected. They would contradict Unlimited Retention and
could remove content for reasons the user did not select.

Consequences:

- Frequently pasted but unprotected entries still expire; protection is
  explicit and inspectable.
- Tagged collections can grow without an age bound, and their actual allocated
  footprint remains visible as History Storage Usage.
- Retention tests need a controllable clock and must cover protection changes,
  edits, duplicate capture, confirmation races, expiry during pagination,
  clear scopes, and delayed physical reclamation.
