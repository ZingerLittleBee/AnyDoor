---
status: accepted
---

# Preserve pasteboard item groups

One observed general-pasteboard change creates one Clipboard Entry containing
the complete ordered sequence of `NSPasteboardItem` values. Each Clipboard Item
persists its own Standard Clipboard Representations. Normal paste reconstructs
all items in their original order.

The Clipboard Entry is the unit of recency, duplicate reuse, search, retention,
favorite state, tags, and deletion. The Capture Safety Limit is measured across
the complete entry. Search and content filters consider the union of its item
content, while duplicate identity includes item boundaries and order.

The previous type-priority classifier was rejected because it selected files
before images and images before text, silently discarding other items or
representations present in the same pasteboard state. Reading
`NSPasteboard.string(forType:)` as the entry payload was rejected because that
API concatenates matching string representations across items and destroys
their original boundaries.

Splitting one copy operation into several sibling history records was rejected.
It changes paste semantics, lets retention or manual deletion remove only part
of the copied state, and makes mixed-content ordering impossible to restore.

Consequences:

- Storage uses an entry-to-items relationship with a stable item position.
- A copy containing mixed text, images, and file references remains one entry.
- Any unavailable File Reference blocks normal paste of the complete Clipboard
  Entry, including mixed text or image items; no path silently restores a
  partial state. Multiple files retain both their item order and this
  all-or-nothing rule from ADR-0015.
- Duplicate fingerprints are computed from the ordered item structure rather
  than from one selected representation.
- Migration can preserve each legacy record as a one-item entry but cannot
  reconstruct item boundaries that older capture code already discarded.
- Tests must cover mixed item types, multiple text items without concatenation,
  ordered restoration, and entry-wide safety-limit rejection.
