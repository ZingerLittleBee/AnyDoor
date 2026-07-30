---
status: accepted
---

# Isolate Clipboard History storage

AnyDoor will move Clipboard History out of the shared application data store
into a device-local storage boundary that exclusively owns its entry records,
search data, and owned payloads. Independently attributable files are
required to report the feature's actual file-system-allocated History Storage
Usage, and the boundary also allows paging and indexed search to scale under
Unlimited Retention.

An attachment-directory-only measurement was rejected because it excludes text,
rich content, database pages, and search indexes. Measuring the shared AnyDoor
store was rejected because it includes unrelated application data. The storage
engine is selected separately by ADR-0013: a dedicated SQLite database, not a
second SwiftData `ModelContainer`.

The boundary has one pinned location shared by development and installed app
identities:
`~/Library/Application Support/dev.bybee.AnyDoor/ClipboardHistory/`. It owns
the encrypted database, WAL and shared-memory files, encrypted payloads and
thumbnails, migration staging, and temporary encrypted orphans. History Storage
Usage recursively sums their file-system allocated sizes without following
symlinks. It excludes referenced source files and every unrelated AnyDoor
store. The displayed value refreshes after mutations and when the Settings
section appears; it is not an estimate by content kind.

Existing clipboard records and payloads will require a one-time migration. The
new storage remains device-local and outside Config Sync and Config Backup.
Portable configuration includes tag definitions, tag order, and excluded
applications or source channels. Clipboard monitoring, copy-only paste
behavior, Retention Period, and Automatic Image Text Indexing remain
device-local, and a restore never turns monitoring on or off or replaces or
merges local Clipboard History entries.

AnyDoor performs no proactive disk-pressure monitoring, storage warning,
emergency purge, or automatic retention reduction. Age-based retention and
explicit Clear History are the only deletion policies. An actual failed write
is still reported as an operation failure and never authorizes deletion of
existing entries.

No standalone Clipboard History export or import is included in this scope. A
future history archive requires its own encrypted format, capacity disclosure,
migration policy, and conflict semantics.
