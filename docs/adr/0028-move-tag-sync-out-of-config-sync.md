---
status: accepted
---

# Move automatic tag synchronization out of Config Sync

Clipboard Sync owns automatic synchronization of selected tag definitions and
their entry associations. The new version retires the existing automatic
Config Sync tag channel; unselected tags remain local. This decision was
accepted in the [design interview](../prds/2026-10-28-clipboard-icloud-sync.md)
and the automatic Config Sync tag channel is now retired. Native Clipboard Sync
now handles shared selection, names, and selected memberships through encrypted
operations. Losing the final selected tag withdraws cloud content while retaining
local copies; explicit selection or reassignment rejoins the original identity.
Tracked files and complete directories now use the same withdrawal, rejoin,
deletion, preservation, and Cloud Reset authority; retained copies alone do not
authorize republishing. See the [runtime boundary](../agents/architecture.md#clipboard-sync).

Keeping both channels was rejected: Config Sync previously serialized the
complete tag list as a plaintext setting, which would bypass the selected-tag
privacy boundary and the new end-to-end encryption promise. It would also give
two independent mechanisms authority to replace the same tag definitions.

Stable tag identity survives a rename. Independently created same-name tags
remain distinct. Name matching alone must not enroll another device's local
history for synchronization; users may explicitly merge the tags or select
them independently. Manual Config Backup can still export tag definitions as
a separate user-requested action.

The migration stops old-channel emission and application, removes the retired
record from retained local state and incoming documents, and preserves local
memberships. Automatic runtime refresh never reads tag definitions from preferences.
The active plaintext preferences mirror is retired: startup imports any missing
legacy identities into the writable encrypted store once, preserving existing
names and associations, and removes the old value only after success. A durable
encrypted marker prevents stale copies from resurrecting removed tags on restart;
failed transactions retain the original value for retry. New tag operations do not
write a mirror. Explicit manual backup export builds definitions in memory from
the module; import replaces them directly through the module, retaining existing
memberships for retained IDs and removing memberships of removed IDs. These
explicit files remain a user-requested exception to background-artifact encryption.
Removing the whitelist entry alone is insufficient because Config Sync retains
unknown settings.
Existing remote files and older clients may retain former tag names; the new
feature cannot claim historical erasure or govern old software. Users who
previously relied on Config Sync for tags must enable Clipboard Sync and select
tags to continue automatic tag synchronization after the change.
