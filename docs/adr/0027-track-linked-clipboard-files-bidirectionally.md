---
status: accepted
---

# Track linked clipboard files bidirectionally

Selected Clipboard History entries can own a shared file version and explicit
Linked Locations on participating Macs. Changes at those locations flow in
both directions, including for directories and application packages. The owner
rejected both initial-copy-only synchronization and source-device-only updates
in the [design interview](../prds/2026-10-28-clipboard-icloud-sync.md).

This extends the existing [file-reference contract](0015-reference-original-files-from-clipboard-history.md)
only for the new synchronized workflow. It does not turn every pasted or
separately saved copy into a tracked location. Ordinary copies remain independent
unless explicitly associated; an unchanged local-history file reference still
does not imply ownership of file contents.

User-visible Linked Working Copies may persist as ordinary editable files so
external applications can modify them. That exception does not apply to the
encrypted history database, background payload caches, or transfer staging.
It is not possible to promise at-rest application encryption for a file while
also exposing it as a normal editable file to other applications.

Conflicting edits retain both versions. Directory and package publication
exposes only complete verified versions. Replacing an associated application
requires an explicit Apply Update action and never occurs while it is running.
The original or independently exported file is never removed merely because a
history entry is deleted. Top-level source removal detaches that location;
removal inside a tracked directory remains a content change.

Ordinary-file associations and saved-change reconciliation are implemented with
persisted per-location bases and dirty-file preservation. Established filesystem
identity follows moves and renames; supported mounted filesystems can recover
the object using persistent volume/object identity and its birth stamp. Missing
volumes and permissions pause tracking without mounting a volume or publishing
empty content. Confirmed removal detaches the location while retaining shared
versions and other linked copies.

In-place saves continue tracking. AnyDoor's own verified replacement journal can
establish continuity across its atomic new-inode installation. An external editor
safe-save that replaces the filesystem object requires explicit reassociation
when continuity cannot be proven, even if its path or document ID matches.
Generic filesystem and file-coordination callbacks do not establish that proof.
Pause, retry, resume, and reassociation actions validate the displayed location
revision so a stale picker cannot silently replace a changed association.

Complete directory versions now reuse the same linked identity, file graph,
explicit per-version download consent, and conflict resolution. Recursive changes
freeze as one authenticated tree, including portable metadata and logical forks.
The original-size threshold counts all synchronized content and attribute values;
encoded framing has a separate size. Incomplete or changing trees cannot replace
the previous complete version. Source proof and reconstruction use disk-backed
encrypted inventories and bounded content streams; ordinary xattrs require one
platform-sized value buffer. See the [format and mutation boundary](../agents/architecture.md#clipboard-sync).

Application-package Apply Update and running-application protection remain a
separate acceptance slice.
The complete specification defines the signed-app and multi-device acceptance
gates; isolated real-file tests do not establish live iCloud delivery.
