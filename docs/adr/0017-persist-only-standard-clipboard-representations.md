---
status: accepted
---

# Persist only standard clipboard representations

Clipboard History persists an explicit allowlist of standard pasteboard
representations:

- exact plain text;
- every supplied RTF, RTFD, and HTML rich-text representation;
- URL data together with its exact text representation;
- the standard color representation together with a normalized color value;
- one lossless canonical bitmap for image content; and
- concrete file URLs represented by File Reference Entries.

Normal paste restores every stored standard representation for an entry.
Plain-text paste is available only when every Clipboard Item has an Exact Text
Payload; it reconstructs those string items in their original order and drops
their non-text representations deliberately. It is unavailable for a mixed
entry when doing so would silently omit an image or file-only item. Search and
duplicate fingerprints are derived from canonical domain content rather than
from the order in which pasteboard types happened to be advertised.

The canonical bitmap is a still, orientation-applied, lossless PNG produced
through ImageIO. It preserves alpha, decoded component depth, and an applicable
ICC color profile while dropping unrelated source metadata. Multi-frame or
animated source behavior is not promised by a general-pasteboard bitmap; file
URLs for animated assets remain File Reference Entries. A persistent,
size-bounded preview thumbnail may be derived from the bitmap, but it is an
encrypted owned payload rather than another paste representation.

Derived text used for preview and search may be extracted from rich
representations, but extraction never loads remote HTML resources or rewrites
the original RTF, RTFD, or HTML bytes.

Editing is available only for a Clipboard Entry with exactly one Clipboard Item
that has an Exact Text Payload. Saving replaces that item's representation set
with the edited exact plain string, because retaining old RTF, HTML, URL, color,
or QR provenance would misrepresent the new content. A truly zero-length edit
is rejected, while whitespace-only text remains valid. Facets, search fields,
preview data, and the duplicate fingerprint recompute in the same transaction;
the entry keeps its id, source, capture time, favorite, and tags, records an
edit time, and receives a fresh Retention Start without moving in recency order.
An edit may create content equal to another entry; it does not destructively
merge their independent protection metadata.

Persisting only the single richest text representation was rejected because an
entry can legitimately supply RTF, RTFD, and HTML at the same time, and
discarding all but one changes how different destination applications paste it.
Persisting every advertised pasteboard type, as Raycast v2 describes for its
own implementation, was rejected because application-private formats can be
large, lazily generated, version-specific, or contain opaque metadata unrelated
to the user's reusable content.

History Exclusion Markers are inspected but never stored as content. File
promises and unknown binary or application-private formats are not
materialized. This keeps capture behavior reviewable and prevents a source
application from expanding long-lived history storage through an unbounded
private representation surface.

The complete selected representation set is subject to the Capture Safety
Limit: at most 128 MiB of canonical plaintext representation bytes and, for an
image, at most 64 megapixels after decoding. Both limits are aggregate across
the complete Clipboard Entry, not per representation or per image. Exceeding
either bound rejects the whole entry with one non-modal notice; it never stores
a partial format set. Referenced file contents are not read and therefore do
not count toward the limit.

Consequences:

- Text entries store a representation collection instead of one optional
  `richData` and `richType` pair.
- Capturing RTF does not discard simultaneously supplied HTML or RTFD.
- Image paste preserves visual content through one lossless canonical bitmap,
  not every source encoding or private image flavor.
- Plain-text paste never converts a mixed multi-item entry into a partial
  clipboard state.
- Oversized content cannot create a partial entry whose paste behavior differs
  silently from the source.
- The allowlist is a versioned domain contract; adding a representation later
  requires a migration but cannot reconstruct formats discarded by older
  versions.
- Tests must verify both multi-representation restoration and explicit
  rejection of private or promised types.
