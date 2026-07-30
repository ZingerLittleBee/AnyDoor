---
status: accepted
---

# Model content types as overlapping facets

Clipboard History classifies content with a closed, non-exclusive Content Facet
set:

- Text
- Link
- Email
- Color
- Image
- Screenshot
- File
- QR Code

Each Clipboard Item can carry several facets, and its Clipboard Entry exposes
their union. Facets support filtering and presentation; they do not select a
different stored record or override the ordered representation model from
ADR-0018.

A textual URL, email address, or color remains Text while gaining its more
specific facet. A referenced image file is both File and Image. A screenshot
containing a QR code is Image, Screenshot, and QR Code. These cases appear once
in history and can be reached through every applicable filter.

Explicit standard URL, color, file-URL, and image representations establish
their facets directly. Plain-text inference requires the complete text after
derived surrounding-whitespace removal to be one valid Link, Email, or Color.
Embedded values remain ordinary searchable Text rather than broadening facet
filters. A referenced file gains Image from its declared resource type or
filename type without opening file contents. Derived OCR and QR strings never
feed Link, Email, or Color inference; those facets describe stored clipboard
representations rather than text discovered later.

For plain-text Link inference, valid values are complete `http` or `https`
URLs, bare domains, `localhost`, IP addresses, or syntactically valid custom
`scheme://` deep links. Hosts may include a port or path. Relative URLs,
filesystem paths, templates, values containing internal whitespace, and the
unsafe `javascript:`, `data:`, and `vbscript:` schemes do not qualify.
`file://` is classified as File, while email-specific schemes are handled by
Email classification. Any scheme completion or normalization happens only for
the open action and does not rewrite the stored text. The same unsafe-scheme
and file-URL exclusions apply to explicit URL pasteboard representations.

For plain-text Email inference, one complete valid mailbox qualifies as Text
and Email but not Link. A complete valid `mailto:` URI with at least one
recipient qualifies as Text, Email, and Link. Addresses embedded in prose,
display-name forms such as `Name <address@example.com>`, and comma-separated
bare-mailbox lists remain searchable Text but do not receive the Email facet.
As with Link inference, derived surrounding-whitespace removal never rewrites
the stored text.

For plain-text Color inference, supported complete values are `#RGB`, `#RGBA`,
`#RRGGBB`, `#RRGGBBAA`, CSS `rgb()` / `rgba()` / `hsl()` / `hsla()` in comma
or modern space-and-slash syntax, and the exact
`Color(red:..., green:..., blue:...)` form emitted by AnyDoor. Standard
pasteboard color representations establish Color directly. Bare hexadecimal
strings, named colors, CSS variables, gradients, and extended color functions
such as `lab()` and `oklch()` do not qualify. Parsed normalized color data may
support display and search, but it never replaces the original text.

Every bitmap receives Image, but Screenshot requires first-party provenance
from AnyDoor's own screenshot capture pipeline. AppKit provides standard image
representations such as PNG and TIFF but no standard screenshot pasteboard
type. Images copied from macOS Screenshot or another application therefore
remain Image. Dimensions, filenames, PNG metadata, and source-application names
are not sufficient evidence; a Finder image whose filename resembles a
screenshot is File and Image, not Screenshot.

Bitmap payloads saved in history are scanned asynchronously for QR codes using
on-device recognition. This pass is always enabled, has no user-facing setting,
and never blocks capture. Successful recognition adds every decoded value and
the QR Code facet to the same entry rather than creating a sibling record or
replacing the image. Plain text never gains QR Code through content inference;
text produced by AnyDoor's explicit QR scanner gains it through first-party
provenance. Referenced image files are not opened for automatic QR indexing.
Eligible entries persist pending work across relaunches and receive at most
three recognition attempts, including the initial attempt. Exhaustion is silent
and affects neither the entry nor its image. Recapturing an identical bitmap
grants a fresh three-attempt budget; no manual retry action is exposed. The
indexer processes only bitmap captures made after this indexing system becomes
active. Migrated and otherwise pre-existing images are not backfilled, but
recapturing one makes the new capture eligible. A successful recognition pass
that finds no QR code is complete rather than failed and is not retried.

The previous single `ClipboardHistoryKind` enum was rejected because these
classifications overlap in ordinary clipboard content. Choosing one primary
kind either hid entries from useful filters or required duplicate records with
independent retention and deletion behavior.

OCR is not a Content Facet and never creates a sibling history record. It is
derived searchable text attached to the image entry that produced it.

The user-facing Facet Filter is single-select with an All state and has a fixed
order matching the closed facet list. It combines with query, one optional
source, one optional tag, and an independent favorite-only toggle rather than
replacing them. Tag definitions keep their user-visible order separately from
facets. The overlap model makes an image file reachable through either Image or
File without adding multi-select Boolean facet expressions.

Consequences:

- Storage represents facets independently of paste representations.
- Content-filter queries use facet membership without duplicating result rows.
- Content type remains a simple browsing choice rather than a Boolean query
  language.
- Existing screenshot and image records migrate to Image, with Screenshot added
  where known; color, QR, and text records retain Text when they contain text.
- Legacy OCR-only records migrate as Text because their source image
  relationship was never stored and cannot be reconstructed.
- Tests must cover overlapping classification and deduplicated filter results.
