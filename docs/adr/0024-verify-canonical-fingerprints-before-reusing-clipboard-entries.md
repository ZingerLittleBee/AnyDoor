---
status: accepted
---

# Verify canonical fingerprints before reusing Clipboard Entries

Duplicate capture uses a versioned canonical encoding of the complete ordered
Clipboard Entry. The encoding length-prefixes every value and includes each
Clipboard Item boundary, item position, representation type, and canonical
payload. Representation type identifiers are sorted within an item so
pasteboard advertisement order does not affect identity.

Exact text retains case, whitespace, and line endings. Rich-text identity
includes the exact stored RTF, RTFD, and HTML bytes. URL and color
representations include their canonical domain values. File collections include
standardized capture-time paths and order, not the current frontmost app.
Bitmap identity uses the orientation-applied canonical lossless bitmap,
including dimensions, component depth, alpha, and the color profile that gives
pixel values their meaning, while ignoring source encoding and unrelated
metadata.

SHA-256 of that encoding is an indexed candidate key, not proof of equality.
Before reuse, AnyDoor compares the canonical structure and payload digests of
each candidate so a hash collision cannot merge unrelated user data. The
fingerprint column is intentionally non-unique: one-time migration and explicit
text edits preserve pre-existing independent records rather than destructively
merging their favorite and tag metadata. When several live rows match, a real
capture reuses the newest one by recency.

Reuse commits as one transaction. It moves the selected entry to newest,
replaces capture time and latest source attribution, resets Retention Start,
preserves favorite state and tags, and grants fresh OCR or QR indexing budgets
when the new capture is eligible. It does not retain a source-history trail.
Expired rows are never reuse candidates. Immutable owned payloads are reused
instead of rewritten when their authenticated files remain valid.

Writing, copying, or pasting an existing history entry back to the system
pasteboard is a suppressed AnyDoor self-write, not a duplicate capture, and
therefore does not invoke this policy.

Consequences:

- Visually identical rich content with different stored standard
  representations may remain distinct, by design.
- The schema can index fingerprints efficiently without trusting a digest as a
  uniqueness constraint.
- Tests must cover item order, representation order, exact whitespace,
  equivalent image encodings, differing formatting, multiple legacy
  duplicates, expired candidates, and forced digest collisions.
