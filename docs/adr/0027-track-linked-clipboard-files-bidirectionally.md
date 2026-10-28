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

Implementation has not started. The complete specification defines the
signed-app and multi-device acceptance gates that it must satisfy.
