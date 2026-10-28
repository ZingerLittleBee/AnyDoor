---
status: accepted
---

# Move automatic tag synchronization out of Config Sync

Clipboard Sync owns automatic synchronization of selected tag definitions and
their entry associations. The new version retires the existing automatic
Config Sync tag channel; unselected tags remain local. This decision was
accepted in the [design interview](../prds/2026-10-28-clipboard-icloud-sync.md)
and is not implemented yet.

Keeping both channels was rejected: Config Sync currently serializes the
complete tag list as a plaintext setting, which would bypass the selected-tag
privacy boundary and the new end-to-end encryption promise. It would also give
two independent mechanisms authority to replace the same tag definitions.

Stable tag identity survives a rename. Independently created same-name tags
remain distinct. Name matching alone must not enroll another device's local
history for synchronization; users may explicitly merge the tags or select
them independently. Manual Config Backup can still export tag definitions as
a separate user-requested action.

Migration must stop old-channel emission and application, handle retained
serialized sync state, and preserve local memberships. Removing the whitelist
entry alone is insufficient because Config Sync retains unknown settings.
Existing remote files and older clients may retain former tag names; the new
feature cannot claim historical erasure or govern old software. Users who
previously relied on Config Sync for tags must enable Clipboard Sync and select
tags to continue automatic tag synchronization after the change.
