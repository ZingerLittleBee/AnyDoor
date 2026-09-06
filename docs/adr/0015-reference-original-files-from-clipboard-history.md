---
status: accepted
---

# Reference original files from Clipboard History

A Clipboard History file entry is created only when the pasteboard exposes one
or more concrete local `file://` URLs. AnyDoor stores each absolute original
path, display name, copy order, and regular non-security-scoped bookmark as
encrypted database metadata. It does not copy the file or directory contents
into the Clipboard History Store and does not materialize file promises.
Every URL must resolve sufficiently to create its bookmark at capture time; if
one member fails, the complete Clipboard Entry is skipped rather than storing a
partial file collection. A file's declared resource type or filename type may
establish Image without opening its contents.

Bookmark resolution runs without UI or automatic volume mounting. If the same
file is moved or renamed on an available volume, AnyDoor refreshes its current
display name and searchable path while retaining the capture-time path. If the
bookmark no longer identifies a file, AnyDoor does not fall back to a different
file later created at the old path.

When a bookmark cannot resolve because the original was deleted or its volume
is unavailable, the history entry remains visible and searchable. Any operation
that requires the unavailable item does not proceed silently; it reports that
the original file is unavailable. A multi-file entry remains one atomic
collection: if any reference is unavailable, AnyDoor blocks the entire paste
and reports how many items are unavailable rather than silently omitting them.
Referenced content is not part of History Storage Usage and is not encrypted
by AnyDoor.

Copying every referenced file was rejected because Unlimited Retention could
silently turn Clipboard History into an unbounded backup of private user data.
Copying only files below the previous 25 MB threshold was rejected because it
made persistence depend on an arbitrary size boundary: two visually identical
history entries had different recovery behavior after their originals
disappeared. Materializing file promises was rejected because that would create
new owned files where the normal copy operation supplied no stable file URL.

Consequences:

- The previous per-file copy threshold and copied-file payload format are
  removed.
- A file entry remains useful for search after its source disappears, but it is
  not a backup.
- A multi-file entry never pastes a partial subset implicitly.
- iCloud, external-volume, and network-volume paths can become temporarily
  unavailable without deleting their history entries.
- Bookmarks follow moves and renames without copying content or granting
  security-scoped access.
- The database encrypts file names and paths; the source file remains under the
  storage provider's own protection.
- Legacy file collections migrate member by member because one old manifest
  may already mix copied members with path-only members.
- A member with an intact legacy copy becomes an ordinary reference only when
  its current path resolves to a regular file whose size and streamed SHA-256
  digest equal the legacy copy. Publication verification may then retire the
  redundant old copy. A missing, changed, replaced, or unverifiable current
  target instead preserves the old copy as an encrypted Legacy Owned File
  payload, even when something now exists at the same path.
- A legacy member without readable captured bytes, whether the old manifest was
  path-only or its named copy is now missing, cannot be content-verified. If
  its path resolves during migration, AnyDoor creates a bookmark but records
  legacy-unverified provenance: the bookmark establishes identity only from
  migration onward and does not claim that the current target is the file
  originally copied. If the path does not resolve, the capture-time path
  remains as a searchable unavailable legacy reference with no bookmark;
  AnyDoor never binds it automatically to a later file at that path or asks
  the user to confirm discarding the record.
- Any Legacy Owned File or unavailable member blocks normal paste of the
  complete collection. Restore File… is used for one owned member and Restore
  Files… for several. Restore writes every owned member to explicit
  user-chosen destinations and creates all replacement bookmarks before one
  database transaction converts those members to ordinary references. No
  encrypted owned payload is retired unless the complete history-state
  transition succeeds. A filesystem or process failure may leave an already
  written user-owned output at its chosen destination, but the history entry
  and every encrypted owned payload remain recoverable and retryable with
  explicit collision handling.
- Restore updates current paths and bookmarks while capture-time paths and the
  duplicate fingerprint remain unchanged. Legacy Owned File payloads count
  toward History Storage Usage and follow normal retention and protection.
  This is a migration-only exception: new captures never copy file contents.
  A failed overall migration leaves every legacy record and payload intact for
  a later retry.
